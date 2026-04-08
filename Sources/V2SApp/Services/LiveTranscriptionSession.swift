import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Speech

#if canImport(OnnxRuntimeBindings)
private typealias SessionVADEngine = SileroVADEngine
private typealias SessionVADResult = VADResult
#else
private struct SessionVADResult: Sendable {
    let speechProbability: Float
    let isSpeech: Bool
    let containsSpeechOnset: Bool
    let containsSpeechOffset: Bool
}

private enum SessionVADError: LocalizedError, AppLocalizableError {
    case unavailable

    func localizedDescription(languageID: String) -> String {
        AppLocalization.string(.sileroVadUnavailableWithoutOnnx, languageID: languageID)
    }

    var errorDescription: String? {
        localizedDescription(languageID: "en")
    }
}

private final class SessionVADEngine {
    init() throws {
        throw SessionVADError.unavailable
    }

    func process(buffer: AVAudioPCMBuffer) -> SessionVADResult {
        _ = buffer
        return SessionVADResult(
            speechProbability: 0,
            isSpeech: false,
            containsSpeechOnset: false,
            containsSpeechOffset: false
        )
    }

    func reset() {}
}
#endif

struct RecognizedSentence: Equatable, Sendable {
    let text: String
    let promotionSegmentID: UUID?

    init(text: String, promotionSegmentID: UUID? = nil) {
        self.text = text
        self.promotionSegmentID = promotionSegmentID
    }
}

final class LiveTranscriptionSession: NSObject, @unchecked Sendable {
    private struct CommittedEmission {
        let text: String
        let promotionSegmentID: UUID?
    }

    private struct ApplicationCaptureDescriptor: Sendable {
        let appName: String
        let processObjectIDs: [AudioObjectID]
        let readStreamFailureMessage: String
    }

    @MainActor
    private struct RecentCommittedSentence {
        let rawText: String
        let comparableText: String
        let time: Date
        let allowsPrefixContinuation: Bool
    }

    private struct AudioLevelStats {
        let peak: Float
        let rms: Float
    }

    private enum RecognitionBackend {
        case legacy
        case speechAnalyzer
    }

    enum SessionError: LocalizedError, AppLocalizableError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case audioCapturePermissionDenied
        case unsupportedSpeechLocale(String)
        case unavailableSpeechRecognizer(String)
        case missingMicrophoneDevice
        case missingApplication(String)
        case applicationNotProducingAudio(String)
        case failedToStartCapture(String)

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .speechPermissionDenied:
                return AppLocalization.string(.speechPermissionDenied, languageID: languageID)
            case .microphonePermissionDenied:
                return AppLocalization.string(.microphonePermissionDenied, languageID: languageID)
            case .audioCapturePermissionDenied:
                return AppLocalization.string(.appAudioCapturePermissionDenied, languageID: languageID)
            case .unsupportedSpeechLocale(let localeIdentifier):
                return AppLocalization.string(.unsupportedSpeechLocaleFormat, languageID: languageID, localeIdentifier)
            case .unavailableSpeechRecognizer(let localeIdentifier):
                return AppLocalization.string(.unavailableSpeechRecognizerFormat, languageID: languageID, localeIdentifier)
            case .missingMicrophoneDevice:
                return AppLocalization.string(.missingMicrophoneDevice, languageID: languageID)
            case .missingApplication(let appName):
                return AppLocalization.string(.missingApplicationFormat, languageID: languageID, appName)
            case .applicationNotProducingAudio(let appName):
                return AppLocalization.string(.applicationNotProducingAudioFormat, languageID: languageID, appName)
            case .failedToStartCapture(let reason):
                return AppLocalization.string(.failedToStartCaptureFormat, languageID: languageID, reason)
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    private let captureQueue = DispatchQueue(label: "com.franklioxygen.v2s.capture", qos: .userInitiated)
    private let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Incremented on every restart. Handlers capture their generation at creation time
    /// and discard callbacks that arrive after a newer generation has started.
    private var recognitionGeneration: Int = 0
    private var preprocessingConverter: AVAudioConverter?
    private var preprocessingConverterInputSignature: AudioFormatSignature?
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputSignature: AudioFormatSignature?
    private var modernAudioConverter: AVAudioConverter?
    private var modernAudioConverterInputSignature: AudioFormatSignature?
    private var committedSegmentCount = 0
    private let committedBoundaryToleranceSec: TimeInterval = 0.08
    private var committedAudioBoundaryTime: TimeInterval?
    private var recognitionContextualStrings: [String] = []
    private var recognitionBackend: RecognitionBackend = .legacy
    private var activeLocaleIdentifier: String?
    private var interfaceLanguageID = "en"
    private var modernAnalyzerTask: Task<Void, Never>?
    private var modernResultsTask: Task<Void, Never>?
    private var lastModernCommittedResultIdentity: String?
    private var speechAnalyzerState: AnyObject?
    private var speechTranscriberState: AnyObject?
    private var analyzerInputContinuationState: Any?
    private var analyzerInputFormat: AVAudioFormat?
    private var latestModernText = ""
    private var modernCommittedPrefixText = ""

    private var microphoneCaptureSession: AVCaptureSession?
    private var applicationAudioCapture: ApplicationAudioCapture?

    private var transcriptHandler: (@MainActor (RecognizedSentence) -> Void)?
    private var partialHandler: (@MainActor (DraftSegment?) -> Void)?
    private var errorHandler: (@MainActor (String) -> Void)?
    @MainActor private var recentCommittedSentenceHistory: [RecentCommittedSentence] = []

    private func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: interfaceLanguageID, arguments: arguments)
    }

    private func localizedErrorDescription(_ error: Error) -> String {
        AppLocalization.localizedErrorDescription(error, languageID: interfaceLanguageID)
    }

    // MARK: Draft state (accessed only on captureQueue)
    private var modeConfig: ModeConfig = .balanced
    private var currentDraftId = UUID()
    private var lastDraftText = ""
    private var lastDraftTextChangeTime = Date.distantPast
    private var lastRecognitionResultTime = Date.distantPast
    private var draftChangeHistory: [(text: String, time: Date)] = []
    private var draftPrefixCandidate = ""
    private var draftPrefixCandidateTime = Date.distantPast
    private var confirmedStablePrefixLength = 0

    // MARK: Silence-commit timer (captureQueue)
    // Fires when the ASR stops delivering new results — i.e. the user has paused.
    // This is more reliable than measuring inter-word gaps because the last word in
    // a sentence has no "next segment" and therefore never triggers a pause boundary.
    private var silenceCommitTimer: DispatchSourceTimer?
    private var latestSegments: [SFTranscriptionSegment] = []
    private var latestFormattedText: NSString = ""

    // MARK: Silero VAD (captureQueue)
    private var vadEngine: SessionVADEngine?
    private var lastVADProbability: Float = 0.0
    private var vadSilenceCommitTimer: DispatchSourceTimer?
    private var noiseFloorRMS: Float = 0.0012
    private var highPassPreviousInput: Float = 0.0
    private var highPassPreviousOutput: Float = 0.0

    private func runOnCaptureQueue<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private enum SilenceCommitTrigger {
        case asrInactivity
        case vadOffset
    }

    func start(
        source: InputSource,
        localeIdentifier: String,
        interfaceLanguageID: String,
        modeConfig: ModeConfig = .balanced,
        contextualStrings: [String] = [],
        transcriptHandler: @escaping @MainActor (RecognizedSentence) -> Void,
        partialHandler: @escaping @MainActor (DraftSegment?) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void
    ) async throws {
        self.transcriptHandler = transcriptHandler
        self.partialHandler = partialHandler
        self.modeConfig = modeConfig
        self.recognitionContextualStrings = sanitizeContextualStrings(contextualStrings)
        self.activeLocaleIdentifier = localeIdentifier
        self.interfaceLanguageID = interfaceLanguageID
        self.errorHandler = errorHandler
        await MainActor.run {
            recentCommittedSentenceHistory.removeAll()
        }

        try await requestRequiredPermissions(for: source)
        if try await configureModernSpeechRecognizer(localeIdentifier: localeIdentifier) == false {
            try await runOnCaptureQueue {
                try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
            }
        }

        switch source.category {
        case .microphone:
            try await runOnCaptureQueue {
                try self.startMicrophoneCapture(deviceUniqueID: source.detail)
            }
        case .application:
            let captureDescriptor = try await MainActor.run {
                try self.makeApplicationCaptureDescriptor(for: source)
            }
            try await runOnCaptureQueue {
                try self.startApplicationAudioCapture(descriptor: captureDescriptor)
            }
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            self?.stopOnCaptureQueue()
        }
    }

    private func stopOnCaptureQueue() {
        cancelSilenceTimer()
        cancelVADSilenceTimer()

        microphoneCaptureSession?.stopRunning()
        microphoneCaptureSession = nil

        applicationAudioCapture?.stop()
        applicationAudioCapture = nil

        stopModernSpeechRecognizer()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        activeLocaleIdentifier = nil
        resetAudioProcessingState()
        resetLegacyTranscriptionState()

        vadEngine = nil
        lastVADProbability = 0

        resetModernTranscriptionState()
        partialHandler = nil
        resetDraftState()
        Task { @MainActor [weak self] in
            self?.recentCommittedSentenceHistory.removeAll()
        }
    }

    private func requestRequiredPermissions(for source: InputSource) async throws {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        switch speechStatus {
        case .authorized:
            break
        case .notDetermined:
            let granted = await requestSpeechAuthorization()
            guard granted else {
                throw SessionError.speechPermissionDenied
            }
        case .denied, .restricted:
            throw SessionError.speechPermissionDenied
        @unknown default:
            throw SessionError.speechPermissionDenied
        }

        switch source.category {
        case .microphone:
            let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

            switch microphoneStatus {
            case .authorized:
                break
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    throw SessionError.microphonePermissionDenied
                }
            case .denied, .restricted:
                throw SessionError.microphonePermissionDenied
            @unknown default:
                throw SessionError.microphonePermissionDenied
            }
        case .application:
            break
        }
    }

    private func configureSpeechRecognizer(localeIdentifier: String) throws {
        stopModernSpeechRecognizer()
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SessionError.unsupportedSpeechLocale(localeIdentifier)
        }

        guard recognizer.isAvailable else {
            throw SessionError.unavailableSpeechRecognizer(localeIdentifier)
        }

        let request = makeRecognitionRequest()

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionTask = task
        recognitionBackend = .legacy
        resetAudioProcessingState()
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        cancelSilenceTimer()
        resetDraftState()

        // Initialize Silero VAD engine.
        do {
            vadEngine = try SessionVADEngine()
        } catch {
            // VAD is optional — fall back to implicit ASR-based silence detection.
            vadEngine = nil
            Task {
                await emitError(
                    localized(
                        .sileroVadUnavailableFallbackFormat,
                        localizedErrorDescription(error)
                    )
                )
            }
        }
    }

    private func configureModernSpeechRecognizer(localeIdentifier: String) async throws -> Bool {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            return false
        }

        do {
            return try await configureSpeechAnalyzerRecognizer(localeIdentifier: localeIdentifier)
        } catch {
            stopModernSpeechRecognizer()
            return false
        }
    }

    @available(macOS 26.0, *)
    private func configureSpeechAnalyzerRecognizer(localeIdentifier: String) async throws -> Bool {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return false
        }

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        try await ensureSpeechAnalyzerAssetsIfNeeded(for: transcriber, locale: resolvedLocale)

        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        let context = AnalysisContext()
        if recognitionContextualStrings.isEmpty == false {
            context.contextualStrings[.general] = recognitionContextualStrings
        }
        try await analyzer.setContext(context)

        let preferredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: processingFormat
        ) ?? processingFormat
        try await analyzer.prepareToAnalyze(in: preferredFormat)

        let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(12)) { continuation in
            self.analyzerInputContinuationState = continuation
        }

        modernResultsTask?.cancel()
        modernResultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.captureQueue.async { [weak self] in
                        self?.processModernRecognitionResult(result)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.fallbackFromSpeechAnalyzer(error)
            }
        }

        modernAnalyzerTask?.cancel()
        modernAnalyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch is CancellationError {
                return
            } catch {
                self?.fallbackFromSpeechAnalyzer(error)
            }
        }

        speechAnalyzerState = analyzer
        speechTranscriberState = transcriber
        analyzerInputFormat = preferredFormat
        recognitionBackend = .speechAnalyzer
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        audioConverter = nil
        audioConverterInputSignature = nil
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        resetDraftState()
        lastModernCommittedResultIdentity = nil

        // Initialize Silero VAD engine for draft confidence / silence scoring only.
        do {
            vadEngine = try SessionVADEngine()
        } catch {
            vadEngine = nil
        }

        return true
    }

    @available(macOS 26.0, *)
    private func ensureSpeechAnalyzerAssetsIfNeeded(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        let installedLocales = await Set(SpeechTranscriber.installedLocales.map(\.identifier))
        if installedLocales.contains(locale.identifier) {
            return
        }

        if let installer = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installer.downloadAndInstall()
        }
    }

    private func stopModernSpeechRecognizer() {
        modernAnalyzerTask?.cancel()
        modernAnalyzerTask = nil
        modernResultsTask?.cancel()
        modernResultsTask = nil
        lastModernCommittedResultIdentity = nil
        recognitionBackend = .legacy
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil
        resetModernTranscriptionState()

        if #available(macOS 26.0, *) {
            (analyzerInputContinuationState as? AsyncStream<AnalyzerInput>.Continuation)?.finish()
            analyzerInputContinuationState = nil
            let analyzer = speechAnalyzerState as? SpeechAnalyzer
            speechAnalyzerState = nil
            speechTranscriberState = nil
            analyzerInputFormat = nil

            if let analyzer {
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
        }
    }

    private func fallbackFromSpeechAnalyzer(_ error: Error) {
        captureQueue.async { [weak self] in
            guard let self,
                  self.recognitionBackend == .speechAnalyzer,
                  let localeIdentifier = self.activeLocaleIdentifier else {
                return
            }

            self.stopModernSpeechRecognizer()

            do {
                try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
            } catch {
                Task {
                    await self.emitError(
                        self.localized(
                            .speechRecognitionStoppedFormat,
                            self.localizedErrorDescription(error)
                        )
                    )
                }
            }
        }
    }

    private func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = recognitionContextualStrings
        return request
    }

    private func sanitizeContextualStrings(_ candidates: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  trimmed.count <= 40 else {
                continue
            }

            let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(normalized).inserted else {
                continue
            }

            result.append(trimmed)
            if result.count >= 60 {
                break
            }
        }

        return result
    }

    private func resetAudioProcessingState() {
        preprocessingConverter = nil
        preprocessingConverterInputSignature = nil
        audioConverter = nil
        audioConverterInputSignature = nil
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil
        noiseFloorRMS = 0.0012
        highPassPreviousInput = 0
        highPassPreviousOutput = 0
    }

    private func resetModernTranscriptionState() {
        latestModernText = ""
        modernCommittedPrefixText = ""
    }

    private func resetLegacyTranscriptionState() {
        committedSegmentCount = 0
        committedAudioBoundaryTime = nil
        latestSegments = []
        latestFormattedText = ""
    }

    private func startMicrophoneCapture(deviceUniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw SessionError.missingMicrophoneDevice
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(input) else {
            throw SessionError.failedToStartCapture(
                localized(.couldNotAddSelectedMicrophoneToCaptureSession)
            )
        }

        guard session.canAddOutput(output) else {
            throw SessionError.failedToStartCapture(
                localized(.couldNotAddMicrophoneAudioOutput)
            )
        }

        session.beginConfiguration()
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

        microphoneCaptureSession = session
        session.startRunning()
    }

    @MainActor
    private func makeApplicationCaptureDescriptor(for source: InputSource) throws -> ApplicationCaptureDescriptor {
        ApplicationCaptureDescriptor(
            appName: source.name,
            processObjectIDs: try resolveApplicationProcessObjectIDs(for: source),
            readStreamFailureMessage: localized(.failedToReadCapturedAudioStreamFormat, source.name)
        )
    }

    private func startApplicationAudioCapture(descriptor: ApplicationCaptureDescriptor) throws {
        let capture = ApplicationAudioCapture(
            appName: descriptor.appName,
            processObjectIDs: descriptor.processObjectIDs,
            readStreamFailureMessage: descriptor.readStreamFailureMessage,
            queue: captureQueue,
            audioHandler: { [weak self] buffer in
                self?.append(audioBuffer: buffer)
            },
            errorHandler: { [weak self] message in
                Task {
                    await self?.emitError(message)
                }
            }
        )

        do {
            try capture.start()
            applicationAudioCapture = capture
        } catch let error as ApplicationAudioCapture.CaptureError {
            throw mapApplicationCaptureError(error)
        } catch {
            throw SessionError.failedToStartCapture(
                localized(
                    .failedToStageWithReasonFormat,
                    "start application audio capture",
                    localizedErrorDescription(error)
                )
            )
        }
    }

    private func resolveApplicationProcessObjectIDs(for source: InputSource) throws -> [AudioObjectID] {
        let runningApp = try resolveRunningApplication(for: source)
        let system = AudioHardwareSystem.shared
        let audioProcesses = try system.processes
        let targetAssociation = ApplicationProcessAssociation(runningApplication: runningApp)
        var relatedProcessIDs: [AudioObjectID] = []
        var seen = Set<AudioObjectID>()

        for process in audioProcesses {
            let processID = try process.pid
            let processObjectID = process.id
            let processBundleIdentifier = (try? process.bundleID) ?? ""
            let processAppBundleURL = applicationBundleURL(forProcessID: processID)
            let executablePath = executablePath(forProcessID: processID)

            let matchesMainProcess = processID == runningApp.processIdentifier
            let matchesBundleIdentifier = targetAssociation.matchesExactBundleIdentifier(processBundleIdentifier)
            let matchesBundleURL = targetAssociation.matchesApplicationBundleURL(processAppBundleURL)
            let matchesHelperBundle = targetAssociation.matchesHelperBundleIdentifier(processBundleIdentifier)
            let matchesHelperPath = targetAssociation.matchesHelperExecutablePath(executablePath)

            guard matchesMainProcess
                || matchesBundleIdentifier
                || matchesBundleURL
                || matchesHelperBundle
                || matchesHelperPath else {
                    continue
                }

            if seen.insert(processObjectID).inserted {
                relatedProcessIDs.append(processObjectID)
            }
        }

        if relatedProcessIDs.isEmpty {
            if let exactProcess = try system.process(for: runningApp.processIdentifier) {
                return [exactProcess.id]
            }

            throw SessionError.applicationNotProducingAudio(source.name)
        }

        return relatedProcessIDs
    }

    private func resolveRunningApplication(for source: InputSource) throws -> NSRunningApplication {
        let runningApps = NSWorkspace.shared.runningApplications
        let application: NSRunningApplication?

        if let processIdentifier = source.processIdentifierHint {
            application = runningApps.first(where: { $0.processIdentifier == processIdentifier })
        } else {
            application = runningApps.first(where: { $0.bundleIdentifier == source.detail })
        }

        guard let application else {
            throw SessionError.missingApplication(source.name)
        }

        return application
    }

    private func append(sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        // Convert to PCMBuffer so gain processing can be applied (same path as app audio).
        // Fall back to direct append if conversion fails.
        if let pcmBuffer = pcmBuffer(from: sampleBuffer) {
            append(audioBuffer: pcmBuffer)
        } else if recognitionBackend == .legacy {
            recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        }
    }

    /// Converts a CMSampleBuffer from AVCaptureSession into an AVAudioPCMBuffer so it can
    /// share the format-conversion and gain-boost pipeline in append(audioBuffer:).
    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        var mutableASBD = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }

    private func append(audioBuffer: AVAudioPCMBuffer) {
        guard audioBuffer.frameLength > 0 else {
            return
        }

        guard let processingBuffer = prepareProcessingBuffer(from: audioBuffer) else {
            return
        }

        let audioLevels = cleanUpSpeechBuffer(processingBuffer)
        boostIfQuiet(buffer: processingBuffer, levels: audioLevels)

        if let vadEngine {
            let vadResult = vadEngine.process(buffer: processingBuffer)
            lastVADProbability = vadResult.speechProbability

            if vadResult.containsSpeechOffset {
                scheduleVADSilenceCommit()
            }
            if vadResult.containsSpeechOnset {
                cancelVADSilenceTimer()
            }
        }

        if recognitionBackend == .speechAnalyzer {
            appendToSpeechAnalyzer(processingBuffer)
            return
        }

        guard let recognitionRequest else {
            return
        }

        guard let recognizerBuffer = makeRecognizerBuffer(from: processingBuffer, nativeFormat: recognitionRequest.nativeAudioFormat) else {
            return
        }

        // Always forward audio to the recognizer — VAD is used only
        // for silence-commit timing, not to gate the audio stream.
        recognitionRequest.append(recognizerBuffer)
    }

    private func appendToSpeechAnalyzer(_ processingBuffer: AVAudioPCMBuffer) {
        guard #available(macOS 26.0, *),
              recognitionBackend == .speechAnalyzer,
              let continuation = analyzerInputContinuationState as? AsyncStream<AnalyzerInput>.Continuation else {
            return
        }

        guard let analyzerBuffer = makeSpeechAnalyzerBuffer(from: processingBuffer) else {
            return
        }

        continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
    }

    private func prepareProcessingBuffer(from audioBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if audioBuffer.format.matches(processingFormat) {
            guard let copiedBuffer = copyPCMBuffer(audioBuffer) else {
                Task {
                    await emitError(localized(.failedToCopyCapturedAudioForSpeechPreprocessing))
                }
                return nil
            }
            return copiedBuffer
        }

        let inputSignature = AudioFormatSignature(audioBuffer.format)
        if preprocessingConverterInputSignature != inputSignature {
            preprocessingConverter = AVAudioConverter(from: audioBuffer.format, to: processingFormat)
            preprocessingConverterInputSignature = inputSignature
        }

        guard let preprocessingConverter else {
            Task {
                await emitError(localized(.failedToPrepareSpeechPreprocessingAudioConverter))
            }
            return nil
        }

        return convertBuffer(
            audioBuffer,
            using: preprocessingConverter,
            to: processingFormat,
            allocationError: localized(.failedToAllocateSpeechPreprocessingAudioBuffer),
            failurePrefix: localized(.failedToPreprocessCapturedAudio)
        )
    }

    private func makeRecognizerBuffer(
        from processingBuffer: AVAudioPCMBuffer,
        nativeFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if processingBuffer.format.matches(nativeFormat) {
            return processingBuffer
        }

        let inputSignature = AudioFormatSignature(processingBuffer.format)
        if audioConverterInputSignature != inputSignature {
            audioConverter = AVAudioConverter(from: processingBuffer.format, to: nativeFormat)
            audioConverterInputSignature = inputSignature
        }

        guard let audioConverter else {
            Task {
                await emitError(localized(.failedToPrepareAudioConverterForSpeechRecognition))
            }
            return nil
        }

        return convertBuffer(
            processingBuffer,
            using: audioConverter,
            to: nativeFormat,
            allocationError: localized(.failedToAllocateSpeechRecognitionAudioBuffer),
            failurePrefix: localized(.failedToConvertCapturedAudioForSpeechRecognition)
        )
    }

    private func makeSpeechAnalyzerBuffer(from processingBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard #available(macOS 26.0, *),
              let analyzerInputFormat else {
            return processingBuffer
        }

        if processingBuffer.format.matches(analyzerInputFormat) {
            return processingBuffer
        }

        let inputSignature = AudioFormatSignature(processingBuffer.format)
        if modernAudioConverterInputSignature != inputSignature {
            modernAudioConverter = AVAudioConverter(from: processingBuffer.format, to: analyzerInputFormat)
            modernAudioConverterInputSignature = inputSignature
        }

        guard let modernAudioConverter else {
            return nil
        }

        return convertBuffer(
            processingBuffer,
            using: modernAudioConverter,
            to: analyzerInputFormat,
            allocationError: localized(.failedToAllocateSpeechAnalyzerAudioBuffer),
            failurePrefix: localized(.failedToConvertCapturedAudioForSpeechAnalyzer)
        )
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat,
        allocationError: String,
        failurePrefix: String
    ) -> AVAudioPCMBuffer? {
        let outputFrameCapacity = max(
            AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate)),
            1
        )

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            Task { await emitError(allocationError) }
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            Task {
                await emitError("\(failurePrefix): \(conversionError.localizedDescription)")
            }
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            guard outputBuffer.frameLength > 0 else { return nil }
            return outputBuffer
        case .error:
            Task {
                await emitError("\(failurePrefix).")
            }
            return nil
        @unknown default:
            return nil
        }
    }

    private func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)

        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else {
                continue
            }

            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
        }

        return copy
    }

    private func cleanUpSpeechBuffer(_ buffer: AVAudioPCMBuffer) -> AudioLevelStats {
        guard let channelData = buffer.floatChannelData else {
            return AudioLevelStats(peak: 0, rms: 0)
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return AudioLevelStats(peak: 0, rms: 0)
        }

        let samples = channelData[0]
        let highPassAlpha: Float = 0.995
        var sumSquares: Float = 0
        var peak: Float = 0

        for index in 0..<frameCount {
            let input = samples[index]
            let filtered = input - highPassPreviousInput + highPassAlpha * highPassPreviousOutput
            highPassPreviousInput = input
            highPassPreviousOutput = filtered
            samples[index] = filtered

            let magnitude = abs(filtered)
            sumSquares += magnitude * magnitude
            if magnitude > peak {
                peak = magnitude
            }
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        updateNoiseFloorEstimate(rms: rms, peak: peak)
        return AudioLevelStats(peak: peak, rms: rms)
    }

    private func updateNoiseFloorEstimate(rms: Float, peak: Float) {
        let clampedRMS = min(max(rms, 0.0003), 0.03)
        let likelyNoiseOnly = peak < 0.02 || rms <= noiseFloorRMS * 1.6
        let smoothing: Float = likelyNoiseOnly ? 0.08 : 0.01
        noiseFloorRMS = max(0.0005, min(0.02, noiseFloorRMS * (1 - smoothing) + clampedRMS * smoothing))
    }

    // MARK: - Audio gain boost

    /// Amplifies a Float32 PCM buffer when the signal is too quiet for the ASR's VAD to
    /// detect reliably. Only applies when the peak is in the "quiet speech" range
    /// (0.002–0.30); leaves silence and normal-to-loud audio untouched.
    ///
    /// - Quiet speech range: peak 0.002 – 0.30 → boost toward target peak 0.35 (up to 4×)
    /// - Silence (< 0.002): no boost (would just amplify noise floor)
    /// - Normal/loud (≥ 0.30): no boost (already loud enough; avoid clipping)
    private func boostIfQuiet(buffer: AVAudioPCMBuffer, levels: AudioLevelStats) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        let peak = levels.peak
        let rms = levels.rms
        let speechFloor = max(0.006, noiseFloorRMS * 4.0)
        let targetPeak: Float = 0.35
        guard peak > speechFloor,
              rms > max(noiseFloorRMS * 1.8, 0.0015),
              peak < targetPeak else {
            return
        }

        let gain = min(targetPeak / peak, 3.0)
        for ch in 0..<channelCount {
            let ptr = channelData[ch]
            for i in 0..<frameCount {
                var v = ptr[i] * gain
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                ptr[i] = v
            }
        }
    }

    @MainActor
    private func emitRecognizedSentence(_ sentence: RecognizedSentence) {
        transcriptHandler?(sentence)
    }

    @MainActor
    private func emitRecognizedText(_ text: String, promotionSegmentID: UUID? = nil) {
        let sentenceTexts = splitCommittedEmissionUnits(in: text)

        for (index, sentenceText) in sentenceTexts.enumerated() {
            emitRecognizedSentence(
                RecognizedSentence(
                    text: sentenceText,
                    promotionSegmentID: index == 0 ? promotionSegmentID : nil
                )
            )
        }
    }

    @MainActor
    private func emitCommittedSequence(
        _ emissions: [CommittedEmission],
        clearDraftAfter: Bool = false
    ) {
        pruneRecentCommittedSentenceHistory()

        for emission in emissions {
            let sentenceTexts = splitCommittedEmissionUnits(in: emission.text)
            var pendingPromotionID = emission.promotionSegmentID

            for sentenceText in sentenceTexts {
                guard let preparedSentence = prepareCommittedSentenceForEmission(sentenceText) else {
                    continue
                }

                emitRecognizedSentence(
                    RecognizedSentence(
                        text: preparedSentence,
                        promotionSegmentID: pendingPromotionID
                    )
                )
                rememberCommittedSentence(preparedSentence)
                pendingPromotionID = nil
            }
        }

        if clearDraftAfter {
            emitPartialDraft(nil)
        }
    }

    private func splitCommittedEmissionUnits(in text: String) -> [String] {
        splitRecognizedSentences(in: text).flatMap(splitDialogueClausesIfNeeded)
    }

    private func splitDialogueClausesIfNeeded(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return []
        }

        let nsText = trimmed as NSString
        let matches = Self.dialogueClauseSeparatorRegex.matches(
            in: trimmed,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard matches.count == 1,
              let separatorRange = matches.first?.range else {
            return [trimmed]
        }

        let left = nsText.substring(to: separatorRange.location).trimmingCharacters(in: .whitespacesAndNewlines)
        let rightStart = separatorRange.location + separatorRange.length
        let right = nsText.substring(from: rightStart).trimmingCharacters(in: .whitespacesAndNewlines)

        guard shouldSplitDialogueClauses(left: left, right: right) else {
            return [trimmed]
        }

        return [left, right]
    }

    private func shouldSplitDialogueClauses(left: String, right: String) -> Bool {
        guard left.isEmpty == false,
              right.isEmpty == false,
              left.containsCJKCharacters || right.containsCJKCharacters else {
            return false
        }

        let maxClauseLength = 18
        guard left.count <= maxClauseLength,
              right.count <= maxClauseLength else {
            return false
        }

        let leftLooksComplete = Self.dialogueClauseEndingSuffixes.contains(where: { left.hasSuffix($0) })
            || left.containsSentenceTerminator
        let rightLooksLikeNewTurn = Self.dialogueClauseLeadingPhrases.contains(where: { right.hasPrefix($0) })

        return leftLooksComplete || rightLooksLikeNewTurn
    }

    @MainActor
    private func emitPartialDraft(_ draft: DraftSegment?) {
        partialHandler?(draft)
    }

    @MainActor
    private func emitError(_ message: String) {
        errorHandler?(message)
    }

    @MainActor
    private func prepareCommittedSentenceForEmission(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let comparable = comparableCommittedSentenceText(trimmed)
        guard comparable.isEmpty == false else {
            return nil
        }

        if recentCommittedSentenceHistory.contains(where: { $0.comparableText == comparable }) {
            return nil
        }

        if let extendedSentence = trimmedCommittedPrefixContinuation(from: trimmed) {
            let extendedComparable = comparableCommittedSentenceText(extendedSentence)
            guard extendedComparable.isEmpty == false,
                  recentCommittedSentenceHistory.contains(where: { $0.comparableText == extendedComparable }) == false else {
                return nil
            }

            return extendedSentence
        }

        let bestOverlap = recentCommittedSentenceHistory
            .suffix(3)
            .map { leadingOverlapLength(previous: $0.rawText, current: trimmed) }
            .max() ?? 0

        let candidateText: String
        if shouldTrimLeadingOverlap(length: bestOverlap, in: trimmed) {
            candidateText = dropLeadingCharacters(bestOverlap, from: trimmed)
                .trimmingCharacters(in: Self.leadingOverlapTrimCharacterSet)
        } else {
            candidateText = trimmed
        }

        guard candidateText.isEmpty == false else {
            return nil
        }

        let candidateComparable = comparableCommittedSentenceText(candidateText)
        guard candidateComparable.isEmpty == false,
              recentCommittedSentenceHistory.contains(where: { $0.comparableText == candidateComparable }) == false else {
            return nil
        }

        return candidateText
    }

    @MainActor
    private func rememberCommittedSentence(_ text: String) {
        let comparable = comparableCommittedSentenceText(text)
        guard comparable.isEmpty == false else {
            return
        }

        recentCommittedSentenceHistory.append(
            RecentCommittedSentence(
                rawText: text,
                comparableText: comparable,
                time: Date(),
                allowsPrefixContinuation: text.containsSentenceTerminator == false
            )
        )
        pruneRecentCommittedSentenceHistory()
    }

    @MainActor
    private func trimmedCommittedPrefixContinuation(from text: String) -> String? {
        let now = Date()

        for previous in recentCommittedSentenceHistory.suffix(3).reversed() {
            guard previous.allowsPrefixContinuation,
                  now.timeIntervalSince(previous.time) <= Self.committedPrefixContinuationWindow,
                  text.count > previous.rawText.count,
                  text.hasPrefix(previous.rawText) else {
                continue
            }

            let remainder = dropLeadingCharacters(previous.rawText.count, from: text)
                .trimmingCharacters(in: Self.leadingOverlapTrimCharacterSet)
            guard remainder.isEmpty == false else {
                continue
            }

            return remainder
        }

        return nil
    }

    @MainActor
    private func pruneRecentCommittedSentenceHistory() {
        let now = Date()
        recentCommittedSentenceHistory.removeAll { now.timeIntervalSince($0.time) > 8.0 }
        if recentCommittedSentenceHistory.count > Self.recentCommittedSentenceLimit {
            recentCommittedSentenceHistory.removeFirst(
                recentCommittedSentenceHistory.count - Self.recentCommittedSentenceLimit
            )
        }
    }

    private func comparableCommittedSentenceText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: Self.committedComparisonTrimCharacterSet)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func leadingOverlapLength(previous: String, current: String) -> Int {
        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        let maxOverlap = min(previousCharacters.count, currentCharacters.count)

        guard maxOverlap > 0 else {
            return 0
        }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(previousCharacters.suffix(overlap)) == Array(currentCharacters.prefix(overlap)) {
                return overlap
            }
        }

        return 0
    }

    private func shouldTrimLeadingOverlap(length: Int, in text: String) -> Bool {
        guard length > 0, text.isEmpty == false else {
            return false
        }

        let minimumOverlap = text.containsCJKCharacters
            ? Self.minimumCJKLeadingOverlapCharacters
            : Self.minimumLatinLeadingOverlapCharacters
        let overlapRatio = Double(length) / Double(text.count)
        return length >= minimumOverlap && overlapRatio >= 0.35
    }

    private func dropLeadingCharacters(_ count: Int, from text: String) -> String {
        guard count > 0 else {
            return text
        }

        var index = text.startIndex
        var remaining = count
        while remaining > 0, index < text.endIndex {
            index = text.index(after: index)
            remaining -= 1
        }

        return String(text[index...])
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func splitRecognizedSentences(in text: String) -> [String] {
        let normalizedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.isEmpty == false else {
            return []
        }

        let nsText = normalizedText as NSString
        let sentenceRanges = sentenceRanges(in: nsText)
        guard sentenceRanges.isEmpty == false else {
            return [normalizedText]
        }

        return sentenceRanges.compactMap { range in
            let sentence = nsText.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
    }

    private func sentenceRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.bySentences, .substringNotRequired]
        ) { _, substringRange, _, _ in
            guard substringRange.length > 0 else {
                return
            }
            ranges.append(substringRange)
        }

        return ranges
    }

    private func pendingModernText(from fullText: String) -> String {
        guard modernCommittedPrefixText.isEmpty == false else {
            return fullText
        }
        if fullText.hasPrefix(modernCommittedPrefixText) {
            return String(fullText.dropFirst(modernCommittedPrefixText.count))
        }

        let committedSentences = splitRecognizedSentences(in: modernCommittedPrefixText)
        let nsFullText = fullText as NSString
        let fullSentenceRanges = sentenceRanges(in: nsFullText)
        let fullSentences = fullSentenceRanges.map {
            nsFullText.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard committedSentences.isEmpty == false,
              fullSentences.isEmpty == false else {
            return fullText
        }

        let committedComparable = committedSentences.map(comparableCommittedSentenceText)
        let fullComparable = fullSentences.map(comparableCommittedSentenceText)
        let maxOverlap = min(committedComparable.count, fullComparable.count)

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(committedComparable.suffix(overlap)) == Array(fullComparable.prefix(overlap)) {
                let matchedRange = fullSentenceRanges[overlap - 1]
                let nextLocation = matchedRange.location + matchedRange.length
                guard nextLocation < nsFullText.length else {
                    return ""
                }

                return nsFullText.substring(from: nextLocation)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return fullText
    }

    private func committableModernText(in rawText: String) -> (committedRawText: String, remainingRawText: String)? {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return nil
        }

        let nsText = rawText as NSString
        let sentenceRanges = sentenceRanges(in: nsText)
        guard sentenceRanges.isEmpty == false else {
            return nil
        }

        if String(trimmedText.suffix(1)).containsSentenceTerminator {
            return (rawText, "")
        }

        guard sentenceRanges.count >= 2,
              let trailingSentenceRange = sentenceRanges.last,
              trailingSentenceRange.location > 0 else {
            return nil
        }

        let committedRawText = nsText.substring(to: trailingSentenceRange.location)
        let remainingRawText = nsText.substring(from: trailingSentenceRange.location)
        guard committedRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        return (committedRawText, remainingRawText)
    }

    private func boundaryGapText(
        afterSegmentAt index: Int,
        in formattedText: NSString,
        segments: [SFTranscriptionSegment]
    ) -> String {
        let currentRange = segments[index].substringRange
        let currentEndLocation = currentRange.location + currentRange.length
        let nextStartLocation = index < segments.count - 1
            ? segments[index + 1].substringRange.location
            : formattedText.length

        guard nextStartLocation > currentEndLocation else {
            return ""
        }

        return formattedText.substring(
            with: NSRange(location: currentEndLocation, length: nextStartLocation - currentEndLocation)
        )
    }

    private func emittedTextRange(
        in formattedText: NSString,
        segments: [SFTranscriptionSegment],
        from startIndex: Int,
        to endIndex: Int
    ) -> NSRange {
        let startLocation = segments[startIndex].substringRange.location
        let endLocation = endIndex < segments.count - 1
            ? segments[endIndex + 1].substringRange.location
            : formattedText.length

        return NSRange(location: startLocation, length: max(0, endLocation - startLocation))
    }

    private func processRecognitionResult(_ result: SFSpeechRecognitionResult) {
        lastRecognitionResultTime = Date()
        let transcription = result.bestTranscription
        let segments = transcription.segments
        let formattedText = transcription.formattedString as NSString
        var committedEmissions: [CommittedEmission] = []

        // Always save the latest transcript so the silence timer can commit it
        latestSegments = segments
        latestFormattedText = formattedText

        alignCommittedSegmentCount(to: segments)

        guard committedSegmentCount < segments.count else {
            cancelSilenceTimer()
            // The task has no more pending text. If it just finished, restart it.
            if result.isFinal { restartRecognitionTask() }
            return
        }

        var sentenceStartIndex = committedSegmentCount

        for index in committedSegmentCount..<segments.count {
            let segment = segments[index]
            let nextPauseDuration: TimeInterval?

            if index < segments.count - 1 {
                let nextSegment = segments[index + 1]
                nextPauseDuration = nextSegment.timestamp - (segment.timestamp + segment.duration)
            } else {
                nextPauseDuration = nil
            }

            let currentSegmentCount = index - sentenceStartIndex + 1
            let sentenceStartTimestamp = segments[sentenceStartIndex].timestamp
            let sentenceEndTimestamp = segment.timestamp + segment.duration
            let currentSentenceDuration = max(sentenceEndTimestamp - sentenceStartTimestamp, 0)
            let gapText = boundaryGapText(afterSegmentAt: index, in: formattedText, segments: segments)

            // Apple may place restored punctuation in the gap before the next segment
            // rather than inside the current segment substring.
            let punctuationBoundary = segment.substring.containsSentenceTerminator || gapText.containsSentenceTerminator
            // 0.85 s was too conservative and often merged two short sentences.
            let strongPauseBoundary = (nextPauseDuration ?? 0) >= max(0.55, Double(modeConfig.minSilenceCommitMs) / 1000.0 + 0.24)
            // Char-length limit removed: 40 chars is only ~6 English words and caused
            // false mid-sentence cuts. Segment count + audio duration are sufficient.
            let forcedBoundary = currentSegmentCount >= 18
                || currentSentenceDuration >= modeConfig.maxChunkAudioSec
            let finalBoundary = result.isFinal && index == segments.count - 1

            guard punctuationBoundary || strongPauseBoundary || forcedBoundary || finalBoundary else {
                continue
            }

            // When a purely forced cut lands close to the end of available segments,
            // absorb the tiny tail rather than leaving a 1–2 word orphan that would
            // be emitted as a meaningless standalone sentence by the silence timer.
            var commitEndIndex = index
            if forcedBoundary && !punctuationBoundary && !strongPauseBoundary && !finalBoundary {
                let tailCount = (segments.count - 1) - index
                if tailCount > 0 && tailCount <= 2 {
                    commitEndIndex = segments.count - 1
                }
            }

            let commitRange = emittedTextRange(
                in: formattedText,
                segments: segments,
                from: sentenceStartIndex,
                to: commitEndIndex
            )

            let sentenceText = formattedText.substring(with: commitRange)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let committedDraftID = currentDraftId

            if sentenceText.isEmpty == false {
                committedEmissions.append(
                    CommittedEmission(
                        text: sentenceText,
                        promotionSegmentID: committedDraftID
                    )
                )
            }

            committedAudioBoundaryTime = segmentEndTime(for: segments[commitEndIndex])
            sentenceStartIndex = commitEndIndex + 1
            committedSegmentCount = sentenceStartIndex
            resetDraftState()

            // If we consumed all remaining segments (tail absorption or final boundary),
            // stop iterating to avoid referencing segments beyond the committed range.
            if commitEndIndex >= segments.count - 1 { break }
        }

        let shouldClearDraftAfterCommit = committedSegmentCount >= segments.count

        // Emit draft update for the uncommitted tail
        if committedSegmentCount < segments.count {
            emitDraftUpdate(
                draftRange: committedSegmentCount..<segments.count,
                allSegments: segments,
                formattedText: formattedText
            )
            // Schedule a silence-based commit: if no new ASR result arrives within
            // silenceCommitDeadlineMs, the user has paused → commit whatever we have.
            scheduleSilenceCommit()
        } else {
            cancelSilenceTimer()
        }

        if committedEmissions.isEmpty == false {
            Task { [committedEmissions, shouldClearDraftAfterCommit] in
                await emitCommittedSequence(
                    committedEmissions,
                    clearDraftAfter: shouldClearDraftAfterCommit
                )
            }
        } else if shouldClearDraftAfterCommit {
            Task { await emitPartialDraft(nil) }
        }

        // SFSpeechRecognizer marks isFinal = true when its internal session ends
        // (after a long pause or utterance limit). Once final, the task delivers no
        // more callbacks — new audio is silently ignored. Restart immediately so
        // recognition continues without interruption.
        if result.isFinal {
            restartRecognitionTask()
        }
    }

    /// Replaces the spent recognition task with a fresh one so recording continues
    /// indefinitely. Called on captureQueue whenever isFinal is received or on error recovery.
    private func restartRecognitionTask() {
        guard let recognizer = speechRecognizer else { return }

        // Cleanly end the old request before discarding it.
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        vadEngine?.reset()

        // Bump generation BEFORE creating the new handler so any late callbacks
        // dispatched by the cancelled task are silently ignored.
        recognitionGeneration &+= 1

        let request = makeRecognitionRequest()

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        recognitionRequest = request
        recognitionTask = task
        // Reset the converter — new request may have a different nativeAudioFormat.
        resetAudioProcessingState()
        resetLegacyTranscriptionState()
        resetModernTranscriptionState()
        resetDraftState()
        Task { await emitPartialDraft(nil) }
    }

    /// Builds the result/error handler used by every recognition task.
    ///
    /// On transient errors (no speech detected, internal failure, etc.) the handler
    /// automatically restarts recognition so the pipeline never goes silent.
    /// Fatal configuration errors (permission denied, unsupported locale) propagate
    /// to the UI so the user knows why things stopped.
    private func makeRecognitionHandler() -> (SFSpeechRecognitionResult?, Error?) -> Void {
        // Capture the generation at handler-creation time. Any callback arriving
        // after a restart (which bumps recognitionGeneration) will be discarded,
        // preventing stale isFinal results from replaying committed sentences.
        let generation = recognitionGeneration
        return { [weak self] result, error in
            if let error {
                let nsError = error as NSError
                // kAFAssistantErrorDomain 216/301 = intentional cancellation from our own
                // restartRecognitionTask / stop calls — ignore silently.
                let isCancellation = nsError.domain == "kAFAssistantErrorDomain"
                    && (nsError.code == 216 || nsError.code == 301)

                if isCancellation { return }

                // For any other error, attempt a silent restart so recording continues.
                // If the recogniser is truly unavailable the restart guard will bail out.
                self?.captureQueue.async { [weak self] in
                    guard let self, self.speechRecognizer != nil,
                          self.recognitionGeneration == generation else { return }
                    self.restartRecognitionTask()
                }
                return
            }

            guard let result else { return }
            self?.captureQueue.async { [weak self] in
                guard let self, self.recognitionGeneration == generation else { return }
                self.processRecognitionResult(result)
            }
        }
    }

    @available(macOS 26.0, *)
    private func processModernRecognitionResult(_ result: SpeechTranscriber.Result) {
        let now = Date()
        lastRecognitionResultTime = now
        let fullText = normalizedTranscriberText(result.text)
        let pendingRawText = pendingModernText(from: fullText)
        let text = pendingRawText.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isFinal {
            let identity = modernResultIdentity(for: result)
            guard identity != lastModernCommittedResultIdentity else { return }
            lastModernCommittedResultIdentity = identity

            cancelSilenceTimer()
            cancelVADSilenceTimer()
            resetModernTranscriptionState()
            let committedDraftID = currentDraftId
            resetDraftState()

            if text.isEmpty == false {
                Task {
                    await emitCommittedSequence(
                        [
                            CommittedEmission(
                                text: text,
                                promotionSegmentID: committedDraftID
                            )
                        ],
                        clearDraftAfter: true
                    )
                }
            } else {
                Task { await emitPartialDraft(nil) }
            }
            return
        }

        guard text.isEmpty == false else {
            latestModernText = ""
            cancelSilenceTimer()
            cancelVADSilenceTimer()
            Task { await emitPartialDraft(nil) }
            return
        }

        observeDraftText(text, at: now)
        latestModernText = pendingRawText
        if let split = committableModernText(in: pendingRawText),
           split.remainingRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           String(text.suffix(1)).containsSentenceTerminator,
           canFastCommitModernBoundary(at: now) {
            let committedText = split.committedRawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard committedText.isEmpty == false else {
                latestModernText = ""
                Task { await emitPartialDraft(nil) }
                return
            }

            cancelSilenceTimer()
            cancelVADSilenceTimer()
            modernCommittedPrefixText += split.committedRawText
            latestModernText = split.remainingRawText
            let committedDraftID = currentDraftId
            resetDraftState()
            Task {
                await emitCommittedSequence(
                    [
                        CommittedEmission(
                            text: committedText,
                            promotionSegmentID: committedDraftID
                        )
                    ],
                    clearDraftAfter: true
                )
            }
            return
        }

        emitDraftUpdate(from: result, text: text)
        scheduleSilenceCommit()
    }

    private func observeDraftText(_ text: String, at now: Date) {
        if text != lastDraftText {
            lastDraftText = text
            lastDraftTextChangeTime = now
            draftChangeHistory.append((text: text, time: now))
        }
        draftChangeHistory.removeAll { now.timeIntervalSince($0.time) > 0.4 }
    }

    private func currentDraftStability(at now: Date) -> (silenceMs: Int, stabilityScore: Float) {
        let silenceMs = Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000)
        let recentChanges = draftChangeHistory.count
        let stabilityScore: Float
        switch recentChanges {
        case 0, 1: stabilityScore = 1.0
        case 2:    stabilityScore = 0.7
        default:   stabilityScore = max(0.1, 0.5 - Float(recentChanges - 2) * 0.15)
        }

        return (silenceMs, stabilityScore)
    }

    private func canFastCommitModernBoundary(at now: Date) -> Bool {
        Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000) >= modernBoundaryCommitStabilityDelayMs
    }

    private func canVADCommitModernDraft(_ rawText: String, at now: Date) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            return false
        }

        guard shouldHoldModernVADCommit(for: text) == false else {
            return false
        }

        let stableForMs = Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000)
        let minimumStableMs = max(vadSilenceCommitDeadlineMs, 260)
        guard stableForMs >= minimumStableMs else {
            return false
        }

        let maxDraftLength = text.containsCJKCharacters ? 14 : 28
        return text.count <= maxDraftLength
    }

    private func shouldHoldModernVADCommit(for text: String) -> Bool {
        guard String(text.suffix(1)).containsSentenceTerminator == false else {
            return false
        }

        if text.containsCJKCharacters {
            return Self.modernVADDeferredCJKCommitSuffixes.contains(where: { text.hasSuffix($0) })
        }

        let normalized = text.lowercased()
        return Self.modernVADDeferredLatinCommitSuffixes.contains(where: { normalized.hasSuffix($0) })
    }

    @available(macOS 26.0, *)
    private func emitDraftUpdate(from result: SpeechTranscriber.Result, text: String) {
        let now = Date()
        observeDraftText(text, at: now)
        let draftStability = currentDraftStability(at: now)
        let silenceMs = draftStability.silenceMs
        let stabilityScore = draftStability.stabilityScore

        let boundaryScore: Float = String(text.suffix(1)).containsSentenceTerminator ? 0.9 : 0.45
        let lengthFitScore = draftLengthFitScore(for: text)
        let averageConfidence = transcriberAverageConfidence(result.text)

        let chunkScore = ChunkScorer.score(
            vadProbability: lastVADProbability,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            lengthFitScore: lengthFitScore,
            confidenceScore: averageConfidence
        )

        let stablePrefixLen = computeStablePrefixLength(text: text, now: now)
        let mutableTail = String(text.dropFirst(min(stablePrefixLen, text.count)))
        let timeRange = transcriberTimeRange(result.text)
        let startMs = timeRange.map { cmTimeMilliseconds($0.start) } ?? 0

        let draft = DraftSegment(
            segmentId: currentDraftId,
            sourceText: text,
            stablePrefixLength: stablePrefixLen,
            mutableTailText: mutableTail,
            avgConfidence: averageConfidence,
            startMs: startMs,
            lastUpdateMs: Int(now.timeIntervalSinceReferenceDate * 1000),
            silenceMs: silenceMs,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            chunkScore: chunkScore,
            vadProbability: lastVADProbability,
            words: []
        )

        Task { await emitPartialDraft(draft) }
    }

    @available(macOS 26.0, *)
    private func normalizedTranscriberText(_ text: AttributedString) -> String {
        String(text.characters)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(macOS 26.0, *)
    private func transcriberAverageConfidence(_ text: AttributedString) -> Float {
        var total: Double = 0
        var count = 0

        for run in text.runs {
            if let confidence = run.transcriptionConfidence {
                total += confidence
                count += 1
            }
        }

        guard count > 0 else { return 0.82 }
        return Float(total / Double(count))
    }

    @available(macOS 26.0, *)
    private func transcriberTimeRange(_ text: AttributedString) -> CMTimeRange? {
        for run in text.runs {
            if let timeRange = run.audioTimeRange {
                return timeRange
            }
        }

        return nil
    }

    @available(macOS 26.0, *)
    private func modernResultIdentity(for result: SpeechTranscriber.Result) -> String {
        let startMs = cmTimeMilliseconds(result.range.start)
        let durationMs = cmTimeMilliseconds(result.range.duration)
        return "\(startMs):\(durationMs):\(normalizedTranscriberText(result.text))"
    }

    private func draftLengthFitScore(for text: String) -> Float {
        let charCount = text.count
        let isCJK = text.containsCJKCharacters

        if isCJK {
            switch charCount {
            case 12...20: return 1.0
            case 5..<12:  return Float(charCount) / 12.0 * 0.6
            case 21...30: return 0.7
            default:      return 0.3
            }
        }

        switch charCount {
        case 28...56: return 1.0
        case 10..<28: return Float(charCount) / 28.0 * 0.6
        case 57...84: return 0.7
        default:      return 0.3
        }
    }

    private func cmTimeMilliseconds(_ time: CMTime) -> Int {
        guard time.isNumeric else { return 0 }
        return Int((CMTimeGetSeconds(time) * 1000.0).rounded())
    }

    // MARK: - Silence-commit timer

    /// Time after the last ASR callback before we force-commit pending text.
    ///
    /// 420 ms was too short: SFSpeechRecognizer can take 400–600 ms between consecutive
    /// partial-result callbacks for the same utterance on a loaded device, causing the
    /// timer to fire between two ASR deliveries for the same sentence.
    ///
    /// ~600–690 ms sits safely above:
    ///   • inter-result ASR delivery gaps (typically 100–500 ms during speech)
    ///   • natural within-sentence pauses in Mandarin/Japanese (200–450 ms)
    /// and below clear sentence-ending silences (≥ 600 ms for most speakers).
    ///
    /// Follow ≈ 600 ms · Balanced ≈ 630 ms · Reading ≈ 690 ms.
    private var silenceCommitDeadlineMs: Int {
        max(600, modeConfig.minSilenceCommitMs + 350)
    }

    /// Require a short stable window before promoting a punctuation-ended partial.
    /// This keeps the fast path responsive without freezing a still-revisable boundary.
    private var modernBoundaryCommitStabilityDelayMs: Int {
        max(160, min(modeConfig.minSilenceCommitMs, 240))
    }

    private var vadSilenceCommitDeadlineMs: Int {
        max(280, modeConfig.minSilenceCommitMs)
    }

    private func scheduleSilenceCommit() {
        scheduleSilenceCommit(trigger: .asrInactivity, afterMs: silenceCommitDeadlineMs)
    }

    private func cancelSilenceTimer() {
        silenceCommitTimer?.cancel()
        silenceCommitTimer = nil
    }

    // MARK: - VAD-based silence commit

    /// Schedules a fast commit based on Silero VAD detecting speech offset.
    /// Uses the mode's minSilenceCommitMs (100–200 ms) — much faster than the
    /// ASR-inactivity timer (700+ ms).
    private func scheduleVADSilenceCommit() {
        scheduleSilenceCommit(trigger: .vadOffset, afterMs: vadSilenceCommitDeadlineMs)
    }

    private func cancelVADSilenceTimer() {
        vadSilenceCommitTimer?.cancel()
        vadSilenceCommitTimer = nil
    }

    private func scheduleSilenceCommit(trigger: SilenceCommitTrigger, afterMs: Int) {
        cancelSilenceCommitTimer(for: trigger)
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(afterMs))
        timer.setEventHandler { [weak self] in
            self?.forceCommitOnSilence(trigger: trigger)
        }
        timer.resume()

        switch trigger {
        case .asrInactivity:
            silenceCommitTimer = timer
        case .vadOffset:
            vadSilenceCommitTimer = timer
        }
    }

    private func cancelSilenceCommitTimer(for trigger: SilenceCommitTrigger) {
        switch trigger {
        case .asrInactivity:
            cancelSilenceTimer()
        case .vadOffset:
            cancelVADSilenceTimer()
        }
    }

    /// Called by the silence timer when no new ASR result has arrived for
    /// silenceCommitDeadlineMs — meaning the user has paused.
    private func forceCommitOnSilence(trigger: SilenceCommitTrigger) {
        switch trigger {
        case .asrInactivity:
            silenceCommitTimer = nil
        case .vadOffset:
            vadSilenceCommitTimer = nil
        }

        if recognitionBackend == .speechAnalyzer {
            let committedRawText: String
            let remainingRawText: String

            switch trigger {
            case .asrInactivity:
                guard let split = committableModernText(in: latestModernText) else {
                    return
                }
                committedRawText = split.committedRawText
                remainingRawText = split.remainingRawText
            case .vadOffset:
                let now = Date()
                guard canVADCommitModernDraft(latestModernText, at: now) else {
                    return
                }
                committedRawText = latestModernText
                remainingRawText = ""
            }

            let text = committedRawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else {
                latestModernText = remainingRawText
                return
            }

            modernCommittedPrefixText += committedRawText
            latestModernText = remainingRawText
            let committedDraftID = currentDraftId
            resetDraftState()
            Task {
                await emitCommittedSequence(
                    [
                        CommittedEmission(
                            text: text,
                            promotionSegmentID: committedDraftID
                        )
                    ],
                    clearDraftAfter: remainingRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            return
        }

        let segments = latestSegments
        let formattedText = latestFormattedText

        guard committedSegmentCount < segments.count else { return }

        let pendingSegments = Array(segments[committedSegmentCount...])
        if let delayMs = requiredCommitDelayMs(trigger: trigger, pendingSegments: pendingSegments) {
            scheduleSilenceCommit(trigger: trigger, afterMs: delayMs)
            return
        }

        let lastIdx = segments.count - 1
        let currentRange = combinedRange(for: segments, from: committedSegmentCount, to: lastIdx)
        let sentenceText = (formattedText.substring(with: currentRange) as String)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let committedDraftID = currentDraftId

        committedAudioBoundaryTime = segmentEndTime(for: segments[lastIdx])
        committedSegmentCount = segments.count
        resetDraftState()
        if sentenceText.isEmpty == false {
            Task {
                await emitCommittedSequence(
                    [
                        CommittedEmission(
                            text: sentenceText,
                            promotionSegmentID: committedDraftID
                        )
                    ],
                    clearDraftAfter: true
                )
            }
        } else {
            Task { await emitPartialDraft(nil) }
        }
    }

    private func requiredCommitDelayMs(
        trigger: SilenceCommitTrigger,
        pendingSegments: [SFTranscriptionSegment]
    ) -> Int? {
        guard pendingSegments.isEmpty == false else {
            return nil
        }

        let now = Date()
        let lastUpdateTime = max(lastRecognitionResultTime, lastDraftTextChangeTime)
        let elapsedMs = Int(now.timeIntervalSince(lastUpdateTime) * 1000)
        let averageConfidence = pendingSegments.map(\.confidence).reduce(0, +) / Float(pendingSegments.count)

        var settleWindowMs = trigger == .vadOffset ? 320 : 220
        if pendingSegments.count <= 2 {
            settleWindowMs += 80
        }
        if averageConfidence < 0.78 {
            settleWindowMs += 120
        }

        guard elapsedMs < settleWindowMs else {
            return nil
        }

        return settleWindowMs - max(elapsedMs, 0)
    }

    private func alignCommittedSegmentCount(to segments: [SFTranscriptionSegment]) {
        if segments.count < committedSegmentCount {
            resetLegacyTranscriptionState()
            resetDraftState()
            return
        }

        guard let committedAudioBoundaryTime else {
            return
        }

        let alignedCount = segments.prefix {
            segmentEndTime(for: $0) <= committedAudioBoundaryTime + committedBoundaryToleranceSec
        }.count

        guard alignedCount != committedSegmentCount else {
            return
        }

        committedSegmentCount = alignedCount
        resetDraftState()
    }

    private func segmentEndTime(for segment: SFTranscriptionSegment) -> TimeInterval {
        segment.timestamp + segment.duration
    }

    // MARK: - Draft helpers (called on captureQueue)

    private func resetDraftState() {
        currentDraftId = UUID()
        lastDraftText = ""
        lastDraftTextChangeTime = Date.distantPast
        lastRecognitionResultTime = Date.distantPast
        draftChangeHistory = []
        draftPrefixCandidate = ""
        draftPrefixCandidateTime = Date.distantPast
        confirmedStablePrefixLength = 0
    }

    private func emitDraftUpdate(
        draftRange: Range<Int>,
        allSegments: [SFTranscriptionSegment],
        formattedText: NSString
    ) {
        let now = Date()
        let lastIdx = draftRange.upperBound - 1
        let draftNSRange = combinedRange(for: allSegments, from: draftRange.lowerBound, to: lastIdx)
        let text = (formattedText.substring(with: draftNSRange) as String)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            Task { await emitPartialDraft(nil) }
            return
        }

        observeDraftText(text, at: now)
        let draftStability = currentDraftStability(at: now)
        let silenceMs = draftStability.silenceMs
        let stabilityScore = draftStability.stabilityScore

        // Boundary score: sentence-terminating punctuation scores highest
        let lastSeg = allSegments[lastIdx]
        let boundaryScore: Float = lastSeg.substring.containsSentenceTerminator ? 0.9 : 0.45

        // Length fit score
        let lengthFitScore = draftLengthFitScore(for: text)

        let draftSegs = Array(allSegments[draftRange])
        let avgConfidence = draftSegs.map(\.confidence).reduce(0, +) / Float(draftSegs.count)

        let chunkScore = ChunkScorer.score(
            vadProbability: lastVADProbability,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            lengthFitScore: lengthFitScore,
            confidenceScore: avgConfidence
        )

        let stablePrefixLen = computeStablePrefixLength(text: text, now: now)
        let mutableTail = String(text.dropFirst(min(stablePrefixLen, text.count)))

        let words = draftSegs.map { seg in
            WordToken(
                text: seg.substring,
                startMs: Int(seg.timestamp * 1000),
                endMs: Int((seg.timestamp + seg.duration) * 1000),
                confidence: seg.confidence,
                stable: seg.confidence >= 0.80
            )
        }

        let draft = DraftSegment(
            segmentId: currentDraftId,
            sourceText: text,
            stablePrefixLength: stablePrefixLen,
            mutableTailText: mutableTail,
            avgConfidence: avgConfidence,
            startMs: Int(draftSegs[0].timestamp * 1000),
            lastUpdateMs: Int(now.timeIntervalSinceReferenceDate * 1000),
            silenceMs: silenceMs,
            stabilityScore: stabilityScore,
            boundaryScore: boundaryScore,
            chunkScore: chunkScore,
            vadProbability: lastVADProbability,
            words: words
        )

        Task { await emitPartialDraft(draft) }
    }

    /// Returns the character count of the stable (frozen) prefix.
    /// A prefix is stable once it has been unchanged for >= 400 ms.
    private func computeStablePrefixLength(text: String, now: Date) -> Int {
        let mutableLen = mutableTailCharCount(for: text)
        let candidateLen = max(0, text.count - mutableLen)
        let candidate = String(text.prefix(candidateLen))

        if candidate == draftPrefixCandidate {
            if now.timeIntervalSince(draftPrefixCandidateTime) >= 0.4 {
                confirmedStablePrefixLength = candidateLen
            }
        } else if text.hasPrefix(draftPrefixCandidate) {
            // Text grew but prefix region unchanged — slide candidate forward
            draftPrefixCandidate = candidate
        } else {
            // Prefix regressed — reset
            draftPrefixCandidate = candidate
            draftPrefixCandidateTime = now
            confirmedStablePrefixLength = 0
        }

        return confirmedStablePrefixLength
    }

    /// Characters in the mutable tail: last 12 for CJK, last 35 for Latin (≈ 6 words).
    private func mutableTailCharCount(for text: String) -> Int {
        text.containsCJKCharacters ? min(12, text.count) : min(35, text.count)
    }

    private func combinedRange(for segments: [SFTranscriptionSegment], from startIndex: Int, to endIndex: Int) -> NSRange {
        let firstRange = segments[startIndex].substringRange
        let lastRange = segments[endIndex].substringRange
        let endLocation = lastRange.location + lastRange.length
        return NSRange(location: firstRange.location, length: endLocation - firstRange.location)
    }

    private func mapApplicationCaptureError(_ error: ApplicationAudioCapture.CaptureError) -> SessionError {
        switch error {
        case .permissionDenied:
            return .audioCapturePermissionDenied
        case .missingOutputDevice:
            return .failedToStartCapture(localized(.noOutputAudioDeviceForAppCapture))
        case .tapFormatUnavailable:
            return .failedToStartCapture(localized(.selectedAppAudioFormatCouldNotBePrepared))
        case .failed(let stage, let status):
            return .failedToStartCapture(
                localized(.failedToStageWithReasonFormat, stage, status.readableDescription)
            )
        }
    }
}

extension LiveTranscriptionSession: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        append(sampleBuffer: sampleBuffer)
    }
}

private final class ApplicationAudioCapture {
    enum CaptureError: Error {
        case permissionDenied
        case missingOutputDevice
        case tapFormatUnavailable
        case failed(stage: String, status: OSStatus)
    }

    private let appName: String
    private let processObjectIDs: [AudioObjectID]
    private let readStreamFailureMessage: String
    private let queue: DispatchQueue
    private let audioHandler: (AVAudioPCMBuffer) -> Void
    private let errorHandler: (String) -> Void

    private let system = AudioHardwareSystem.shared
    private var processTap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var deviceIOProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    init(
        appName: String,
        processObjectIDs: [AudioObjectID],
        readStreamFailureMessage: String,
        queue: DispatchQueue,
        audioHandler: @escaping (AVAudioPCMBuffer) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        self.appName = appName
        self.processObjectIDs = processObjectIDs
        self.readStreamFailureMessage = readStreamFailureMessage
        self.queue = queue
        self.audioHandler = audioHandler
        self.errorHandler = errorHandler
    }

    func start() throws {
        do {
            let tapDescription = CATapDescription(monoMixdownOfProcesses: processObjectIDs)
            tapDescription.uuid = UUID()
            tapDescription.muteBehavior = .unmuted
            tapDescription.isPrivate = true
            tapDescription.name = "v2s \(appName)"

            guard let processTap = try system.makeProcessTap(description: tapDescription) else {
                throw CaptureError.failed(stage: "create the process tap", status: kAudioHardwareIllegalOperationError)
            }

            self.processTap = processTap

            guard let outputDevice = try system.defaultOutputDevice else {
                throw CaptureError.missingOutputDevice
            }

            let outputUID = try outputDevice.uid
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "v2s-\(appName)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: outputUID
                    ]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: try processTap.uid
                    ]
                ]
            ]

            guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
                throw CaptureError.failed(stage: "create the aggregate device", status: kAudioHardwareIllegalOperationError)
            }

            self.aggregateDevice = aggregateDevice

            var streamDescription = try processTap.format
            guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError.tapFormatUnavailable
            }

            self.tapFormat = tapFormat

            var deviceIOProcID: AudioDeviceIOProcID?
            let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
                &deviceIOProcID,
                aggregateDevice.id,
                queue
            ) { [weak self] _, inputData, _, _, _ in
                guard let self else {
                    return
                }

                self.handleCapturedAudio(inputData)
            }

            guard createIOProcStatus == noErr, let deviceIOProcID else {
                throw CaptureError.failed(stage: "create the capture callback", status: createIOProcStatus)
            }

            self.deviceIOProcID = deviceIOProcID

            let startStatus = AudioDeviceStart(aggregateDevice.id, deviceIOProcID)
            guard startStatus == noErr else {
                throw CaptureError.failed(stage: "start app audio capture", status: startStatus)
            }
        } catch let error as AudioHardwareError {
            stop()

            if error.error == permErr {
                throw CaptureError.permissionDenied
            }

            throw CaptureError.failed(stage: "configure app audio capture", status: error.error)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let aggregateDevice, let deviceIOProcID {
            AudioDeviceStop(aggregateDevice.id, deviceIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDevice.id, deviceIOProcID)
        }

        deviceIOProcID = nil

        if let aggregateDevice {
            try? system.destroyAggregateDevice(aggregateDevice)
        }

        aggregateDevice = nil

        if let processTap {
            try? system.destroyProcessTap(processTap)
        }

        processTap = nil
        tapFormat = nil
    }

    private func handleCapturedAudio(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat,
              inputData.pointee.mNumberBuffers > 0,
              inputData.pointee.mBuffers.mDataByteSize > 0 else {
            return
        }

        let mutableAudioBufferList = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: mutableAudioBufferList,
            deallocator: nil
        ) else {
            errorHandler(readStreamFailureMessage)
            return
        }

        audioHandler(buffer)
    }
}

private struct AudioFormatSignature: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        isInterleaved = format.isInterleaved
    }
}

private extension AVAudioFormat {
    func matches(_ other: AVAudioFormat) -> Bool {
        AudioFormatSignature(self) == AudioFormatSignature(other)
    }
}

private extension InputSource {
    var processIdentifierHint: pid_t? {
        guard detail.hasPrefix("pid-") else {
            return nil
        }

        return pid_t(detail.dropFirst(4))
    }
}

private struct ApplicationProcessAssociation {
    let bundleIdentifier: String?
    let applicationBundleURL: URL?
    let helperBundlePrefixes: [String]
    let helperPathFragments: [String]

    init(runningApplication: NSRunningApplication) {
        self.bundleIdentifier = runningApplication.bundleIdentifier
        self.applicationBundleURL = runningApplication.bundleURL?.standardizedFileURL

        var helperBundlePrefixes: [String] = []
        var helperPathFragments: [String] = []

        if let bundleIdentifier = runningApplication.bundleIdentifier {
            helperBundlePrefixes.append(bundleIdentifier)

            switch bundleIdentifier {
            case "com.apple.Safari":
                helperBundlePrefixes.append(contentsOf: [
                    "com.apple.WebKit.",
                    "com.apple.Safari"
                ])
                helperPathFragments.append(contentsOf: [
                    "/WebKit.framework/",
                    "/SafariPlatformSupport.framework/",
                    "/Safari.app/"
                ])
            case "com.google.Chrome":
                helperPathFragments.append(contentsOf: [
                    "/Google Chrome.app/",
                    "Google Chrome Helper"
                ])
            case "org.chromium.Chromium":
                helperPathFragments.append(contentsOf: [
                    "/Chromium.app/",
                    "Chromium Helper"
                ])
            case "com.microsoft.edgemac":
                helperPathFragments.append(contentsOf: [
                    "/Microsoft Edge.app/",
                    "Microsoft Edge Helper"
                ])
            case "com.brave.Browser":
                helperPathFragments.append(contentsOf: [
                    "/Brave Browser.app/",
                    "Brave Browser Helper"
                ])
            case "org.mozilla.firefox":
                helperPathFragments.append(contentsOf: [
                    "/Firefox.app/",
                    "plugin-container"
                ])
            default:
                break
            }
        }

        self.helperBundlePrefixes = Array(Set(helperBundlePrefixes))
        self.helperPathFragments = Array(Set(helperPathFragments))
    }

    func matchesExactBundleIdentifier(_ candidate: String) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return candidate == bundleIdentifier
    }

    func matchesApplicationBundleURL(_ candidate: URL?) -> Bool {
        guard let applicationBundleURL else {
            return false
        }

        return candidate == applicationBundleURL
    }

    func matchesHelperBundleIdentifier(_ candidate: String) -> Bool {
        guard candidate.isEmpty == false else {
            return false
        }

        return helperBundlePrefixes.contains(where: { candidate.hasPrefix($0) })
    }

    func matchesHelperExecutablePath(_ candidate: String?) -> Bool {
        guard let candidate, candidate.isEmpty == false else {
            return false
        }

        return helperPathFragments.contains(where: { candidate.contains($0) })
    }
}

private extension String {
    var containsSentenceTerminator: Bool {
        contains(where: { ".!?。！？;；".contains($0) })
    }

    var containsCJKCharacters: Bool {
        unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)   // CJK Unified Ideographs
                || (0x3040...0x30FF).contains($0.value) // Hiragana + Katakana
                || (0xAC00...0xD7AF).contains($0.value) // Korean Hangul
        }
    }
}

private extension LiveTranscriptionSession {
    static let minimumLatinLeadingOverlapCharacters = 10
    static let minimumCJKLeadingOverlapCharacters = 4
    static let recentCommittedSentenceLimit = 6
    static let committedPrefixContinuationWindow: TimeInterval = 3.0
    static let dialogueClauseSeparatorRegex = try! NSRegularExpression(pattern: "[、,，]")
    static let dialogueClauseEndingSuffixes = [
        "ね", "よ", "の", "な", "さ", "わ", "ぞ", "ぜ", "かな", "かも", "だよ", "だね"
    ]
    static let dialogueClauseLeadingPhrases = [
        "俺", "私", "僕", "うん", "いや", "や", "でも", "じゃ", "ただいま", "おかえり", "ありがとう", "ごめん"
    ]
    static let modernVADDeferredCJKCommitSuffixes = [
        "けど", "けれど", "けれども", "から", "ので", "のに", "とか", "って",
        "で", "て", "が", "を", "に", "へ", "と", "し"
    ]
    static let modernVADDeferredLatinCommitSuffixes = [
        " and", " or", " but", " so", " because", " if", " when", " that", " to"
    ]
    static let committedComparisonTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    static let leadingOverlapTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
}

private extension OSStatus {
    var readableDescription: String {
        let nsError = NSError(domain: NSOSStatusErrorDomain, code: Int(self))

        if nsError.localizedDescription != "The operation couldn’t be completed. (OSStatus error \(self).)" {
            return nsError.localizedDescription
        }

        if let fourCharacterCode = fourCharacterCode {
            return "\(self) (\(fourCharacterCode))"
        }

        return "\(self)"
    }

    private var fourCharacterCode: String? {
        let bigEndianValue = UInt32(bitPattern: self).bigEndian
        let scalarValues = [
            UInt8((bigEndianValue >> 24) & 0xFF),
            UInt8((bigEndianValue >> 16) & 0xFF),
            UInt8((bigEndianValue >> 8) & 0xFF),
            UInt8(bigEndianValue & 0xFF)
        ]

        guard scalarValues.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return nil
        }

        return String(bytes: scalarValues, encoding: .ascii)
    }
}

private func executablePath(forProcessID processID: pid_t) -> String? {
    let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
    defer {
        pathBuffer.deallocate()
    }

    let pathLength = proc_pidpath(processID, pathBuffer, UInt32(MAXPATHLEN))
    guard pathLength > 0 else {
        return nil
    }

    return String(cString: pathBuffer)
}

private func applicationBundleURL(forProcessID processID: pid_t) -> URL? {
    guard let executablePath = executablePath(forProcessID: processID) else {
        return nil
    }

    return URL(fileURLWithPath: executablePath).owningApplicationBundleURL()
}

private extension URL {
    func owningApplicationBundleURL(maxDepth: Int = 16) -> URL? {
        var depth = 0
        var currentURL = standardizedFileURL

        while depth < maxDepth {
            if currentURL.pathExtension == "app" {
                return currentURL.standardizedFileURL
            }

            currentURL = currentURL.deletingLastPathComponent()
            depth += 1
        }

        return nil
    }
}
