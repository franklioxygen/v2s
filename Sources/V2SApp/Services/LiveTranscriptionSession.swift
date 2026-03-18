import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Speech

struct RecognizedSentence: Equatable, Sendable {
    let text: String
}

final class LiveTranscriptionSession: NSObject {
    enum SessionError: LocalizedError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case audioCapturePermissionDenied
        case unsupportedSpeechLocale(String)
        case unavailableSpeechRecognizer(String)
        case missingMicrophoneDevice
        case missingApplication(String)
        case applicationNotProducingAudio(String)
        case failedToStartCapture(String)

        var errorDescription: String? {
            switch self {
            case .speechPermissionDenied:
                return "Speech recognition permission was denied."
            case .microphonePermissionDenied:
                return "Microphone permission was denied."
            case .audioCapturePermissionDenied:
                return "App audio capture permission was denied. Allow v2s to capture audio from other apps, then reopen the app."
            case .unsupportedSpeechLocale(let localeIdentifier):
                return "Speech recognition does not support \(localeIdentifier)."
            case .unavailableSpeechRecognizer(let localeIdentifier):
                return "Speech recognition is currently unavailable for \(localeIdentifier)."
            case .missingMicrophoneDevice:
                return "The selected microphone is no longer available."
            case .missingApplication(let appName):
                return "The selected app, \(appName), is no longer available."
            case .applicationNotProducingAudio(let appName):
                return "\(appName) is not producing app audio yet. Start playback in the app, then try again."
            case .failedToStartCapture(let reason):
                return reason
            }
        }
    }

    private let captureQueue = DispatchQueue(label: "com.franklioxygen.v2s.capture", qos: .userInitiated)

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Incremented on every restart. Handlers capture their generation at creation time
    /// and discard callbacks that arrive after a newer generation has started.
    private var recognitionGeneration: Int = 0
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputSignature: AudioFormatSignature?
    private var committedSegmentCount = 0

    private var microphoneCaptureSession: AVCaptureSession?
    private var applicationAudioCapture: ApplicationAudioCapture?

    private var transcriptHandler: (@MainActor (RecognizedSentence) -> Void)?
    private var partialHandler: (@MainActor (DraftSegment?) -> Void)?
    private var errorHandler: (@MainActor (String) -> Void)?

    // MARK: Draft state (accessed only on captureQueue)
    private var modeConfig: ModeConfig = .balanced
    private var currentDraftId = UUID()
    private var lastDraftText = ""
    private var lastDraftTextChangeTime = Date.distantPast
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

    func start(
        source: InputSource,
        localeIdentifier: String,
        modeConfig: ModeConfig = .balanced,
        transcriptHandler: @escaping @MainActor (RecognizedSentence) -> Void,
        partialHandler: @escaping @MainActor (DraftSegment?) -> Void,
        errorHandler: @escaping @MainActor (String) -> Void
    ) async throws {
        self.transcriptHandler = transcriptHandler
        self.partialHandler = partialHandler
        self.modeConfig = modeConfig
        self.errorHandler = errorHandler

        try await requestRequiredPermissions(for: source)
        try configureSpeechRecognizer(localeIdentifier: localeIdentifier)

        switch source.category {
        case .microphone:
            try startMicrophoneCapture(deviceUniqueID: source.detail)
        case .application:
            try startApplicationAudioCapture(source: source)
        }
    }

    func stop() {
        cancelSilenceTimer()
        cancelVADSilenceTimer()

        microphoneCaptureSession?.stopRunning()
        microphoneCaptureSession = nil

        applicationAudioCapture?.stop()
        applicationAudioCapture = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        audioConverter = nil
        audioConverterInputSignature = nil
        committedSegmentCount = 0

        vadEngine = nil
        lastVADProbability = 0

        latestSegments = []
        latestFormattedText = ""
        partialHandler = nil
        resetDraftState()
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
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SessionError.unsupportedSpeechLocale(localeIdentifier)
        }

        guard recognizer.isAvailable else {
            throw SessionError.unavailableSpeechRecognizer(localeIdentifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionTask = task
        audioConverter = nil
        audioConverterInputSignature = nil
        committedSegmentCount = 0
        latestSegments = []
        latestFormattedText = ""
        cancelSilenceTimer()
        resetDraftState()

        // Initialize Silero VAD engine.
        do {
            vadEngine = try SileroVADEngine()
        } catch {
            // VAD is optional — fall back to implicit ASR-based silence detection.
            vadEngine = nil
            Task { await emitError("Silero VAD unavailable: \(error.localizedDescription). Falling back to ASR-based silence detection.") }
        }
    }

    private func startMicrophoneCapture(deviceUniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw SessionError.missingMicrophoneDevice
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(input) else {
            throw SessionError.failedToStartCapture("Could not add the selected microphone to the capture session.")
        }

        guard session.canAddOutput(output) else {
            throw SessionError.failedToStartCapture("Could not add an audio output to the microphone capture session.")
        }

        session.beginConfiguration()
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(output)
        session.commitConfiguration()

        microphoneCaptureSession = session
        captureQueue.async {
            session.startRunning()
        }
    }

    private func startApplicationAudioCapture(source: InputSource) throws {
        let processObjectIDs = try resolveApplicationProcessObjectIDs(for: source)
        let capture = ApplicationAudioCapture(
            appName: source.name,
            processObjectIDs: processObjectIDs,
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
            throw SessionError.failedToStartCapture("Failed to start application audio capture: \(error.localizedDescription)")
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
        } else {
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
        guard audioBuffer.frameLength > 0,
              let recognitionRequest else {
            return
        }

        let nativeFormat = recognitionRequest.nativeAudioFormat

        if audioBuffer.format.matches(nativeFormat) {
            recognitionRequest.append(audioBuffer)
            return
        }

        let inputSignature = AudioFormatSignature(audioBuffer.format)

        if audioConverterInputSignature != inputSignature {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: nativeFormat)
            audioConverterInputSignature = inputSignature
        }

        guard let audioConverter else {
            Task {
                await emitError("Failed to prepare the audio converter for speech recognition.")
            }
            return
        }

        let outputFrameCapacity = max(
            AVAudioFrameCount(ceil(Double(audioBuffer.frameLength) * nativeFormat.sampleRate / audioBuffer.format.sampleRate)),
            1
        )

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: outputFrameCapacity) else {
            Task {
                await emitError("Failed to allocate a speech-recognition audio buffer.")
            }
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = audioConverter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return audioBuffer
        }

        if let conversionError {
            Task {
                await emitError("Failed to convert captured audio: \(conversionError.localizedDescription)")
            }
            return
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if convertedBuffer.frameLength > 0 {
                // Boost quiet audio before the VAD / recognizer sees it.
                boostIfQuiet(buffer: convertedBuffer)

                if let vadEngine {
                    let vadResult = vadEngine.process(buffer: convertedBuffer)
                    lastVADProbability = vadResult.speechProbability

                    // Only forward speech frames to the ASR.
                    if vadResult.isSpeech {
                        recognitionRequest.append(convertedBuffer)
                    }

                    if vadResult.containsSpeechOffset {
                        scheduleVADSilenceCommit()
                    }
                    if vadResult.containsSpeechOnset {
                        cancelVADSilenceTimer()
                    }
                } else {
                    // Fallback: no VAD, pass everything through.
                    recognitionRequest.append(convertedBuffer)
                }
            }
        case .error:
            Task {
                await emitError("Audio conversion failed while feeding the speech recognizer.")
            }
        @unknown default:
            break
        }
    }

    // MARK: - Audio gain boost

    /// Amplifies a Float32 PCM buffer when the signal is too quiet for the ASR's VAD to
    /// detect reliably. Only applies when the peak is in the "quiet speech" range
    /// (0.002–0.30); leaves silence and normal-to-loud audio untouched.
    ///
    /// - Quiet speech range: peak 0.002 – 0.30 → boost toward target peak 0.35 (up to 4×)
    /// - Silence (< 0.002): no boost (would just amplify noise floor)
    /// - Normal/loud (≥ 0.30): no boost (already loud enough; avoid clipping)
    private func boostIfQuiet(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var peak: Float = 0
        for ch in 0..<channelCount {
            let ptr = channelData[ch]
            for i in 0..<frameCount {
                let abs = ptr[i] < 0 ? -ptr[i] : ptr[i]
                if abs > peak { peak = abs }
            }
        }

        let targetPeak: Float = 0.35
        guard peak > 0.002, peak < targetPeak else { return }

        let gain = min(targetPeak / peak, 4.0)
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
    private func emitPartialDraft(_ draft: DraftSegment?) {
        partialHandler?(draft)
    }

    @MainActor
    private func emitError(_ message: String) {
        errorHandler?(message)
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func processRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription
        let segments = transcription.segments
        let formattedText = transcription.formattedString as NSString

        // Always save the latest transcript so the silence timer can commit it
        latestSegments = segments
        latestFormattedText = formattedText

        if committedSegmentCount > segments.count {
            committedSegmentCount = 0
            resetDraftState()
        }

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

            let currentRange = combinedRange(for: segments, from: sentenceStartIndex, to: index)
            let currentTextLength = currentRange.length
            let currentSegmentCount = index - sentenceStartIndex + 1
            let sentenceStartTimestamp = segments[sentenceStartIndex].timestamp
            let sentenceEndTimestamp = segment.timestamp + segment.duration
            let currentSentenceDuration = max(sentenceEndTimestamp - sentenceStartTimestamp, 0)

            // Boundaries that fire mid-loop (require a gap to a *next* word, or explicit cues)
            let punctuationBoundary = segment.substring.containsSentenceTerminator
            // 0.65 s: above typical ASR timestamp-reporting noise and natural within-sentence
            // clause pauses (200–450 ms), below genuine mid-sentence breath pauses.
            let strongPauseBoundary = (nextPauseDuration ?? 0) >= 0.65
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

            let commitRange = commitEndIndex == index
                ? currentRange
                : combinedRange(for: segments, from: sentenceStartIndex, to: commitEndIndex)

            let sentenceText = formattedText.substring(with: commitRange)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if sentenceText.isEmpty == false {
                let recognizedSentence = RecognizedSentence(text: sentenceText)
                Task { await emitRecognizedSentence(recognizedSentence) }
            }

            sentenceStartIndex = commitEndIndex + 1
            committedSegmentCount = sentenceStartIndex
            resetDraftState()

            // If we consumed all remaining segments (tail absorption or final boundary),
            // stop iterating to avoid referencing segments beyond the committed range.
            if commitEndIndex >= segments.count - 1 { break }
        }

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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let task = recognizer.recognitionTask(with: request, resultHandler: makeRecognitionHandler())

        recognitionRequest = request
        recognitionTask = task
        // Reset the converter — new request may have a different nativeAudioFormat.
        audioConverter = nil
        audioConverterInputSignature = nil
        committedSegmentCount = 0
        latestSegments = []
        latestFormattedText = ""
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

    // MARK: - Silence-commit timer

    /// Time after the last ASR callback before we force-commit pending text.
    ///
    /// 420 ms was too short: SFSpeechRecognizer can take 400–600 ms between consecutive
    /// partial-result callbacks for the same utterance on a loaded device, causing the
    /// timer to fire between two ASR deliveries for the same sentence.
    ///
    /// 700 ms sits safely above:
    ///   • inter-result ASR delivery gaps (typically 100–500 ms during speech)
    ///   • natural within-sentence pauses in Mandarin/Japanese (200–450 ms)
    /// and below clear sentence-ending silences (≥ 600 ms for most speakers).
    ///
    /// Follow ≈ 700 ms · Balanced ≈ 750 ms · Reading ≈ 800 ms.
    private var silenceCommitDeadlineMs: Int {
        max(700, modeConfig.minSilenceCommitMs + 500)
    }

    private func scheduleSilenceCommit() {
        silenceCommitTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(silenceCommitDeadlineMs))
        timer.setEventHandler { [weak self] in
            self?.forceCommitOnSilence()
        }
        timer.resume()
        silenceCommitTimer = timer
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
        vadSilenceCommitTimer?.cancel()
        let deadline = modeConfig.minSilenceCommitMs
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(deadline))
        timer.setEventHandler { [weak self] in
            self?.forceCommitOnSilence()
        }
        timer.resume()
        vadSilenceCommitTimer = timer
    }

    private func cancelVADSilenceTimer() {
        vadSilenceCommitTimer?.cancel()
        vadSilenceCommitTimer = nil
    }

    /// Called by the silence timer when no new ASR result has arrived for
    /// silenceCommitDeadlineMs — meaning the user has paused.
    private func forceCommitOnSilence() {
        silenceCommitTimer = nil
        let segments = latestSegments
        let formattedText = latestFormattedText

        guard committedSegmentCount < segments.count else { return }

        let lastIdx = segments.count - 1
        let currentRange = combinedRange(for: segments, from: committedSegmentCount, to: lastIdx)
        let sentenceText = (formattedText.substring(with: currentRange) as String)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if sentenceText.isEmpty == false {
            let sentence = RecognizedSentence(text: sentenceText)
            Task { await emitRecognizedSentence(sentence) }
        }

        committedSegmentCount = segments.count
        resetDraftState()
        Task { await emitPartialDraft(nil) }
    }

    // MARK: - Draft helpers (called on captureQueue)

    private func resetDraftState() {
        currentDraftId = UUID()
        lastDraftText = ""
        lastDraftTextChangeTime = Date.distantPast
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

        // Track text changes for stability scoring
        if text != lastDraftText {
            lastDraftText = text
            lastDraftTextChangeTime = now
            draftChangeHistory.append((text: text, time: now))
        }
        draftChangeHistory.removeAll { now.timeIntervalSince($0.time) > 0.4 }

        let silenceMs = Int(now.timeIntervalSince(lastDraftTextChangeTime) * 1000)

        // Stability score: fewer changes in 400 ms → higher score
        let recentChanges = draftChangeHistory.count
        let stabilityScore: Float
        switch recentChanges {
        case 0, 1: stabilityScore = 1.0
        case 2:    stabilityScore = 0.7
        default:   stabilityScore = max(0.1, 0.5 - Float(recentChanges - 2) * 0.15)
        }

        // Boundary score: sentence-terminating punctuation scores highest
        let lastSeg = allSegments[lastIdx]
        let boundaryScore: Float = lastSeg.substring.containsSentenceTerminator ? 0.9 : 0.45

        // Length fit score
        let charCount = text.count
        let isCJK = text.containsCJKCharacters
        let lengthFitScore: Float
        if isCJK {
            switch charCount {
            case 12...20: lengthFitScore = 1.0
            case 5..<12:  lengthFitScore = Float(charCount) / 12.0 * 0.6
            case 21...30: lengthFitScore = 0.7
            default:      lengthFitScore = 0.3
            }
        } else {
            switch charCount {
            case 28...56: lengthFitScore = 1.0
            case 10..<28: lengthFitScore = Float(charCount) / 28.0 * 0.6
            case 57...84: lengthFitScore = 0.7
            default:      lengthFitScore = 0.3
            }
        }

        let draftSegs = Array(allSegments[draftRange])
        let avgConfidence = draftSegs.map(\.confidence).reduce(0, +) / Float(draftSegs.count)

        let chunkScore = ChunkScorer.score(
            silenceMs: silenceMs,
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
            return .failedToStartCapture("No output audio device is available for app capture.")
        case .tapFormatUnavailable:
            return .failedToStartCapture("The selected app's audio format could not be prepared for capture.")
        case .failed(let stage, let status):
            return .failedToStartCapture("Failed to \(stage): \(status.readableDescription)")
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
        queue: DispatchQueue,
        audioHandler: @escaping (AVAudioPCMBuffer) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        self.appName = appName
        self.processObjectIDs = processObjectIDs
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
            errorHandler("Failed to read the captured audio stream for \(appName).")
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
