import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os.log
import Speech

private extension Logger {
    static let appAudioCapture = Logger(subsystem: "com.franklioxygen.v2s", category: "appAudioCapture")
}

struct RecognizedSentence: Equatable, Sendable {
    let text: String
    let promotionSegmentID: UUID?

    init(text: String, promotionSegmentID: UUID? = nil) {
        self.text = text
        self.promotionSegmentID = promotionSegmentID
    }
}

final class LiveTranscriptionSession: NSObject, @unchecked Sendable {
    enum LegacyRecognitionErrorDisposition: Equatable {
        case ignore
        case restartImmediately
        case retryWithBackoff
        case stopAndSurface
    }

    /// Decides what to do about a legacy recognition-task error.
    ///
    /// `message` is the error's localized description. Code 203 is a bucket Apple uses
    /// for unrelated failures — the transient "Retry"/"Corrupt" faults that a restart
    /// clears, and the server quota rejection that no amount of retrying clears — so
    /// only the quota text earns a hard stop.
    static func legacyRecognitionErrorDisposition(
        domain: String,
        code: Int,
        message: String = ""
    ) -> LegacyRecognitionErrorDisposition {
        guard domain == "kAFAssistantErrorDomain" else {
            return .retryWithBackoff
        }

        if message.range(of: "quota", options: .caseInsensitive) != nil {
            return .stopAndSurface
        }

        switch code {
        case 216, 301:
            return .ignore
        case 1110:
            return .restartImmediately
        default:
            return .retryWithBackoff
        }
    }

    private struct CommittedEmission {
        let text: String
        let promotionSegmentID: UUID?
    }

    private struct ApplicationCaptureDescriptor: Sendable {
        let source: InputSource
        let processObjectIDs: [AudioObjectID]
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
    /// Consecutive recognition-task failures since the last delivered result. Restarting
    /// immediately recovers from a one-off fault, but a persistent one — an evicted
    /// on-device asset, an unreachable backend — would otherwise spin the task in a hot
    /// loop, so retries are spaced out and eventually surfaced instead of hidden.
    private var consecutiveRecognitionFailures = 0
    private var lastRecognitionFailureTime = Date.distantPast
    private var pendingRecognitionRestart: DispatchWorkItem?
    /// Delay before the Nth consecutive retry. The first stays immediate so ordinary
    /// hiccups still recover without a visible gap.
    private let recognitionRestartBackoff: [TimeInterval] = [0, 0.5, 1.5, 3, 5]
    /// Failures spaced further apart than this are unrelated, not a failing recognizer.
    private let recognitionFailureWindow: TimeInterval = 60
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
    private var modernResultLedger = TranscriberResultLedger()
    /// Latest volatile SpeechTranscriber.Result, which supplies draft confidence and
    /// timing when a commit changes the draft without a volatile result of its own.
    private var latestModernVolatileResult: Any?
    /// Latest sentence boundary the transcriber was asked to finalize through.
    private var modernFinalizationRequestedThrough: CMTime?
    private var speechAnalyzerState: AnyObject?
    private var speechTranscriberState: AnyObject?
    private var analyzerInputContinuationState: Any?
    private var analyzerInputFormat: AVAudioFormat?

    private var microphoneCaptureSession: AVCaptureSession?
    private var applicationAudioCapture: ApplicationAudioCapture?

    // MARK: App audio capture recovery (captureQueue)
    /// The app being captured. Nil for a microphone source and once the session stops.
    private var applicationCaptureSource: InputSource?
    /// Identifies the current capture. Events and rebuilds that belong to an earlier one
    /// are dropped.
    private var applicationCaptureGeneration = 0
    private var pendingApplicationCaptureRebuild: DispatchWorkItem?
    private var applicationCaptureRebuildSchedule = ApplicationCaptureRebuildSchedule()
    private var applicationCaptureRecovery = ApplicationCaptureRecoveryPolicy()
    /// A route change arrives as a burst of notifications; one rebuild answers them all.
    private let applicationCaptureRebuildDebounce: TimeInterval = 0.3
    private let applicationProcessRefreshDebounce: TimeInterval = 1

    private var transcriptHandler: (@MainActor (RecognizedSentence) -> Void)?
    private var partialHandler: (@MainActor (DraftSegment?) -> Void)?
    private var errorHandler: (@MainActor (String) -> Void)?
    /// Reports an unrecoverable recognition failure after this session has stopped.
    /// The owner uses this separate callback to stop sibling sessions as well.
    private var fatalErrorHandler: (@MainActor (String) -> Void)?
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
    private var vadEngine: SileroVADEngine?
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
        errorHandler: @escaping @MainActor (String) -> Void,
        fatalErrorHandler: @escaping @MainActor (String) -> Void
    ) async throws {
        self.transcriptHandler = transcriptHandler
        self.partialHandler = partialHandler
        self.modeConfig = modeConfig
        self.recognitionContextualStrings = sanitizeContextualStrings(contextualStrings)
        self.activeLocaleIdentifier = localeIdentifier
        self.interfaceLanguageID = interfaceLanguageID
        self.errorHandler = errorHandler
        self.fatalErrorHandler = fatalErrorHandler
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
        // Keep the session alive until every capture resource has been released. The
        // owner drops its references immediately after calling this method.
        captureQueue.async { [self] in
            stopOnCaptureQueue()
        }
    }

    /// Stops the session and returns only after its capture queue has released all
    /// microphone/Core Audio resources. Used before starting replacement sessions.
    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [self] in
                stopOnCaptureQueue()
                continuation.resume()
            }
        }
    }

    private func stopOnCaptureQueue() {
        cancelSilenceTimer()
        cancelVADSilenceTimer()

        microphoneCaptureSession?.stopRunning()
        microphoneCaptureSession = nil

        applicationAudioCapture?.stop()
        applicationAudioCapture = nil
        resetApplicationCaptureRecovery()

        stopModernSpeechRecognizer()
        resetRecognitionFailureState()
        recognitionGeneration &+= 1
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

        let request = makeRecognitionRequest(
            requiresOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionTask = task
        recognitionBackend = .legacy
        resetRecognitionFailureState()
        resetAudioProcessingState()
        resetLegacyTranscriptionState()
        cancelSilenceTimer()
        resetDraftState()

        // Initialize Silero VAD engine.
        do {
            vadEngine = try SileroVADEngine()
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

    /// Resolves `requestedLocale` to a locale the modern Speech stack actually carries.
    ///
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` answers with an equivalent
    /// locale even for languages the stack does not support at all — `ru-RU` resolves
    /// to `ru_RU` on a Mac whose supported list holds no Russian — so its answer only
    /// counts when it appears in `supportedLocales`. Without this check the modern path
    /// is entered for languages only the legacy recognizer can serve.
    @available(macOS 26.0, *)
    static func modernSpeechLocale(equivalentTo requestedLocale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return nil
        }

        let supportedIdentifiers = await Set(SpeechTranscriber.supportedLocales.map(\.identifier))
        return supportedIdentifiers.contains(resolved.identifier) ? resolved : nil
    }

    /// The transcriber a live session runs. Asset checks build theirs here too, so they
    /// ask for the same configuration the session will use.
    ///
    /// A session runs two: one reporting volatile results for the draft line, and one
    /// reporting only final results for the transcript. A transcriber that reported a
    /// volatile result need not reissue it as final when finalization leaves it
    /// unchanged, so only the final-only one is sure to deliver every final result.
    @available(macOS 26.0, *)
    static func makeSpeechTranscriber(locale: Locale, reportsVolatileResults: Bool = true) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportsVolatileResults ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
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
        guard let resolvedLocale = await Self.modernSpeechLocale(equivalentTo: requestedLocale) else {
            return false
        }

        let transcriber = Self.makeSpeechTranscriber(locale: resolvedLocale)
        let finalTranscriber = Self.makeSpeechTranscriber(locale: resolvedLocale, reportsVolatileResults: false)
        let modules = [transcriber, finalTranscriber]

        try await ensureSpeechAnalyzerAssetsIfNeeded(for: modules, locale: resolvedLocale)

        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        let context = AnalysisContext()
        if recognitionContextualStrings.isEmpty == false {
            context.contextualStrings[.general] = recognitionContextualStrings
        }
        try await analyzer.setContext(context)

        let preferredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: processingFormat
        ) ?? processingFormat
        try await analyzer.prepareToAnalyze(in: preferredFormat)

        let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(12)) { continuation in
            self.analyzerInputContinuationState = continuation
        }

        modernResultsTask?.cancel()
        modernResultsTask = Task { [weak self] in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await result in transcriber.results {
                            self?.captureQueue.async { [weak self] in
                                self?.processModernDraftResult(result)
                            }
                        }
                    }
                    group.addTask {
                        for try await result in finalTranscriber.results {
                            self?.captureQueue.async { [weak self] in
                                self?.processModernFinalResult(result)
                            }
                        }
                    }
                    // waitForAll would hold a failed stream's error until the other
                    // stream ends. Rethrowing it here cancels the other one instead.
                    while try await group.next() != nil {}
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
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        resetDraftState()
        modernResultLedger = TranscriberResultLedger()
        latestModernVolatileResult = nil
        modernFinalizationRequestedThrough = nil

        // Silero VAD finds speech offsets, which ask the transcriber to finalize.
        do {
            vadEngine = try SileroVADEngine()
        } catch {
            vadEngine = nil
        }

        return true
    }

    @available(macOS 26.0, *)
    private func ensureSpeechAnalyzerAssetsIfNeeded(
        for modules: [SpeechTranscriber],
        locale: Locale
    ) async throws {
        let installedLocales = await Set(SpeechTranscriber.installedLocales.map(\.identifier))
        if installedLocales.contains(locale.identifier) {
            return
        }

        if let installer = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await installer.downloadAndInstall()
        }
    }

    private func stopModernSpeechRecognizer() {
        modernAnalyzerTask?.cancel()
        modernAnalyzerTask = nil
        modernResultsTask?.cancel()
        modernResultsTask = nil
        modernResultLedger = TranscriberResultLedger()
        latestModernVolatileResult = nil
        modernFinalizationRequestedThrough = nil
        recognitionBackend = .legacy
        modernAudioConverter = nil
        modernAudioConverterInputSignature = nil

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

            // No finalized result will arrive for the draft the analyzer was revising,
            // so it is the best text there is: commit it rather than drop it.
            self.commitPendingModernDraft()
            self.stopModernSpeechRecognizer()

            do {
                try self.configureSpeechRecognizer(localeIdentifier: localeIdentifier)
            } catch {
                self.stopRecognitionAndSurface(error)
            }
        }
    }

    /// Builds a recognition request, keeping recognition on device wherever the
    /// recognizer has a local model. Languages without one — Chinese on Intel, say —
    /// are only served by Apple's speech service, and refusing that would leave them
    /// with no recognition at all.
    private func makeRecognitionRequest(
        requiresOnDeviceRecognition: Bool
    ) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
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
            source: source,
            processObjectIDs: try resolveApplicationProcessObjectIDs(for: source)
        )
    }

    private func startApplicationAudioCapture(descriptor: ApplicationCaptureDescriptor) throws {
        applicationCaptureGeneration &+= 1
        let generation = applicationCaptureGeneration
        let capture = ApplicationAudioCapture(
            appName: descriptor.source.name,
            processObjectIDs: descriptor.processObjectIDs,
            silenceWindow: applicationCaptureRecovery.silenceWindow,
            queue: captureQueue,
            audioHandler: { [weak self] buffer in
                self?.append(audioBuffer: buffer)
            },
            eventHandler: { [weak self] event in
                self?.handleApplicationCaptureEvent(event, generation: generation)
            }
        )

        do {
            try capture.start()
            applicationAudioCapture = capture
            applicationCaptureSource = descriptor.source
            // The descriptor predates tap creation. Process changes during creation or
            // the listener gap between captures may never reach this generation, so
            // always reconcile once the new listeners are installed.
            scheduleApplicationCaptureRebuild(after: applicationProcessRefreshDebounce, onlyIfProcessesChanged: true)
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

    // MARK: App audio capture recovery

    /// Handles a capture's report on the capture queue. A capture that stopped matching
    /// its audio is replaced: the app's processes are resolved again, and a new tap and
    /// aggregate device are built for them.
    private func handleApplicationCaptureEvent(_ event: ApplicationCaptureEvent, generation: Int) {
        guard generation == applicationCaptureGeneration, applicationCaptureSource != nil else {
            return
        }

        switch event {
        case .receivingAudio:
            applicationCaptureRecovery.recordAudibleCapture()
        case .processListChanged:
            scheduleApplicationCaptureRebuild(after: applicationProcessRefreshDebounce, onlyIfProcessesChanged: true)
        case .invalidated(let change):
            Logger.appAudioCapture.notice("Rebuilding app audio capture: \(String(describing: change), privacy: .public)")

            if change == .silentWhileAppIsPlaying {
                applicationCaptureRecovery.recordSilentCapture()
            }

            scheduleApplicationCaptureRebuild(after: applicationCaptureRebuildDebounce, onlyIfProcessesChanged: false)
        }
    }

    /// Queues a rebuild of the app capture. With `onlyIfProcessesChanged` the running
    /// capture is kept unless the app's audio processes differ from the tapped ones.
    private func scheduleApplicationCaptureRebuild(after delay: TimeInterval, onlyIfProcessesChanged: Bool) {
        guard let request = applicationCaptureRebuildSchedule.schedule(onlyIfProcessesChanged: onlyIfProcessesChanged) else {
            return
        }
        pendingApplicationCaptureRebuild?.cancel()

        let generation = applicationCaptureGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.applicationCaptureRebuildSchedule.beginResolving(request) else {
                return
            }

            self.pendingApplicationCaptureRebuild = nil
            self.rebuildApplicationCapture(generation: generation, request: request)
        }

        pendingApplicationCaptureRebuild = work
        captureQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuildApplicationCapture(generation: Int, request: ApplicationCaptureRebuildSchedule.Request) {
        guard generation == applicationCaptureGeneration, let source = applicationCaptureSource else {
            // Release the reservation; a request left in place would block every later rebuild.
            _ = applicationCaptureRebuildSchedule.finish(request)
            return
        }

        // The app's processes are resolved on the main actor, as at start.
        Task { [weak self] in
            guard let self else {
                return
            }

            let resolution: Result<ApplicationCaptureDescriptor, Error>
            do {
                resolution = .success(try await MainActor.run {
                    try self.makeApplicationCaptureDescriptor(for: source)
                })
            } catch {
                resolution = .failure(error)
            }

            self.captureQueue.async {
                self.finishApplicationCaptureRebuild(
                    resolution,
                    generation: generation,
                    request: request
                )
            }
        }
    }

    private func finishApplicationCaptureRebuild(
        _ resolution: Result<ApplicationCaptureDescriptor, Error>,
        generation: Int,
        request: ApplicationCaptureRebuildSchedule.Request
    ) {
        // Release the reservation before anything else, so no early return can leave it
        // in place and block every later rebuild.
        guard applicationCaptureRebuildSchedule.finish(request) else {
            return
        }
        let needsFollowUpRefresh = applicationCaptureRebuildSchedule.takeFollowUpRefresh()

        guard generation == applicationCaptureGeneration, applicationCaptureSource != nil else {
            return
        }
        defer {
            // A process that registered after this request's lookup still needs tapping.
            if needsFollowUpRefresh, applicationCaptureSource != nil {
                scheduleApplicationCaptureRebuild(after: applicationProcessRefreshDebounce, onlyIfProcessesChanged: true)
            }
        }
        let onlyIfProcessesChanged = request.onlyIfProcessesChanged

        let descriptor: ApplicationCaptureDescriptor
        switch resolution {
        case .success(let resolved):
            descriptor = resolved
        case .failure(let error):
            // A closed app cannot recover through the watchdog: none of its old
            // processes will report output again. Surface the specific error now.
            if case SessionError.missingApplication = error {
                abandonApplicationCapture(after: error)
                return
            }
            // Keep a working capture through transient process-list churn.
            if onlyIfProcessesChanged, applicationAudioCapture != nil {
                return
            }

            retryApplicationCaptureRebuild(after: error)
            return
        }

        if onlyIfProcessesChanged,
           let capture = applicationAudioCapture,
           Set(capture.processObjectIDs) == Set(descriptor.processObjectIDs) {
            return
        }

        // Count actual replacements, including process changes, rather than just
        // invalidation events. Helper churn must not bypass the rebuild limit.
        let rebuildKind: ApplicationCaptureRecoveryPolicy.RebuildKind = onlyIfProcessesChanged ? .processChange : .recovery
        if let delay = applicationCaptureRecovery.admitRebuild(rebuildKind, at: ProcessInfo.processInfo.systemUptime) {
            guard onlyIfProcessesChanged, applicationAudioCapture != nil else {
                abandonApplicationCapture(after: nil)
                return
            }

            // The running capture still works, so churn must not end the session. Tap
            // the changed processes once the window has room again.
            Logger.appAudioCapture.notice("Deferring app audio process refresh by \(delay, privacy: .public) s")
            scheduleApplicationCaptureRebuild(after: delay, onlyIfProcessesChanged: true)
            return
        }

        applicationAudioCapture?.stop()
        applicationAudioCapture = nil

        do {
            try startApplicationAudioCapture(descriptor: descriptor)
            applicationCaptureRecovery.recordSuccessfulRebuild()
        } catch {
            retryApplicationCaptureRebuild(after: error)
        }
    }

    private func retryApplicationCaptureRebuild(after error: Error) {
        Logger.appAudioCapture.error("App audio capture rebuild failed: \(self.localizedErrorDescription(error))")

        guard let delay = applicationCaptureRecovery.delayAfterFailedRebuild() else {
            abandonApplicationCapture(after: error)
            return
        }

        scheduleApplicationCaptureRebuild(after: delay, onlyIfProcessesChanged: false)
    }

    /// Ends the session once the app's audio cannot be recovered, and tells the user
    /// how to get it back.
    private func abandonApplicationCapture(after error: Error?) {
        let appName = applicationCaptureSource?.name ?? ""
        var message = localized(.applicationAudioLostFormat, appName)

        if let error = error as? SessionError {
            switch error {
            case .audioCapturePermissionDenied, .missingApplication:
                // These already tell the user what to do.
                message = localizedErrorDescription(error)
            default:
                break
            }
        }

        Logger.appAudioCapture.error("Gave up on app audio capture for \(appName)")
        stopOnCaptureQueue()

        Task {
            await self.emitFatalError(message)
        }
    }

    private func resetApplicationCaptureRecovery() {
        pendingApplicationCaptureRebuild?.cancel()
        pendingApplicationCaptureRebuild = nil
        applicationCaptureRebuildSchedule.cancel()
        applicationCaptureSource = nil
        applicationCaptureGeneration &+= 1
        applicationCaptureRecovery = ApplicationCaptureRecoveryPolicy()
    }

    private func resolveApplicationProcessObjectIDs(for source: InputSource) throws -> [AudioObjectID] {
        let runningApp = try resolveRunningApplication(for: source)
        let system = AudioHardwareSystem.shared
        let audioProcesses = try system.processes
        let targetAssociation = ApplicationProcessAssociation(runningApplication: runningApp)
        var relatedProcessIDs: [AudioObjectID] = []
        var seen = Set<AudioObjectID>()

        for process in audioProcesses {
            // Process-list notifications can race an unrelated process exiting.
            guard let processID = try? process.pid else {
                continue
            }
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
            guard let copiedBuffer = audioBuffer.copied() else {
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

        guard let separatorRange = singleDialogueClauseSeparatorRange(in: trimmed) else {
            return [trimmed]
        }

        let left = String(trimmed[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(trimmed[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard shouldSplitDialogueClauses(left: left, right: right) else {
            return [trimmed]
        }

        return [left, right]
    }

    private func singleDialogueClauseSeparatorRange(in text: String) -> Range<String.Index>? {
        var separatorRange: Range<String.Index>?

        for index in text.indices where Self.dialogueClauseSeparators.contains(text[index]) {
            if separatorRange != nil {
                return nil
            }

            separatorRange = index..<text.index(after: index)
        }

        return separatorRange
    }

    private func shouldSplitDialogueClauses(left: String, right: String) -> Bool {
        guard activeHeuristicLanguage == .japanese,
              left.isEmpty == false,
              right.isEmpty == false,
              left.containsCJKCharacters || right.containsCJKCharacters else {
            return false
        }

        let maxClauseLength = 18
        guard left.count <= maxClauseLength,
              right.count <= maxClauseLength else {
            return false
        }

        let leftLooksComplete = Self.japaneseDialogueClauseEndingSuffixes.contains(where: { left.hasSuffix($0) })
            || left.containsSentenceTerminator
        let rightLooksLikeNewTurn = Self.japaneseDialogueClauseLeadingPhrases.contains(where: { right.hasPrefix($0) })

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
    private func emitFatalError(_ message: String) {
        fatalErrorHandler?(message)
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
                allowsPrefixContinuation: SentenceBoundaryHeuristics
                    .endsWithLikelySentenceTerminator(in: text) == false
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
        SentenceBoundaryHeuristics.sentenceRanges(in: text)
    }

    private func hasLikelyPunctuationBoundary(
        afterSegmentAt index: Int,
        in formattedText: NSString,
        segments: [SFTranscriptionSegment]
    ) -> Bool {
        let currentRange = segments[index].substringRange
        let boundaryEndLocation = index < segments.count - 1
            ? segments[index + 1].substringRange.location
            : formattedText.length

        guard boundaryEndLocation > currentRange.location else {
            return false
        }

        let boundaryText = formattedText.substring(
            with: NSRange(location: currentRange.location, length: boundaryEndLocation - currentRange.location)
        )
        let nextText = index < segments.count - 1 ? segments[index + 1].substring : nil

        return SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(
            in: boundaryText,
            followedBy: nextText
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
        // The recognizer is delivering again — forget any earlier failures.
        consecutiveRecognitionFailures = 0
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
            // Apple may place restored punctuation in the gap before the next segment
            // rather than inside the current segment substring.
            let punctuationBoundary = hasLikelyPunctuationBoundary(
                afterSegmentAt: index,
                in: formattedText,
                segments: segments
            )
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

        // A restart from any source supersedes a retry still waiting on its backoff.
        pendingRecognitionRestart?.cancel()
        pendingRecognitionRestart = nil

        // Cleanly end the old request before discarding it.
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        vadEngine?.reset()

        // Bump generation BEFORE creating the new handler so any late callbacks
        // dispatched by the cancelled task are silently ignored.
        recognitionGeneration &+= 1

        let request = makeRecognitionRequest(
            requiresOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        recognitionRequest = request
        recognitionTask = task
        // Reset the converter — new request may have a different nativeAudioFormat.
        resetAudioProcessingState()
        resetLegacyTranscriptionState()
        resetDraftState()
        Task { await emitPartialDraft(nil) }
    }

    private func resetRecognitionFailureState() {
        pendingRecognitionRestart?.cancel()
        pendingRecognitionRestart = nil
        consecutiveRecognitionFailures = 0
        lastRecognitionFailureTime = .distantPast
    }

    /// Recovers from a recognition-task error on captureQueue.
    ///
    /// Retries are spaced by `recognitionRestartBackoff` so a recognizer that fails the
    /// instant it starts cannot loop at full speed. Once the retries are exhausted the
    /// error reaches the UI — otherwise capture keeps running behind an overlay that
    /// still claims to be waiting for audio.
    private func handleRecognitionFailure(_ error: Error) {
        let now = Date()
        if now.timeIntervalSince(lastRecognitionFailureTime) > recognitionFailureWindow {
            consecutiveRecognitionFailures = 0
        }
        lastRecognitionFailureTime = now
        consecutiveRecognitionFailures += 1

        guard consecutiveRecognitionFailures <= recognitionRestartBackoff.count else {
            stopRecognitionAndSurface(error)
            return
        }

        let delay = recognitionRestartBackoff[consecutiveRecognitionFailures - 1]
        guard delay > 0 else {
            restartRecognitionTask()
            return
        }

        pendingRecognitionRestart?.cancel()
        let restart = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRecognitionRestart = nil
            self.restartRecognitionTask()
        }
        pendingRecognitionRestart = restart
        captureQueue.asyncAfter(deadline: .now() + delay, execute: restart)
    }

    /// Ends the session after recognition has failed for good, and reports why.
    ///
    /// Capture is torn down along with the recognizer: audio that nothing transcribes is
    /// only a microphone left open, and the surfaced message tells the user the session
    /// has stopped. `stopOnCaptureQueue` keeps `errorHandler` in place, so the message
    /// still reaches the UI.
    private func stopRecognitionAndSurface(_ error: Error) {
        stopOnCaptureQueue()

        Task {
            await self.emitFatalError(
                self.localized(
                    .speechRecognitionStoppedFormat,
                    self.localizedErrorDescription(error)
                )
            )
        }
    }

    /// Builds the result/error handler used by every recognition task.
    ///
    /// On transient errors (no speech detected, internal failure, etc.) the handler
    /// restarts recognition so the pipeline never goes silent. Repeated failures back
    /// off and are eventually surfaced instead of retried forever — see
    /// `handleRecognitionFailure`. Fatal configuration errors (permission denied,
    /// unsupported locale) propagate to the UI so the user knows why things stopped.
    private func makeRecognitionHandler() -> (SFSpeechRecognitionResult?, Error?) -> Void {
        // Capture the generation at handler-creation time. Any callback arriving
        // after a restart (which bumps recognitionGeneration) will be discarded,
        // preventing stale isFinal results from replaying committed sentences.
        let generation = recognitionGeneration
        return { [weak self] result, error in
            if let error {
                let nsError = error as NSError
                let disposition = Self.legacyRecognitionErrorDisposition(
                    domain: nsError.domain,
                    code: nsError.code,
                    message: nsError.localizedDescription
                )

                // Codes 216/301 are intentional cancellation from our own restart/stop.
                if disposition == .ignore { return }

                self?.captureQueue.async { [weak self] in
                    guard let self, self.speechRecognizer != nil,
                          self.recognitionGeneration == generation else { return }

                    switch disposition {
                    case .ignore:
                        break
                    case .restartImmediately:
                        // Code 1110 is a normal "no speech detected" timeout.
                        self.restartRecognitionTask()
                    case .stopAndSurface:
                        // An exhausted Apple server quota. Retrying only produces more
                        // rejected requests, so fail fast and tell the user.
                        self.stopRecognitionAndSurface(error)
                    case .retryWithBackoff:
                        self.handleRecognitionFailure(error)
                    }
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

    /// Takes a result from the transcriber that reports volatile results. Its text drives
    /// the draft line only, even when final: finalization that leaves a volatile result
    /// unchanged need not reissue it, so this transcriber cannot be relied on for every
    /// final result. The final-only transcriber's results are committed instead.
    @available(macOS 26.0, *)
    private func processModernDraftResult(_ result: SpeechTranscriber.Result) {
        // A result already in flight when the analyzer failed over must not reach the
        // legacy recognizer's draft state.
        guard recognitionBackend == .speechAnalyzer else { return }

        if result.isFinal == false {
            latestModernVolatileResult = result
        }
        modernResultLedger.applyDraft(Self.transcriberPieces(of: result), range: result.range)
        publishModernTranscript(finalizedText: nil)

        if result.isFinal == false {
            finalizeCompletedSentencesInLongDraft(result)
        }
    }

    /// Commits a result from the final-only transcriber. Volatile results are interim
    /// guesses the transcriber keeps revising, so pauses and long drafts ask the analyzer
    /// to finalize, and the text arrives here.
    @available(macOS 26.0, *)
    private func processModernFinalResult(_ result: SpeechTranscriber.Result) {
        guard recognitionBackend == .speechAnalyzer else { return }

        let finalizedText = modernResultLedger.commit(
            Self.transcriberPieces(of: result),
            range: result.range,
            resultsFinalizationTime: result.resultsFinalizationTime
        )
        publishModernTranscript(finalizedText: finalizedText)
    }

    @available(macOS 26.0, *)
    private static func transcriberPieces(of result: SpeechTranscriber.Result) -> [TranscriberResultLedger.Piece] {
        let runs = result.text.runs.map { run in
            (text: String(result.text[run.range].characters), audioRange: run.audioTimeRange)
        }
        return TranscriberResultLedger.pieces(from: runs, resultRange: result.range)
    }

    /// Commits final text and shows the draft that remains.
    @available(macOS 26.0, *)
    private func publishModernTranscript(finalizedText: String?) {
        let draftText = modernResultLedger.draftText
        let draftChanged = draftText != lastDraftText
        let committedDraftID = currentDraftId
        if finalizedText != nil {
            resetDraftState()
        }

        if draftText.isEmpty {
            // Nothing is left for the inactivity timer to finalize. Left running, it
            // could finalize the next utterance before its first result arrives.
            cancelSilenceTimer()
        } else if let result = latestModernVolatileResult as? SpeechTranscriber.Result {
            emitDraftUpdate(from: result, text: draftText)

            // Re-armed only when the draft moves: a transcriber that repeats the same
            // volatile text through a pause, or stops hearing audio, still finalizes it.
            if draftChanged || finalizedText != nil {
                scheduleSilenceCommit()
            }
        }

        if let finalizedText {
            Task {
                await emitCommittedSequence(
                    [
                        CommittedEmission(
                            text: finalizedText,
                            promotionSegmentID: committedDraftID
                        )
                    ],
                    clearDraftAfter: draftText.isEmpty
                )
            }
        } else if draftText.isEmpty {
            Task { await emitPartialDraft(nil) }
        }
    }

    /// Continuous speech never pauses long enough for the timers, so a long draft
    /// finalizes its completed sentences and keeps only the unfinished tail volatile.
    @available(macOS 26.0, *)
    private func finalizeCompletedSentencesInLongDraft(_ result: SpeechTranscriber.Result) {
        guard CMTimeGetSeconds(result.range.duration) >= modeConfig.maxChunkAudioSec,
              let boundary = completedSentenceBoundary(in: result.text) else {
            return
        }

        if let requested = modernFinalizationRequestedThrough,
           CMTimeCompare(boundary, requested) <= 0 {
            return
        }
        modernFinalizationRequestedThrough = boundary
        requestModernFinalization(through: boundary)
    }

    /// Asks the transcribers to finalize their volatile results through `time`, or through
    /// all audio taken so far when `time` is nil. The final-only transcriber then delivers
    /// the text as final results, whether or not finalization changed it.
    private func requestModernFinalization(through time: CMTime?) {
        guard #available(macOS 26.0, *),
              recognitionBackend == .speechAnalyzer,
              let analyzer = speechAnalyzerState as? SpeechAnalyzer else {
            return
        }

        Task { [weak self] in
            do {
                try await analyzer.finalize(through: time)
            } catch {
                // A failed long-draft request must not block the next request for the
                // same boundary, so the next long result can ask again.
                guard let time else { return }
                self?.captureQueue.async { [weak self] in
                    guard let self,
                          let requested = self.modernFinalizationRequestedThrough,
                          CMTimeCompare(requested, time) == 0 else {
                        return
                    }
                    self.modernFinalizationRequestedThrough = nil
                }
            }
        }
    }

    /// Commits the current SpeechAnalyzer draft as it stands. Only for when the analyzer
    /// is going away, since no finalized result will follow for it.
    private func commitPendingModernDraft() {
        let text = modernResultLedger.removePending()
        let committedDraftID = currentDraftId
        resetDraftState()

        guard text.isEmpty == false else {
            Task { await emitPartialDraft(nil) }
            return
        }

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
    }

    @available(macOS 26.0, *)
    private func completedSentenceBoundary(in text: AttributedString) -> CMTime? {
        let runs = text.runs.map { run in
            (text: String(text[run.range].characters), audioEnd: run.audioTimeRange?.end)
        }
        return Self.completedSentenceBoundary(in: runs)
    }

    /// Returns the audio time at which the last completed sentence ends, when more
    /// speech follows it. Nil when the text holds no complete sentence, or nothing
    /// after its last one.
    static func completedSentenceBoundary(in runs: [(text: String, audioEnd: CMTime?)]) -> CMTime? {
        var prefix = ""
        var lastAudioEnd: CMTime?
        var boundary: CMTime?
        var hasSpeechAfterBoundary = false

        for (index, run) in runs.enumerated() {
            prefix += run.text
            if let audioEnd = run.audioEnd, audioEnd.isNumeric {
                lastAudioEnd = audioEnd
            }
            guard run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                continue
            }

            let nextText = runs.dropFirst(index + 1)
                .first { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }?
                .text
            if let lastAudioEnd,
               SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: prefix, followedBy: nextText) {
                boundary = lastAudioEnd
                hasSpeechAfterBoundary = false
            } else {
                hasSpeechAfterBoundary = true
            }
        }

        return hasSpeechAfterBoundary ? boundary : nil
    }

    /// Whether a speech offset should leave the draft volatile. A draft that ends on a
    /// conjunction, particle or abbreviation is likely mid-sentence, and finalizing it
    /// would split the caption at a breath pause. The inactivity timer still finalizes
    /// it if the pause lasts.
    static func shouldDeferModernVADFinalization(of rawText: String, languageCode: String?) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false,
              SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) == false else {
            return false
        }

        if SentenceBoundaryHeuristics.endsWithLikelyNonTerminalAbbreviation(in: text) {
            return true
        }

        switch languageCode {
        case "ja":
            return modernVADDeferredJapaneseSuffixes.contains(where: { text.hasSuffix($0) })
        case "en":
            let normalized = " " + text.lowercased()
            return modernVADDeferredEnglishSuffixes.contains(where: { normalized.hasSuffix($0) })
        default:
            return false
        }
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

    private var activeHeuristicLanguage: RecognitionHeuristicLanguage {
        switch activeLanguageCode {
        case "ja":
            return .japanese
        case "en":
            return .english
        default:
            return .other
        }
    }

    private var activeLanguageCode: String? {
        guard let activeLocaleIdentifier else {
            return nil
        }

        let separators = CharacterSet(charactersIn: "-_")
        return activeLocaleIdentifier
            .components(separatedBy: separators)
            .first?
            .lowercased()
    }

    @available(macOS 26.0, *)
    private func emitDraftUpdate(from result: SpeechTranscriber.Result, text: String) {
        let now = Date()
        observeDraftText(text, at: now)
        let draftStability = currentDraftStability(at: now)
        let silenceMs = draftStability.silenceMs
        let stabilityScore = draftStability.stabilityScore

        let boundaryScore: Float = SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) ? 0.9 : 0.45
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
    /// Uses the mode's minSilenceCommitMs, floored at 280 ms (280–340 ms) — much faster
    /// than the ASR-inactivity timer (600+ ms).
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

        // SpeechAnalyzer commits only finalized results, so a pause asks the transcriber
        // to finalize now instead of committing the volatile draft here.
        if recognitionBackend == .speechAnalyzer {
            if trigger == .vadOffset,
               Self.shouldDeferModernVADFinalization(of: lastDraftText, languageCode: activeLanguageCode) {
                return
            }
            requestModernFinalization(through: nil)
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
        let boundaryScore: Float = SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) ? 0.9 : 0.45

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

/// Turns the session's SpeechTranscriber results into committed text and a draft line.
///
/// A transcriber that reported a volatile result need not reissue it as final when
/// finalization leaves it unchanged, so its own results cannot tell when its text is
/// final. The session therefore runs a second transcriber on the same analyzer that
/// reports only final results, which it always delivers. Those results are committed
/// as they arrive. The first transcriber's results, final or not, only make up the
/// draft, which drops the text a commit covers and keeps the rest.
struct TranscriberResultLedger {
    /// One run of transcribed text and the audio it covers.
    struct Piece: Equatable {
        let text: String
        let range: CMTimeRange
    }

    /// How long committed text is kept for cutting it out of draft pieces that started
    /// before the commit.
    static let committedTextMemory = CMTime(seconds: 60, preferredTimescale: 1_000)

    /// Draft text, one entry per result, in audio order.
    private var pending: [[Piece]] = []
    /// Text for audio before this time has been committed.
    private(set) var committedThrough = CMTime.negativeInfinity
    /// Recently committed text, word by word.
    private var recentCommitted: [Piece] = []

    /// The draft text as the draft line should read it.
    var draftText: String {
        Self.joined(pending.map(Self.text(of:)))
    }

    /// Takes a result from the transcriber that reports volatile results. It replaces
    /// what the draft said about the same audio, and commits nothing.
    mutating func applyDraft(_ pieces: [Piece], range: CMTimeRange) {
        // Everything this result covers has been committed.
        guard CMTimeCompare(range.end, committedThrough) > 0 else {
            return
        }

        // A result replaces what earlier results said about the same audio; what they
        // said about audio on either side of it still stands.
        if CMTimeCompare(range.start, range.end) < 0 {
            pending = pending
                .flatMap { entry in
                    [
                        entry.filter { CMTimeCompare($0.range.end, range.start) <= 0 },
                        entry.filter { CMTimeCompare($0.range.start, range.end) >= 0 }
                    ]
                }
                .filter { $0.isEmpty == false }
        }

        let freshPieces = pieces.compactMap { uncommittedPart(of: $0) }
        if Self.text(of: freshPieces).isEmpty == false {
            pending.append(freshPieces)
            pending.sort { CMTimeCompare($0[0].range.start, $1[0].range.start) < 0 }
        }
    }

    /// Takes a result from the final-only transcriber and returns the text to commit.
    mutating func commit(_ pieces: [Piece], range: CMTimeRange, resultsFinalizationTime: CMTime) -> String? {
        // Everything this result covers has been committed: it repeats one already taken.
        guard CMTimeCompare(range.end, committedThrough) > 0 else {
            return nil
        }

        let freshPieces = pieces.filter { CMTimeCompare($0.range.end, committedThrough) > 0 }

        // No final text will come for audio before the finalization time, so the draft
        // keeps only what follows it.
        var through = range.end
        if resultsFinalizationTime.isNumeric {
            through = CMTimeMaximum(through, resultsFinalizationTime)
        }
        committedThrough = through
        recentCommitted += freshPieces
        let forgetBefore = CMTimeSubtract(committedThrough, Self.committedTextMemory)
        recentCommitted.removeAll { CMTimeCompare($0.range.end, forgetBefore) <= 0 }
        pending = pending
            .map { entry in entry.compactMap { uncommittedPart(of: $0) } }
            .filter { $0.isEmpty == false }

        let committedText = Self.text(of: freshPieces)
        return committedText.isEmpty ? nil : committedText
    }

    /// The part of a draft piece that has not been committed, or nil when none is left.
    ///
    /// A volatile result is one piece for all its text, so a commit can cover only its
    /// start, and the two transcribers can end the same words at slightly different
    /// times. A piece that runs past the commit is cut after the words it shares with
    /// the text committed for its audio.
    private func uncommittedPart(of piece: Piece) -> Piece? {
        if CMTimeCompare(piece.range.start, committedThrough) >= 0 {
            return piece
        }
        if CMTimeCompare(piece.range.end, committedThrough) <= 0 {
            return nil
        }

        // Committed words that lie mostly within the piece's committed audio.
        let committedText = Self.text(of: recentCommitted.filter { committed in
            let doubledMiddle = CMTimeAdd(committed.range.start, committed.range.end)
            return CMTimeCompare(doubledMiddle, CMTimeMultiply(piece.range.start, multiplier: 2)) >= 0
                && CMTimeCompare(doubledMiddle, CMTimeMultiply(committedThrough, multiplier: 2)) < 0
        })
        guard let tail = Self.text(of: piece.text, after: committedText) else {
            return nil
        }
        return Piece(text: tail, range: CMTimeRange(start: committedThrough, end: piece.range.end))
    }

    /// What is left of `text` once the words it shares with `committedText` are cut
    /// from its start, or nil when nothing is. Words are compared by their letters and
    /// digits, each CJK character counting as a word, so case and punctuation changed
    /// by finalization still match. Where words differ, the cut goes where `text`
    /// matches `committedText` most closely, after as many words as it has.
    static func text(of text: String, after committedText: String) -> String? {
        let committedWords = comparableWords(in: committedText).map(\.word)
        let words = comparableWords(in: text)
        guard words.isEmpty == false else {
            return nil
        }

        // distances[j]: edit distance between the committed words and the first j words.
        var distances = Array(0...words.count)
        for committedWord in committedWords {
            var next = [distances[0] + 1]
            for (j, word) in words.enumerated() {
                next.append(min(
                    distances[j] + (word.word == committedWord ? 0 : 1),
                    distances[j + 1] + 1,
                    next[j] + 1
                ))
            }
            distances = next
        }

        let cut = distances.indices.min { lhs, rhs in
            (distances[lhs], abs(lhs - committedWords.count)) < (distances[rhs], abs(rhs - committedWords.count))
        } ?? 0
        guard cut < words.count else {
            return nil
        }
        return String(text[words[cut].start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func comparableWords(in text: String) -> [(word: String, start: String.Index)] {
        var words: [(word: String, start: String.Index)] = []
        var word = ""
        var wordStart = text.startIndex
        for index in text.indices {
            let character = text[index]
            if String(character).containsCJKCharacters {
                if word.isEmpty == false {
                    words.append((word, wordStart))
                    word = ""
                }
                words.append((String(character), index))
            } else if character.isLetter || character.isNumber {
                if word.isEmpty {
                    wordStart = index
                }
                word += character.lowercased()
            } else if word.isEmpty == false {
                words.append((word, wordStart))
                word = ""
            }
        }
        if word.isEmpty == false {
            words.append((word, wordStart))
        }
        return words
    }

    /// Drops the draft text and returns it.
    mutating func removePending() -> String {
        let text = draftText
        pending.removeAll()
        return text
    }

    /// Gives each run of a result an audio range. A run without one, often punctuation,
    /// takes the range of the timed run before it, or of the first timed run when it
    /// leads the text. Ranges are kept inside the result's own range.
    static func pieces(
        from runs: [(text: String, audioRange: CMTimeRange?)],
        resultRange: CMTimeRange
    ) -> [Piece] {
        func timed(_ range: CMTimeRange?) -> CMTimeRange? {
            guard let range, range.start.isNumeric, range.end.isNumeric else {
                return nil
            }
            guard resultRange.start.isNumeric, resultRange.end.isNumeric else {
                return range
            }

            let start = CMTimeMaximum(range.start, resultRange.start)
            let end = CMTimeMaximum(CMTimeMinimum(range.end, resultRange.end), start)
            return CMTimeRange(start: start, end: end)
        }

        var currentRange = runs.lazy.compactMap { timed($0.audioRange) }.first ?? resultRange
        return runs.map { run in
            if let range = timed(run.audioRange) {
                currentRange = range
            }
            return Piece(text: run.text, range: currentRange)
        }
    }

    private static func text(of pieces: [Piece]) -> String {
        pieces.map(\.text).joined()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins text from separate results, with a space between them unless either side
    /// is CJK.
    private static func joined(_ texts: [String]) -> String {
        var joinedText = ""
        for text in texts where text.isEmpty == false {
            if let last = joinedText.last,
               let first = text.first,
               String(last).containsCJKCharacters == false,
               String(first).containsCJKCharacters == false {
                joinedText += " "
            }
            joinedText += text
        }
        return joinedText
    }
}

/// Why an app-audio capture stopped delivering the audio it was built for. Each one
/// makes the session tear the capture down and build it again.
enum ApplicationCaptureChange: Equatable {
    /// The tap or the aggregate device switched format, as when the app's Bluetooth
    /// output drops into the hands-free profile.
    case formatChanged
    /// An IO cycle's buffer list no longer matches the tap's format.
    case streamLayoutChanged
    /// The private aggregate device went away.
    case deviceDied
    /// The system output route changed.
    case defaultOutputChanged
    /// No IO cycle arrived while the app was playing audio.
    case stalled
    /// Only digital silence arrived for the whole silence window while the app was
    /// playing audio.
    case silentWhileAppIsPlaying
}

enum ApplicationCaptureEvent: Equatable {
    /// The capture no longer matches its audio and has to be rebuilt.
    case invalidated(ApplicationCaptureChange)
    /// Core Audio's process list changed, so the app may have started or stopped an
    /// audio process.
    case processListChanged
    /// The first buffer carrying signal arrived.
    case receivingAudio
}

/// Keeps a rebuild reserved through asynchronous process resolution. A route change
/// supersedes a process refresh, and the superseded result cannot replace the capture.
struct ApplicationCaptureRebuildSchedule {
    struct Request: Equatable {
        let id = UUID()
        let onlyIfProcessesChanged: Bool
    }

    private(set) var current: Request?
    /// The current request has started resolving the app's processes.
    private var isResolving = false
    /// A process-list change arrived while the current request was resolving, so its
    /// snapshot of the app's processes may already be out of date.
    private(set) var needsFollowUpRefresh = false

    mutating func schedule(onlyIfProcessesChanged: Bool) -> Request? {
        if let current, onlyIfProcessesChanged || !current.onlyIfProcessesChanged {
            if onlyIfProcessesChanged, isResolving {
                needsFollowUpRefresh = true
            }
            return nil
        }
        let request = Request(onlyIfProcessesChanged: onlyIfProcessesChanged)
        current = request
        // The new request resolves the processes itself, after this change.
        isResolving = false
        needsFollowUpRefresh = false
        return request
    }

    /// Marks `request` as resolving. Returns false when a newer request superseded it.
    mutating func beginResolving(_ request: Request) -> Bool {
        guard current == request else {
            return false
        }
        isResolving = true
        return true
    }

    mutating func finish(_ request: Request) -> Bool {
        guard current == request else {
            return false
        }
        current = nil
        isResolving = false
        return true
    }

    /// Whether a refresh has to follow the request that just finished. Asking clears it.
    mutating func takeFollowUpRefresh() -> Bool {
        defer { needsFollowUpRefresh = false }
        return needsFollowUpRefresh
    }

    mutating func cancel() {
        current = nil
        isResolving = false
        needsFollowUpRefresh = false
    }
}

/// Tracks IO health on the capture queue, including the active silence timeout.
struct ApplicationCaptureHealth {
    /// A playing app whose capture runs no IO cycle for this long has stalled.
    static let stallTimeout: TimeInterval = 3

    private(set) var silenceWindow: TimeInterval
    private var lastIOCycleTime: TimeInterval = 0
    private var lastSignalTime: TimeInterval = 0
    private var hasReportedAudio = false

    init(silenceWindow: TimeInterval) {
        self.silenceWindow = silenceWindow
    }

    mutating func start(at time: TimeInterval) {
        lastIOCycleTime = time
        lastSignalTime = time
    }

    /// Returns true for the first audible cycle, which also resets session backoff.
    mutating func recordCycle(at time: TimeInterval, hasSignal: Bool) -> Bool {
        lastIOCycleTime = time
        guard hasSignal else {
            return false
        }
        lastSignalTime = time
        silenceWindow = ApplicationCaptureRecoveryPolicy.silenceWindows[0]
        defer { hasReportedAudio = true }
        return !hasReportedAudio
    }

    mutating func check(at time: TimeInterval, isAppPlaying: Bool) -> ApplicationCaptureChange? {
        guard isAppPlaying else {
            start(at: time)
            return nil
        }
        if time - lastIOCycleTime > Self.stallTimeout {
            return .stalled
        }
        if time - lastSignalTime > silenceWindow {
            return .silentWhileAppIsPlaying
        }
        return nil
    }
}

/// Paces how an app-audio capture is rebuilt after it stops delivering audio.
struct ApplicationCaptureRecoveryPolicy {
    /// Delays before retrying a rebuild that failed. Once they run out the capture is
    /// given up and the session reports it.
    static let failedRebuildRetryDelays: [TimeInterval] = [0.5, 1, 2, 4]
    /// How long a playing app may send only digital silence before the capture is
    /// rebuilt. It grows while rebuilds keep coming back silent, so an app that holds its
    /// output open without sound is not rebuilt every few seconds.
    static let silenceWindows: [TimeInterval] = [8, 15, 30, 60]
    /// More replacements of one kind than this within `rebuildWindow` are not converging.
    static let maximumRebuildsPerWindow = 8
    static let rebuildWindow: TimeInterval = 60

    /// Why a capture is being replaced. Each kind has its own allowance, so helper
    /// processes coming and going cannot use up the rebuilds a broken capture needs.
    enum RebuildKind: Hashable {
        /// The running capture stopped delivering its audio.
        case recovery
        /// The app's audio processes changed while the capture kept working.
        case processChange
    }

    private(set) var consecutiveFailedRebuilds = 0
    private(set) var consecutiveSilentCaptures = 0
    private var recentRebuildTimes: [RebuildKind: [TimeInterval]] = [:]

    var silenceWindow: TimeInterval {
        Self.silenceWindows[min(consecutiveSilentCaptures, Self.silenceWindows.count - 1)]
    }

    /// Records a replacement of `kind` at `time`. Returns nil when it may go ahead, or
    /// how long until the window has room for another one.
    mutating func admitRebuild(_ kind: RebuildKind, at time: TimeInterval) -> TimeInterval? {
        var times = recentRebuildTimes[kind, default: []].filter { time - $0 < Self.rebuildWindow }
        defer { recentRebuildTimes[kind] = times }

        if times.count >= Self.maximumRebuildsPerWindow, let oldest = times.first {
            return oldest + Self.rebuildWindow - time
        }

        times.append(time)
        return nil
    }

    /// Records a failed rebuild. Returns the delay before the next attempt, or nil once
    /// the retries are exhausted.
    mutating func delayAfterFailedRebuild() -> TimeInterval? {
        guard consecutiveFailedRebuilds < Self.failedRebuildRetryDelays.count else {
            return nil
        }

        let delay = Self.failedRebuildRetryDelays[consecutiveFailedRebuilds]
        consecutiveFailedRebuilds += 1
        return delay
    }

    mutating func recordSuccessfulRebuild() {
        consecutiveFailedRebuilds = 0
    }

    mutating func recordSilentCapture() {
        consecutiveSilentCaptures += 1
    }

    mutating func recordAudibleCapture() {
        consecutiveSilentCaptures = 0
    }
}

/// Checks the buffer lists an app-audio capture's IO cycle delivers.
enum ApplicationCaptureBufferLayout {
    /// Peaks at or below this (-120 dBFS) are digital silence. A tap that lost its
    /// audio delivers exact zeros, while a live call's comfort noise sits far above it.
    static let silenceThreshold: Float = 1e-6

    /// Whether `buffers` holds exactly one non-empty stream in `format`. The aggregate
    /// device carries only the tap, so any other layout means its configuration changed.
    static func matches(_ buffers: UnsafeMutableAudioBufferListPointer, format: AVAudioFormat) -> Bool {
        let expectedBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        let channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame

        guard expectedBufferCount > 0,
              buffers.count == expectedBufferCount,
              bytesPerFrame > 0,
              let byteSize = buffers.first?.mDataByteSize,
              byteSize > 0,
              byteSize % bytesPerFrame == 0 else {
            return false
        }

        return buffers.allSatisfy {
            $0.mData != nil && $0.mDataByteSize == byteSize && $0.mNumberChannels == channelsPerBuffer
        }
    }

    /// Whether any Float32 sample rises above digital silence. Other sample formats are
    /// assumed to carry signal, so they never read as a silent tap.
    static func containsSignal(_ buffers: UnsafeMutableAudioBufferListPointer, format: AVAudioFormat) -> Bool {
        guard format.commonFormat == .pcmFormatFloat32 else {
            return true
        }

        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }

            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            )

            if samples.contains(where: { abs($0) > silenceThreshold }) {
                return true
            }
        }

        return false
    }
}

final class ApplicationAudioCapture {
    enum CaptureError: Error {
        case permissionDenied
        case tapFormatUnavailable
        case failed(stage: String, status: OSStatus)
    }

    private struct PropertyListener {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
    }

    private enum IOCycle {
        case empty
        case audio(AVAudioPCMBuffer, hasSignal: Bool)
        /// The buffer list did not match the tap's format.
        case unreadable
    }

    private static let healthCheckInterval: DispatchTimeInterval = .seconds(1)

    let processObjectIDs: [AudioObjectID]
    private let appName: String
    private let queue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "com.franklioxygen.v2s.capture.io", qos: .userInteractive)
    private let audioHandler: (AVAudioPCMBuffer) -> Void
    private let eventHandler: (ApplicationCaptureEvent) -> Void

    private var processTapID: AudioObjectID?
    private var aggregateDeviceID: AudioObjectID?
    private var deviceIOProcID: AudioDeviceIOProcID?
    /// The tap's own format when the capture started.
    private var tapFormat: AVAudioFormat?
    /// The format the IO cycle delivers: that of the aggregate device's tap stream.
    private var streamFormat: AVAudioFormat?
    private var propertyListeners: [PropertyListener] = []
    private var propertyListenerToken: PropertyListenerRegistry.Token?
    private var healthTimer: DispatchSourceTimer?

    // Accessed only on `queue`, which also receives the IO cycles and property changes.
    private var isRunning = false
    private var hasReportedInvalidation = false
    private var health: ApplicationCaptureHealth

    init(
        appName: String,
        processObjectIDs: [AudioObjectID],
        silenceWindow: TimeInterval,
        queue: DispatchQueue,
        audioHandler: @escaping (AVAudioPCMBuffer) -> Void,
        eventHandler: @escaping (ApplicationCaptureEvent) -> Void
    ) {
        self.appName = appName
        self.processObjectIDs = processObjectIDs
        self.health = ApplicationCaptureHealth(silenceWindow: silenceWindow)
        self.queue = queue
        self.audioHandler = audioHandler
        self.eventHandler = eventHandler
    }

    func start() throws {
        do {
            let tapDescription = CATapDescription(monoMixdownOfProcesses: processObjectIDs)
            tapDescription.uuid = UUID()
            tapDescription.muteBehavior = .unmuted
            tapDescription.isPrivate = true
            tapDescription.name = "v2s \(appName)"

            var processTapID = kAudioObjectUnknown
            try CoreAudioHAL.check(AudioHardwareCreateProcessTap(tapDescription, &processTapID))
            guard processTapID != kAudioObjectUnknown else {
                throw CaptureError.failed(stage: "create the process tap", status: kAudioHardwareIllegalOperationError)
            }

            self.processTapID = processTapID

            // The aggregate device carries only the tap. With an output device as a
            // sub-device, capture would depend on whichever device was the default output
            // at start, and a headset's microphone would become an input stream in front
            // of the tap. Running that microphone would also force a Bluetooth headset
            // into its hands-free profile.
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "v2s-\(appName)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: try CoreAudioHAL.string(of: processTapID, kAudioTapPropertyUID)
                    ]
                ]
            ]

            var aggregateDeviceID = kAudioObjectUnknown
            try CoreAudioHAL.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
            )
            guard aggregateDeviceID != kAudioObjectUnknown else {
                throw CaptureError.failed(stage: "create the aggregate device", status: kAudioHardwareIllegalOperationError)
            }

            self.aggregateDeviceID = aggregateDeviceID

            var tapStreamDescription = try CoreAudioHAL.value(
                of: processTapID,
                kAudioTapPropertyFormat,
                initialValue: AudioStreamBasicDescription()
            )
            guard let tapFormat = AVAudioFormat(streamDescription: &tapStreamDescription) else {
                throw CaptureError.tapFormatUnavailable
            }

            self.tapFormat = tapFormat
            let streamFormat = Self.tapStreamFormat(of: aggregateDeviceID) ?? tapFormat
            self.streamFormat = streamFormat

            // The IO block gets its own queue. Core Audio holds the device's IO lock while
            // the block runs, so running it on the capture queue would deadlock whenever
            // the capture queue stops the device during an IO cycle.
            var deviceIOProcID: AudioDeviceIOProcID?
            let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
                &deviceIOProcID,
                aggregateDeviceID,
                ioQueue
            ) { [weak self, queue] _, inputData, _, _, _ in
                let cycle = Self.readIOCycle(inputData, format: streamFormat)
                queue.async {
                    self?.handleIOCycle(cycle)
                }
            }

            guard createIOProcStatus == noErr, let deviceIOProcID else {
                throw CaptureError.failed(stage: "create the capture callback", status: createIOProcStatus)
            }

            self.deviceIOProcID = deviceIOProcID

            let now = Self.currentTime()
            health.start(at: now)
            isRunning = true

            let startStatus = AudioDeviceStart(aggregateDeviceID, deviceIOProcID)
            guard startStatus == noErr else {
                throw CaptureError.failed(stage: "start app audio capture", status: startStatus)
            }

            installPropertyListeners(tapID: processTapID, deviceID: aggregateDeviceID)
            startHealthChecks()
        } catch let error as CoreAudioHAL.StatusError {
            stop()

            if error.status == permErr {
                throw CaptureError.permissionDenied
            }

            throw CaptureError.failed(stage: "configure app audio capture", status: error.status)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        isRunning = false
        healthTimer?.cancel()
        healthTimer = nil
        // Listeners go first: they are registered on the tap and the aggregate device.
        removePropertyListeners()

        if let aggregateDeviceID, let deviceIOProcID {
            AudioDeviceStop(aggregateDeviceID, deviceIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceIOProcID)
        }

        deviceIOProcID = nil

        if let aggregateDeviceID {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        aggregateDeviceID = nil

        if let processTapID {
            AudioHardwareDestroyProcessTap(processTapID)
        }

        processTapID = nil
        tapFormat = nil
        streamFormat = nil
    }

    /// Reads one IO cycle on the IO queue. The buffer list is only valid during the
    /// cycle, so the tap's samples are copied before they leave it.
    private static func readIOCycle(_ inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> IOCycle {
        let mutableAudioBufferList = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        let buffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        guard buffers.contains(where: { $0.mDataByteSize > 0 }) else {
            return .empty
        }

        guard ApplicationCaptureBufferLayout.matches(buffers, format: format),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  bufferListNoCopy: mutableAudioBufferList,
                  deallocator: nil
              )?.copied() else {
            return .unreadable
        }

        return .audio(buffer, hasSignal: ApplicationCaptureBufferLayout.containsSignal(buffers, format: format))
    }

    private func handleIOCycle(_ cycle: IOCycle) {
        guard isRunning else {
            return
        }

        let now = Self.currentTime()
        let hasSignal: Bool
        if case .audio(_, let signal) = cycle {
            hasSignal = signal
        } else {
            hasSignal = false
        }
        if health.recordCycle(at: now, hasSignal: hasSignal) {
            eventHandler(.receivingAudio)
        }

        switch cycle {
        case .empty:
            break
        case .unreadable:
            invalidate(.streamLayoutChanged)
        case .audio(let buffer, _):
            audioHandler(buffer)
        }
    }

    // MARK: Change detection

    private func installPropertyListeners(tapID: AudioObjectID, deviceID: AudioObjectID) {
        // Core Audio notifies on its own thread; the change is handled on the capture
        // queue, which owns all of this object's state.
        propertyListenerToken = PropertyListenerRegistry.shared.register { [weak self, queue] selector in
            queue.async {
                self?.handlePropertyChange(selector)
            }
        }

        let systemID = AudioObjectID(kAudioObjectSystemObject)
        addPropertyListener(tapID, kAudioTapPropertyFormat)
        addPropertyListener(deviceID, kAudioDevicePropertyNominalSampleRate)
        addPropertyListener(deviceID, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        addPropertyListener(deviceID, kAudioDevicePropertyDeviceIsAlive)
        addPropertyListener(systemID, kAudioHardwarePropertyDefaultOutputDevice)
        addPropertyListener(systemID, kAudioHardwarePropertyProcessObjectList)
    }

    private func addPropertyListener(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        guard let propertyListenerToken else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListener(
            objectID,
            &address,
            PropertyListenerRegistry.listenerProc,
            propertyListenerToken.clientData
        )
        guard status == noErr else {
            Logger.appAudioCapture.error(
                "Could not watch property \(selector) of object \(objectID): \(status.readableDescription, privacy: .public)"
            )
            return
        }

        propertyListeners.append(PropertyListener(objectID: objectID, address: address))
    }

    private func removePropertyListeners() {
        guard let propertyListenerToken else {
            return
        }

        for listener in propertyListeners {
            var address = listener.address
            AudioObjectRemovePropertyListener(
                listener.objectID,
                &address,
                PropertyListenerRegistry.listenerProc,
                propertyListenerToken.clientData
            )
        }

        propertyListeners.removeAll()
        // A notification already in flight finds no handler and is dropped.
        PropertyListenerRegistry.shared.unregister(propertyListenerToken)
        self.propertyListenerToken = nil
    }

    private func handlePropertyChange(_ selector: AudioObjectPropertySelector) {
        guard isRunning else {
            return
        }

        switch selector {
        case kAudioHardwarePropertyProcessObjectList:
            eventHandler(.processListChanged)
        case kAudioHardwarePropertyDefaultOutputDevice:
            invalidate(.defaultOutputChanged)
        case kAudioDevicePropertyDeviceIsAlive:
            let isAlive = aggregateDeviceID.flatMap {
                try? CoreAudioHAL.value(of: $0, kAudioDevicePropertyDeviceIsAlive, initialValue: UInt32(0))
            }
            if (isAlive ?? 0) == 0 {
                invalidate(.deviceDied)
            }
        default:
            if formatChanged() {
                invalidate(.formatChanged)
            }
        }
    }

    /// Whether the tap, or the aggregate device's tap stream, now has a different format
    /// from the one this capture was built with.
    private func formatChanged() -> Bool {
        guard let processTapID, let aggregateDeviceID, let tapFormat, let streamFormat else {
            return false
        }

        if var tapStreamDescription = try? CoreAudioHAL.value(
               of: processTapID,
               kAudioTapPropertyFormat,
               initialValue: AudioStreamBasicDescription()
           ),
           let currentTapFormat = AVAudioFormat(streamDescription: &tapStreamDescription),
           currentTapFormat.matches(tapFormat) == false {
            return true
        }

        if let currentStreamFormat = Self.tapStreamFormat(of: aggregateDeviceID),
           currentStreamFormat.matches(streamFormat) == false {
            return true
        }

        return false
    }

    /// Catches failures that Core Audio sends no notification for. Stalls and silence
    /// only count while the app is playing, since an idle app legitimately sends nothing.
    private func startHealthChecks() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.healthCheckInterval, repeating: Self.healthCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        timer.resume()
        healthTimer = timer
    }

    private func checkHealth() {
        guard isRunning else {
            return
        }

        if let change = health.check(at: Self.currentTime(), isAppPlaying: isAppPlaying()) {
            invalidate(change)
        }
    }

    private func isAppPlaying() -> Bool {
        processObjectIDs.contains { (try? AudioHardwareProcess(id: $0).isRunningOutput) == true }
    }

    /// Reports the first change only: the session replaces this capture in response.
    private func invalidate(_ change: ApplicationCaptureChange) {
        guard isRunning, hasReportedInvalidation == false else {
            return
        }

        hasReportedInvalidation = true
        eventHandler(.invalidated(change))
    }

    /// The format of the aggregate device's tap stream, which is what the IO cycle delivers.
    private static func tapStreamFormat(of deviceID: AudioObjectID) -> AVAudioFormat? {
        guard let streamIDs = try? CoreAudioHAL.objectIDs(of: deviceID, kAudioDevicePropertyStreams),
              let tapStreamID = streamIDs.last(where: {
                  (try? CoreAudioHAL.value(of: $0, kAudioStreamPropertyDirection, initialValue: UInt32(0)))
                      == CoreAudioHAL.inputDirection
              }),
              var streamDescription = try? CoreAudioHAL.value(
                  of: tapStreamID,
                  kAudioStreamPropertyVirtualFormat,
                  initialValue: AudioStreamBasicDescription()
              ) else {
            return nil
        }

        return AVAudioFormat(streamDescription: &streamDescription)
    }

    private static func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// The Core Audio C calls that app audio capture makes, with failures thrown as their `OSStatus`.
///
/// The Swift wrappers (`AudioHardwareSystem.makeProcessTap(description:)` and the like) throw
/// `AudioHardwareError`, whose `error` property is only exported by macOS 26's libswiftCoreAudio
/// even though the SDK marks it available from macOS 15. Reading it binds a symbol macOS 15
/// does not have, and dyld then refuses to launch the app there.
private enum CoreAudioHAL {
    struct StatusError: Error {
        let status: OSStatus
    }

    /// `kAudioStreamPropertyDirection` is 0 for an output stream and 1 for an input stream.
    static let inputDirection: UInt32 = 1

    static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw StatusError(status: status)
        }
    }

    static func value<Value>(
        of objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        initialValue: Value
    ) throws -> Value {
        var address = globalAddress(selector)
        var value = initialValue
        var size = UInt32(MemoryLayout<Value>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, bytes.baseAddress!))
        }
        return value
    }

    static func string(of objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value))
        guard let value else {
            throw StatusError(status: kAudioHardwareUnspecifiedError)
        }

        return value.takeRetainedValue() as String
    }

    static func objectIDs(of objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = globalAddress(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size))

        let stride = MemoryLayout<AudioObjectID>.stride
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / stride)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &objectIDs))
        return Array(objectIDs.prefix(Int(size) / stride))
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// Routes Core Audio property notifications to the capture that asked for them.
///
/// Listeners are registered with a C function and client data because Core Audio
/// matches removals on exactly that pair. Removing a Swift closure registered through
/// `AudioObjectRemovePropertyListenerBlock` leaves it installed, which would leak a live
/// listener on every rebuild. The client data is a token looked up here rather than an
/// object pointer, so a notification that arrives after removal cannot reach freed memory.
private final class PropertyListenerRegistry: @unchecked Sendable {
    struct Token {
        let value: Int

        var clientData: UnsafeMutableRawPointer? {
            UnsafeMutableRawPointer(bitPattern: value)
        }
    }

    static let shared = PropertyListenerRegistry()

    static let listenerProc: AudioObjectPropertyListenerProc = { _, addressCount, addresses, clientData in
        let token = Int(bitPattern: clientData)
        for index in 0..<Int(addressCount) {
            PropertyListenerRegistry.shared.notify(token: token, selector: addresses[index].mSelector)
        }
        return noErr
    }

    private let lock = NSLock()
    private var nextTokenValue = 1
    private var handlers: [Int: (AudioObjectPropertySelector) -> Void] = [:]

    func register(_ handler: @escaping (AudioObjectPropertySelector) -> Void) -> Token {
        lock.withLock {
            let value = nextTokenValue
            nextTokenValue += 1
            handlers[value] = handler
            return Token(value: value)
        }
    }

    func unregister(_ token: Token) {
        lock.withLock {
            handlers[token.value] = nil
        }
    }

    private func notify(token: Int, selector: AudioObjectPropertySelector) {
        let handler = lock.withLock { handlers[token] }
        handler?(selector)
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

private extension AVAudioPCMBuffer {
    /// A copy that owns its samples, for audio that must outlive the buffer it came in.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        copy.frameLength = frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
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
    enum RecognitionHeuristicLanguage {
        case japanese
        case english
        case other
    }

    static let minimumLatinLeadingOverlapCharacters = 10
    static let minimumCJKLeadingOverlapCharacters = 4
    static let recentCommittedSentenceLimit = 6
    static let committedPrefixContinuationWindow: TimeInterval = 3.0
    static let dialogueClauseSeparators: Set<Character> = ["、", ",", "，"]
    static let japaneseDialogueClauseEndingSuffixes = [
        "ね", "よ", "の", "な", "さ", "わ", "ぞ", "ぜ", "かな", "かも", "だよ", "だね"
    ]
    static let japaneseDialogueClauseLeadingPhrases = [
        "俺", "私", "僕", "うん", "いや", "や", "でも", "じゃ", "ただいま", "おかえり", "ありがとう", "ごめん"
    ]
    static let modernVADDeferredJapaneseSuffixes = [
        "けど", "けれど", "けれども", "から", "ので", "のに", "とか", "って",
        "で", "て", "が", "を", "に", "へ", "と", "し"
    ]
    static let modernVADDeferredEnglishSuffixes = [
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
