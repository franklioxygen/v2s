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
    let translationContext: SentenceTranslationContext?
    /// Identity of an utterance already deduplicated by its finalized audio range.
    /// Repeating its words later is new speech, not a revision of this utterance.
    let recognitionID: UUID?

    init(text: String, promotionSegmentID: UUID? = nil, translationContext: SentenceTranslationContext? = nil, recognitionID: UUID? = nil) {
        self.text = text
        self.promotionSegmentID = promotionSegmentID
        self.translationContext = translationContext
        self.recognitionID = recognitionID
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
    private var lastModernCommittedResultIdentity: String?
    private var speechAnalyzerState: AnyObject?
    private var speechTranscriberState: AnyObject?
    private var analyzerInputContinuationState: Any?
    private var analyzerInputFormat: AVAudioFormat?
    private var japaneseSentenceAssembler = JapaneseSentenceAssembler()
    private var latestModernText = ""
    private var modernCommittedPrefixText = ""
    /// Committed text that stops mid-sentence, held for the next commit (see `commitModernText`).
    private var modernHeldFragmentText = ""
    private var modernHeldFragmentSince: Date?
    private var modernHeldFragmentTimer: DispatchSourceTimer?
    /// The latest committed sentences in `comparableModernSentence` form.
    private var recentModernCommittedSentences: [String] = []

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
        resetModernTranscriptionState()
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
        clearHeldFragment()
        japaneseSentenceAssembler = JapaneseSentenceAssembler()
        recentModernCommittedSentences.removeAll()
        cancelSilenceTimer()
        cancelVADSilenceTimer()
        resetDraftState()
        lastModernCommittedResultIdentity = nil

        // Initialize Silero VAD engine for draft confidence / silence scoring only.
        do {
            vadEngine = try SileroVADEngine()
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
        // A held fragment was already recognized: keep it in the transcript.
        flushHeldFragment(clearDraftAfter: true)
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

        // Per-buffer gain changes the envelope every ~10 ms. In Japanese video
        // replays this erased quiet syllables and short replies from final results.
        // Preserve the captured waveform for this recognizer; VAD still uses the
        // existing processing, as do the other language and legacy paths.
        let japaneseRecognitionBuffer = recognitionBackend == .speechAnalyzer && activeHeuristicLanguage == .japanese
            ? processingBuffer.copied() : nil
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
            appendToSpeechAnalyzer(japaneseRecognitionBuffer ?? processingBuffer)
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

        if SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: trimmedText) {
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
        resetModernTranscriptionState()
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

    @available(macOS 26.0, *)
    private func processModernRecognitionResult(_ result: SpeechTranscriber.Result) {
        if activeHeuristicLanguage == .japanese {
            processJapaneseRecognitionResult(result)
            return
        }
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

            if text.isEmpty == false {
                commitModernText(text, clearDraftAfter: true)
            } else if modernHeldFragmentText.isEmpty {
                resetDraftState()
                Task { await emitPartialDraft(nil) }
            }
            return
        }

        guard text.isEmpty == false else {
            latestModernText = ""
            cancelSilenceTimer()
            cancelVADSilenceTimer()
            if modernHeldFragmentText.isEmpty {
                Task { await emitPartialDraft(nil) }
            }
            return
        }

        observeDraftText(text, at: now)
        latestModernText = pendingRawText
        if let split = committableModernText(in: pendingRawText),
           split.remainingRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text),
           canFastCommitModernBoundary(at: now) {
            let committedText = split.committedRawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard committedText.isEmpty == false else {
                latestModernText = ""
                if modernHeldFragmentText.isEmpty {
                    Task { await emitPartialDraft(nil) }
                }
                return
            }

            cancelSilenceTimer()
            cancelVADSilenceTimer()
            modernCommittedPrefixText += split.committedRawText
            latestModernText = split.remainingRawText
            commitModernText(committedText, clearDraftAfter: true)
            return
        }

        emitDraftUpdate(
            from: result,
            text: Self.joiningHeldFragment(modernHeldFragmentText, to: text, languageCode: activeLanguageCode)
        )
        scheduleSilenceCommit()
    }

    /// Keep speculative Japanese words on the draft line. Fast results arrive in
    /// roughly one-second batches; an inactivity/VAD timer between batches cannot
    /// establish a sentence boundary or safely remove a prefix from a later revision.
    @available(macOS 26.0, *)
    private func processJapaneseRecognitionResult(_ result: SpeechTranscriber.Result) {
        guard result.range.end.seconds > japaneseSentenceAssembler.finalizedThrough else { return }
        lastRecognitionResultTime = Date()
        let text = normalizedTranscriberText(result.text)
        if !result.isFinal {
            latestModernText = text
            emitDraftUpdate(from: result, text: japaneseSentenceAssembler.preview(appending: text))
            return
        }

        let wordRanges = result.text.runs.compactMap { $0.audioTimeRange }
        let start = wordRanges.map { $0.start.seconds }.filter(\.isFinite).min() ?? result.range.start.seconds
        let end = wordRanges.map { $0.end.seconds }.filter(\.isFinite).max() ?? result.range.end.seconds
        let sentences = japaneseSentenceAssembler.appendFinal(
            text, start: start, end: end, finalizedEnd: result.range.end.seconds
        )
        latestModernText = ""
        emitJapaneseSentences(sentences, clearDraftAfter: japaneseSentenceAssembler.pendingText.isEmpty)
        if japaneseSentenceAssembler.pendingText.isEmpty {
            clearHeldFragment()
        } else {
            if !sentences.isEmpty || modernHeldFragmentSince == nil { modernHeldFragmentSince = Date() }
            emitDraftUpdate(from: result, text: japaneseSentenceAssembler.pendingText)
            scheduleHeldFragmentCheck()
        }
    }

    private func emitJapaneseSentences(_ sentences: [String], clearDraftAfter: Bool) {
        let promotionID = currentDraftId
        if !sentences.isEmpty { resetDraftState() }
        Task { @MainActor in
            // These units already have sentence boundaries and audio-range deduplication.
            // The legacy comma splitter and fuzzy text deduplication would split clauses
            // and drop intentional repetitions, respectively.
            for (index, text) in sentences.enumerated() {
                emitRecognizedSentence(RecognizedSentence(
                    text: text,
                    promotionSegmentID: index == 0 ? promotionID : nil,
                    translationContext: SentenceTranslationContext(
                        sentences: sentences, sentenceIndex: index, draftSegmentID: promotionID
                    ),
                    recognitionID: UUID()
                ))
            }
            if clearDraftAfter { emitPartialDraft(nil) }
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

    private func canFastCommitModernBoundary(at now: Date) -> Bool {
        Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000) >= modernBoundaryCommitStabilityDelayMs
    }

    private func canVADCommitModernDraft(_ rawText: String, at now: Date) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            return false
        }

        // Fast results hold the last word back until more speech follows, so at a pause a
        // draft that does not end its sentence usually stops short of what was said, often
        // mid-word. Leave such a draft to the transcriber's final result.
        guard SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: text) else {
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

    // MARK: - Sentence fragments (SpeechAnalyzer)

    /// Commits text from the SpeechAnalyzer path.
    ///
    /// A pause inside a sentence can hand over half of it: the transcriber finalizes there,
    /// or VAD and inactivity commit the draft. Such a fragment ends on a comma or a
    /// particle, or is a lone connective the transcriber closed with a full stop because
    /// the speaker paused. It is held on the draft line and put in front of the next
    /// commit, so the sentence stays one caption. A fragment nothing follows is committed
    /// on its own once the speaker stops.
    private func commitModernText(_ text: String, clearDraftAfter: Bool) {
        if modernHeldFragmentText.isEmpty == false, repeatsRecentModernCommit(text) {
            // The transcriber can reissue sentences it already committed. They come from
            // before the fragment, so joining them to it would garble the sentence: commit
            // them alone, where emission drops what it recognizes as a repeat, and keep
            // waiting for the fragment's own continuation.
            emitModernCommit(text, clearDraftAfter: false)
            return
        }

        let combinedText = Self.joiningHeldFragment(modernHeldFragmentText, to: text, languageCode: activeLanguageCode)
        guard combinedText.isEmpty == false else {
            return
        }

        if Self.isModernSentenceFragment(combinedText, languageCode: activeLanguageCode) {
            modernHeldFragmentText = combinedText
            if modernHeldFragmentSince == nil {
                modernHeldFragmentSince = Date()
            }
            scheduleHeldFragmentCheck()
            return
        }

        clearHeldFragment()
        emitModernCommit(combinedText, clearDraftAfter: clearDraftAfter)
    }

    private func emitModernCommit(_ text: String, clearDraftAfter: Bool) {
        rememberModernCommit(text)
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
                clearDraftAfter: clearDraftAfter
            )
        }
    }

    private func scheduleHeldFragmentCheck() {
        modernHeldFragmentTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(Self.heldFragmentCheckMs))
        timer.setEventHandler { [weak self] in
            self?.commitHeldFragmentIfSpeechStopped()
        }
        timer.resume()
        modernHeldFragmentTimer = timer
    }

    /// Commits a held fragment on its own once nothing has been said after it for a while,
    /// or once it has waited too long for its sentence to be committed.
    private func commitHeldFragmentIfSpeechStopped() {
        modernHeldFragmentTimer = nil
        let hasFragment = activeHeuristicLanguage == .japanese
            ? !japaneseSentenceAssembler.pendingText.isEmpty
            : !modernHeldFragmentText.isEmpty
        guard hasFragment, let heldSince = modernHeldFragmentSince else {
            return
        }

        let now = Date()
        let speechFollows = latestModernText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let quietFor = now.timeIntervalSince(max(heldSince, lastDraftTextChangeTime))
        if now.timeIntervalSince(heldSince) < Self.maxHeldFragmentSeconds,
           speechFollows || quietFor < Self.heldFragmentQuietSeconds {
            scheduleHeldFragmentCheck()
            return
        }

        flushHeldFragment(clearDraftAfter: speechFollows == false)
    }

    private func flushHeldFragment(clearDraftAfter: Bool) {
        if activeHeuristicLanguage == .japanese {
            let sentences = japaneseSentenceAssembler.flush()
            clearHeldFragment()
            if !sentences.isEmpty { emitJapaneseSentences(sentences, clearDraftAfter: clearDraftAfter) }
            return
        }
        let text = modernHeldFragmentText
        clearHeldFragment()
        guard text.isEmpty == false else {
            return
        }

        emitModernCommit(text, clearDraftAfter: clearDraftAfter)
    }

    private func clearHeldFragment() {
        modernHeldFragmentText = ""
        modernHeldFragmentSince = nil
        modernHeldFragmentTimer?.cancel()
        modernHeldFragmentTimer = nil
    }

    private func rememberModernCommit(_ text: String) {
        recentModernCommittedSentences += splitRecognizedSentences(in: text)
            .map(Self.comparableModernSentence)
            .filter { $0.isEmpty == false }
        if recentModernCommittedSentences.count > Self.recentModernCommitMemory {
            recentModernCommittedSentences.removeFirst(recentModernCommittedSentences.count - Self.recentModernCommitMemory)
        }
    }

    /// Whether text opens with a sentence committed a moment ago.
    private func repeatsRecentModernCommit(_ text: String) -> Bool {
        guard let firstSentence = splitRecognizedSentences(in: text).first else {
            return false
        }

        let comparable = Self.comparableModernSentence(firstSentence)
        return recentModernCommittedSentences.contains { committed in
            // A reissue can also be the tail of a longer committed sentence.
            Self.isNearlySameSentence(committed, comparable)
                || (comparable.count >= Self.minimumReissuedTailLength && committed.hasSuffix(comparable))
        }
    }

    /// A sentence without spacing and punctuation, with katakana folded to hiragana: the
    /// transcriber often revises a word only in which of the two it is written in.
    static func comparableModernSentence(_ text: String) -> String {
        let folded = text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { ignored.contains($0) == false }))
    }

    /// Whether two comparable sentences differ in at most a fifth of their characters.
    static func isNearlySameSentence(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.isEmpty == false, rhs.isEmpty == false else {
            return false
        }

        let a = Array(lhs), b = Array(rhs)
        let allowedEdits = max(a.count, b.count) / 5
        guard abs(a.count - b.count) <= allowedEdits else {
            return false
        }

        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count] <= allowedEdits
    }

    /// Whether committed text stops partway through a sentence.
    static func isModernSentenceFragment(_ rawText: String, languageCode: String?) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastCharacter = text.last else {
            return false
        }

        if dialogueClauseSeparators.contains(lastCharacter) {
            return true
        }

        // A pause can make the transcriber close a fragment with a full stop.
        let body = removingTrailingPauseFullStops(from: text)
        guard body.isEmpty == false else {
            return false
        }

        switch languageCode {
        case "ja":
            if japaneseSentenceInitialConnectives.contains(body) || japaneseLoneParticles.contains(body) {
                return true
            }
            if japaneseGreetingsEndingInTopicParticle.contains(where: { body.hasSuffix($0) }) {
                return false
            }
            return japaneseFragmentEndingSuffixes.contains(where: { body.hasSuffix($0) })
        case "en":
            let normalized = " " + body.lowercased()
            return englishFragmentEndingSuffixes.contains(where: { normalized.hasSuffix($0) })
        default:
            return false
        }
    }

    /// Puts a held fragment in front of the text that continues its sentence. The full
    /// stop a pause gave the fragment goes, since the sentence did not end there.
    static func joiningHeldFragment(_ fragment: String, to text: String, languageCode: String?) -> String {
        let nextText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let heldText = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard heldText.isEmpty == false else {
            return nextText
        }
        guard nextText.isEmpty == false else {
            return heldText
        }

        let opening = removingTrailingPauseFullStops(from: heldText)
        // A revision can repeat the fragment at the start of the text that continues it.
        if opening.count >= 2, nextText.hasPrefix(opening) {
            return nextText
        }

        let separator = opening.containsCJKCharacters || nextText.containsCJKCharacters ? "" : " "
        return opening + separator + nextText
    }

    private static func removingTrailingPauseFullStops(from text: String) -> String {
        var body = text
        while let last = body.last, pauseFullStops.contains(last) {
            body.removeLast()
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Japanese volatile text is a preview, including at a VAD pause. Its
            // finalized result owns the boundary and may still correct the last word.
            guard activeHeuristicLanguage != .japanese else { return }
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
            commitModernText(
                text,
                clearDraftAfter: remainingRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
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

    private let system = AudioHardwareSystem.shared
    private var processTap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
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

            guard let processTap = try system.makeProcessTap(description: tapDescription) else {
                throw CaptureError.failed(stage: "create the process tap", status: kAudioHardwareIllegalOperationError)
            }

            self.processTap = processTap

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
                        kAudioSubTapUIDKey: try processTap.uid
                    ]
                ]
            ]

            guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
                throw CaptureError.failed(stage: "create the aggregate device", status: kAudioHardwareIllegalOperationError)
            }

            self.aggregateDevice = aggregateDevice

            var tapStreamDescription = try processTap.format
            guard let tapFormat = AVAudioFormat(streamDescription: &tapStreamDescription) else {
                throw CaptureError.tapFormatUnavailable
            }

            self.tapFormat = tapFormat
            let streamFormat = Self.tapStreamFormat(of: aggregateDevice) ?? tapFormat
            self.streamFormat = streamFormat

            // The IO block gets its own queue. Core Audio holds the device's IO lock while
            // the block runs, so running it on the capture queue would deadlock whenever
            // the capture queue stops the device during an IO cycle.
            var deviceIOProcID: AudioDeviceIOProcID?
            let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
                &deviceIOProcID,
                aggregateDevice.id,
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

            let startStatus = AudioDeviceStart(aggregateDevice.id, deviceIOProcID)
            guard startStatus == noErr else {
                throw CaptureError.failed(stage: "start app audio capture", status: startStatus)
            }

            installPropertyListeners(tap: processTap, device: aggregateDevice)
            startHealthChecks()
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
        isRunning = false
        healthTimer?.cancel()
        healthTimer = nil
        // Listeners go first: they are registered on the tap and the aggregate device.
        removePropertyListeners()

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

    private func installPropertyListeners(tap: AudioHardwareTap, device: AudioHardwareAggregateDevice) {
        // Core Audio notifies on its own thread; the change is handled on the capture
        // queue, which owns all of this object's state.
        propertyListenerToken = PropertyListenerRegistry.shared.register { [weak self, queue] selector in
            queue.async {
                self?.handlePropertyChange(selector)
            }
        }

        addPropertyListener(tap.id, kAudioTapPropertyFormat)
        addPropertyListener(device.id, kAudioDevicePropertyNominalSampleRate)
        addPropertyListener(device.id, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        addPropertyListener(device.id, kAudioDevicePropertyDeviceIsAlive)
        addPropertyListener(system.id, kAudioHardwarePropertyDefaultOutputDevice)
        addPropertyListener(system.id, kAudioHardwarePropertyProcessObjectList)
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
            if (try? aggregateDevice?.isAlive) != true {
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
        guard let processTap, let aggregateDevice, let tapFormat, let streamFormat else {
            return false
        }

        if var tapStreamDescription = try? processTap.format,
           let currentTapFormat = AVAudioFormat(streamDescription: &tapStreamDescription),
           currentTapFormat.matches(tapFormat) == false {
            return true
        }

        if let currentStreamFormat = Self.tapStreamFormat(of: aggregateDevice),
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
    private static func tapStreamFormat(of device: AudioHardwareAggregateDevice) -> AVAudioFormat? {
        guard let streams = try? device.streams,
              let tapStream = streams.last(where: { (try? $0.direction) == .input }),
              var streamDescription = try? tapStream.virtualFormat else {
            return nil
        }

        return AVAudioFormat(streamDescription: &streamDescription)
    }

    private static func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
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
    /// Endings that leave a sentence unfinished: conjunctions, particles, conditionals.
    static let japaneseFragmentEndingSuffixes = [
        "けど", "けれど", "けれども", "から", "ので", "のに", "とか", "って",
        "で", "て", "が", "を", "に", "へ", "と", "し", "ば", "たら", "なら", "は"
    ]
    static let englishFragmentEndingSuffixes = [
        " and", " or", " but", " so", " because", " if", " when", " that", " to"
    ]
    /// Greetings that end in the topic particle but are complete.
    static let japaneseGreetingsEndingInTopicParticle = ["こんにちは", "こんばんは"]
    /// Words that open a sentence; on their own they are only its start.
    static let japaneseSentenceInitialConnectives: Set<String> = [
        "ただ", "でも", "そこで", "それで", "それから", "そして", "だから", "しかし",
        "ところが", "なので", "つまり", "例えば", "たとえば", "もし", "まず"
    ]
    static let japaneseLoneParticles: Set<String> = ["は", "が", "を", "に", "で", "と", "も", "へ", "の", "や"]
    /// Full stops a pause can put at the end of a fragment. Question and exclamation
    /// marks are left alone: the transcriber adds them for intonation, not for pauses.
    static let pauseFullStops: Set<Character> = ["。", "."]
    static let heldFragmentCheckMs = 300
    /// A held fragment is committed on its own after this long with nothing said after it.
    /// It stays visible on the draft line meanwhile, and the next clause can take two
    /// seconds to show up after a pause.
    static let heldFragmentQuietSeconds: TimeInterval = 3
    /// While speech goes on, a fragment waits for its sentence, which can run long.
    static let maxHeldFragmentSeconds: TimeInterval = 20
    static let recentModernCommitMemory = 8
    /// Shorter tails of committed sentences are too likely to be said again on purpose.
    static let minimumReissuedTailLength = 8
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
