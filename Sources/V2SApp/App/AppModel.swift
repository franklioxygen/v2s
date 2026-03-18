import Combine
import Foundation
import SwiftUI
import Translation

@MainActor
final class AppModel: ObservableObject {
    private let settingsStore: SettingsStore
    private let sourceCatalogService: SourceCatalogService
    private let translationService = LiveTranslationService()
    private let glossaryService = GlossaryService()
    private let entityCache = EntityCache()
    private let speedMonitor = SpeedMonitor()
    private var liveTranscriptionSession: LiveTranscriptionSession?
    private var captionDisplayTask: Task<Void, Never>?
    private var captionTranslationTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCaptions: [QueuedCaption] = []
    private var readyCaptionTranslations: [UUID: String] = [:]
    private var displayedCaption: QueuedCaption?
    private var activeInputLanguageID: String?
    private var isBootstrapping = true
    private var fadeTask: Task<Void, Never>?
    private var draftTranslationTask: Task<Void, Never>?
    private var lastDraftStablePrefix = ""
    private var displayedCaptionLastVisualUpdateAt = Date.distantPast
    private var displayedCaptionLastVisualUpdateWasLateTranslation = false
    // Revision tracking: captionID → (committedTranslation, committedAt, revisionCount)
    private var translationRevisions: [UUID: (text: String, committedAt: Date, count: Int)] = [:]

    @Published private(set) var applicationSources: [InputSource] = []
    @Published private(set) var microphoneSources: [InputSource] = []
    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var overlayState: OverlayPreviewState?
    @Published var isOverlayVisible = false

    @Published var selectedSourceID: String? {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
        }
    }

    @Published var inputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
        }
    }

    @Published var outputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            refreshCaptionTranslations()
        }
    }

    @Published var overlayStyle: OverlayStyle {
        didSet {
            persistSettings()
        }
    }

    @Published var subtitleMode: SubtitleMode {
        didSet {
            persistSettings()
        }
    }

    @Published var glossary: [String: String] {
        didSet {
            persistSettings()
        }
    }

    init(
        settingsStore: SettingsStore,
        sourceCatalogService: SourceCatalogService
    ) {
        self.settingsStore = settingsStore
        self.sourceCatalogService = sourceCatalogService

        let settings = settingsStore.load()
        self.selectedSourceID = settings.selectedSourceID
        self.inputLanguageID = settings.inputLanguageID
        self.outputLanguageID = settings.outputLanguageID
        self.overlayStyle = settings.overlayStyle
        self.subtitleMode = settings.subtitleMode
        self.glossary = settings.glossary

        isBootstrapping = false
        refreshSources()
    }

    convenience init() {
        self.init(
            settingsStore: SettingsStore(),
            sourceCatalogService: SourceCatalogService()
        )
    }

    var allSources: [InputSource] {
        applicationSources + microphoneSources
    }

    var selectedSource: InputSource? {
        allSources.first(where: { $0.id == selectedSourceID })
    }

    var sessionButtonTitle: String {
        sessionState == .running ? "Stop" : "Start"
    }

    var sessionBadgeText: String {
        sessionState.displayName
    }

    func refreshSources() {
        let snapshot = sourceCatalogService.loadSnapshot()
        applicationSources = snapshot.applications
        microphoneSources = snapshot.microphones

        if let selectedSourceID, allSources.contains(where: { $0.id == selectedSourceID }) == false {
            self.selectedSourceID = allSources.first?.id
        } else if selectedSourceID == nil {
            selectedSourceID = allSources.first?.id
        }

        if sessionState == .running {
            statusMessage = "Running on \(selectedSource?.name ?? "Selected Source")"
        } else {
            statusMessage = allSources.isEmpty ? "No input sources detected." : "Ready"
        }
    }

    func toggleSession() {
        if sessionState == .running {
            stopSession()
        } else {
            Task {
                await startSession()
            }
        }
    }

    func startSession() async {
        guard let selectedSource else {
            sessionState = .error
            statusMessage = "Choose an input source before starting."
            return
        }

        resetLiveTextPipeline()
        activeInputLanguageID = inputLanguageID
        isOverlayVisible = true
        overlayState = OverlayPreviewState(
            translatedText: "Listening…",
            sourceText: "Waiting for audio from \(selectedSource.name)…",
            sourceName: selectedSource.name
        )
        statusMessage = "Preparing \(selectedSource.name)…"

        let session = LiveTranscriptionSession()
        liveTranscriptionSession = session
        let config = ModeConfig.config(for: subtitleMode)
        let speechLocaleIdentifier = LanguageCatalog.speechLocaleIdentifier(for: inputLanguageID)
        let recognitionHints = recognitionContextualStrings()

        do {
            try await session.start(
                source: selectedSource,
                localeIdentifier: speechLocaleIdentifier,
                modeConfig: config,
                contextualStrings: recognitionHints,
                transcriptHandler: { [weak self] sentence in
                    self?.enqueueRecognizedSentence(sentence, sourceName: selectedSource.name)
                },
                partialHandler: { [weak self] draft in
                    self?.handlePartialDraft(draft)
                },
                errorHandler: { [weak self] message in
                    self?.sessionState = .error
                    self?.statusMessage = message
                    self?.overlayState = OverlayPreviewState(
                        translatedText: "Capture stopped",
                        sourceText: message,
                        sourceName: selectedSource.name
                    )
                }
            )

            sessionState = .running
            statusMessage = "Running on \(selectedSource.name)"
        } catch {
            resetLiveTextPipeline()
            liveTranscriptionSession = nil
            sessionState = .error
            statusMessage = error.localizedDescription
            overlayState = OverlayPreviewState(
                translatedText: "Unable to start",
                sourceText: error.localizedDescription,
                sourceName: selectedSource.name
            )
        }
    }

    func stopSession() {
        resetLiveTextPipeline()
        liveTranscriptionSession?.stop()
        liveTranscriptionSession = nil
        sessionState = .idle
        statusMessage = allSources.isEmpty ? "No input sources detected." : "Ready"
        isOverlayVisible = false
        overlayState = nil
    }

    func showOverlayPreview() {
        let source = selectedSource ?? InputSource.preview
        overlayState = makePreviewState(for: source)
        isOverlayVisible = true

        if sessionState != .running {
            statusMessage = "Showing overlay preview."
        }
    }

    func toggleOverlayVisibility() {
        if isOverlayVisible {
            isOverlayVisible = false
            if sessionState != .running {
                overlayState = nil
            }
        } else {
            showOverlayPreview()
        }
    }

    func updateOverlayStyle(_ update: (inout OverlayStyle) -> Void) {
        var style = overlayStyle
        update(&style)
        overlayStyle = style
    }

    func persistSettings() {
        guard isBootstrapping == false else {
            return
        }

        let settings = AppSettings(
            selectedSourceID: selectedSourceID,
            inputLanguageID: inputLanguageID,
            outputLanguageID: outputLanguageID,
            overlayStyle: overlayStyle,
            subtitleMode: subtitleMode,
            glossary: glossary
        )

        settingsStore.save(settings)
    }

    private func recognitionContextualStrings() -> [String] {
        glossary.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
                return lhs.count < rhs.count
            }
    }

    func languageName(for identifier: String) -> String {
        LanguageCatalog.displayName(for: identifier)
    }

    // MARK: - Draft handler

    private func handlePartialDraft(_ draft: DraftSegment?) {
        guard liveTranscriptionSession != nil else { return }
        overlayState?.draftSourceText = draft?.sourceText
        overlayState?.draftStablePrefixLength = draft?.stablePrefixLength ?? 0

        let stablePrefix: String
        if let draft, draft.stablePrefixLength > 0 {
            stablePrefix = String(draft.sourceText.prefix(draft.stablePrefixLength))
        } else {
            stablePrefix = ""
        }

        guard stablePrefix != lastDraftStablePrefix else { return }
        lastDraftStablePrefix = stablePrefix

        if stablePrefix.isEmpty {
            draftTranslationTask?.cancel()
            draftTranslationTask = nil
            overlayState?.draftTranslatedText = nil
        } else {
            scheduleDraftTranslation(for: stablePrefix)
        }
    }

    private func scheduleDraftTranslation(for text: String) {
        draftTranslationTask?.cancel()
        draftTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 150 ms debounce — coalesces rapid stable-prefix growth bursts
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard !Task.isCancelled, liveTranscriptionSession != nil else { return }

            let sourceID = currentSourceLanguageID
            let targetID = outputLanguageID
            guard sourceID != targetID else { return }

            let translated = await withTaskGroup(of: String?.self, returning: String?.self) { group in
                group.addTask { [translationService = self.translationService] in
                    try? await translationService.translate(text, from: sourceID, to: targetID)
                }
                // 1 s hard timeout so draft translation never blocks the UI
                group.addTask {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }

            guard !Task.isCancelled, liveTranscriptionSession != nil else { return }
            if let translated {
                overlayState?.draftTranslatedText = glossaryService.apply(to: translated, glossary: glossary)
            }
        }
    }

    // MARK: - Previous caption fade

    /// Fades out the currently displayed caption and clears the overlay text.
    /// Called when the display hold time expires and no new caption is queued.
    private func clearOverlayText() {
        guard let current = overlayState,
              !current.translatedText.isEmpty else { return }
        beginFadeOutPreviousCaption(
            translatedText: current.translatedText,
            sourceText: current.sourceText
        )
        overlayState?.translatedText = ""
        overlayState?.sourceText = ""
        overlayState?.draftSourceText = nil
        overlayState?.draftTranslatedText = nil
        displayedCaption = nil
        displayedCaptionLastVisualUpdateAt = Date.distantPast
        displayedCaptionLastVisualUpdateWasLateTranslation = false
    }

    /// Snapshots the currently committed caption into the previous layer at full opacity.
    /// The previous layer stays visible until `startPreviousCaptionFade()` is called.
    private func capturePreviousCaption() {
        guard let current = overlayState,
              displayedCaption != nil,
              !current.translatedText.isEmpty,
              current.translatedText != "Listening…",
              current.translatedText != "Capture stopped",
              current.translatedText != "Unable to start" else { return }

        if inputLanguageID != outputLanguageID,
           current.translatedText == current.sourceText {
            return
        }

        if displayedCaptionLastVisualUpdateWasLateTranslation,
           Date().timeIntervalSince(displayedCaptionLastVisualUpdateAt) < 0.8 {
            return
        }

        fadeTask?.cancel()
        fadeTask = nil
        overlayState?.previousTranslatedText = current.translatedText
        overlayState?.previousSourceText = current.sourceText
        overlayState?.previousFadeProgress = 0.0   // fully visible — no animation yet
    }

    private func updateCommittedOverlay(
        translatedText: String,
        sourceText: String,
        bumpEpoch: Bool = false,
        lateTranslation: Bool = false
    ) {
        if bumpEpoch {
            overlayState?.captionEpoch = (overlayState?.captionEpoch ?? 0) + 1
        }

        overlayState?.translatedText = translatedText
        overlayState?.sourceText = sourceText
        displayedCaptionLastVisualUpdateAt = Date()
        displayedCaptionLastVisualUpdateWasLateTranslation = lateTranslation
    }

    /// Triggers the scroll-up + fade animation on the previous caption layer.
    /// Call this after the new translation is committed so the previous caption
    /// stays on screen until meaningful content replaces it.
    private func startPreviousCaptionFade() {
        guard overlayState?.previousTranslatedText != nil else { return }
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 16_666_667)    // one render frame
            guard !Task.isCancelled else { return }
            overlayState?.previousFadeProgress = 1.0           // triggers scroll-up animation
            try? await Task.sleep(nanoseconds: 600_000_000)    // wait for 0.5 s animation
            guard !Task.isCancelled else { return }
            overlayState?.previousTranslatedText = nil
            overlayState?.previousSourceText = nil
        }
    }

    /// Fades out a caption immediately (used when the queue empties — no new caption coming).
    private func beginFadeOutPreviousCaption(translatedText: String, sourceText: String) {
        guard !translatedText.isEmpty,
              translatedText != "Listening…",
              translatedText != "Capture stopped",
              translatedText != "Unable to start" else { return }

        overlayState?.previousTranslatedText = translatedText
        overlayState?.previousSourceText = sourceText
        overlayState?.previousFadeProgress = 0.0

        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 16_666_667)
            guard !Task.isCancelled else { return }
            overlayState?.previousFadeProgress = 1.0
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            overlayState?.previousTranslatedText = nil
            overlayState?.previousSourceText = nil
        }
    }

    // MARK: - Settings sync

    private func syncOverlayPreviewIfNeeded() {
        guard liveTranscriptionSession == nil else {
            return
        }

        guard isOverlayVisible || sessionState == .running else {
            return
        }

        let source = selectedSource ?? InputSource.preview
        overlayState = makePreviewState(for: source)
    }

    private func makePreviewState(for source: InputSource) -> OverlayPreviewState {
        let sourceText = sampleText(for: inputLanguageID)
        let translatedText: String

        if inputLanguageID == outputLanguageID {
            translatedText = sourceText
        } else {
            translatedText = sampleText(for: outputLanguageID)
        }

        return OverlayPreviewState(
            translatedText: translatedText,
            sourceText: sourceText,
            sourceName: source.name
        )
    }

    // MARK: - Caption queue

    private func enqueueRecognizedSentence(_ sentence: RecognizedSentence, sourceName: String) {
        let sourceText = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceText.isEmpty == false else {
            return
        }

        let caption = QueuedCaption(
            id: UUID(),
            sourceText: sourceText,
            sourceName: sourceName
        )

        pendingCaptions.append(caption)
        translateCaption(caption)

        // Cap the queue at 2 items: whatever is currently being displayed (index 0)
        // plus the newest arrival (just appended). Drop anything in between so the
        // display never falls behind by more than one sentence.
        while pendingCaptions.count > 2 {
            let dropped = pendingCaptions.remove(at: 1)
            captionTranslationTasks[dropped.id]?.cancel()
            captionTranslationTasks.removeValue(forKey: dropped.id)
            readyCaptionTranslations.removeValue(forKey: dropped.id)
        }

        processCaptionQueueIfNeeded()

        // Record speech rate for speed-protection monitor
        let nowMs = Int(Date().timeIntervalSinceReferenceDate * 1000)
        Task { await speedMonitor.record(chars: sourceText.count, nowMs: nowMs) }

        if sessionState != .running {
            sessionState = .running
        }

        statusMessage = "Running on \(sourceName)"
    }

    private func refreshCaptionTranslations() {
        guard liveTranscriptionSession != nil else {
            return
        }

        cancelCaptionTranslations()
        readyCaptionTranslations.removeAll()

        for caption in pendingCaptions {
            translateCaption(caption)
        }

        if let displayedCaption {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let translatedText = await translatedText(for: displayedCaption)
                guard liveTranscriptionSession != nil,
                      self.displayedCaption?.id == displayedCaption.id else {
                    return
                }

                updateCommittedOverlay(
                    translatedText: translatedText,
                    sourceText: displayedCaption.sourceText,
                    lateTranslation: translatedText != displayedCaption.sourceText
                )
            }
        }
    }

    private var currentSourceLanguageID: String {
        activeInputLanguageID ?? inputLanguageID
    }

    private func resetLiveTextPipeline() {
        fadeTask?.cancel()
        fadeTask = nil
        captionDisplayTask?.cancel()
        captionDisplayTask = nil
        draftTranslationTask?.cancel()
        draftTranslationTask = nil
        lastDraftStablePrefix = ""
        cancelCaptionTranslations()
        pendingCaptions.removeAll()
        readyCaptionTranslations.removeAll()
        translationRevisions.removeAll()
        displayedCaption = nil
        activeInputLanguageID = nil
        displayedCaptionLastVisualUpdateAt = Date.distantPast
        displayedCaptionLastVisualUpdateWasLateTranslation = false

        Task {
            await translationService.reset()
            await entityCache.reset()
            await speedMonitor.reset()
        }
    }

    private func processCaptionQueueIfNeeded() {
        guard captionDisplayTask == nil else {
            return
        }

        captionDisplayTask = Task { @MainActor [weak self] in
            await self?.processCaptionQueue()
        }
    }

    private func processCaptionQueue() async {
        // Guaranteed to run even if we break or the task is cancelled.
        defer { captionDisplayTask = nil }

        while Task.isCancelled == false {
            guard liveTranscriptionSession != nil else { break }
            guard let caption = pendingCaptions.first else {
                // Queue is empty — fade out the last caption instead of leaving it on screen.
                clearOverlayText()
                break
            }

            // Caption cleanup runs on every exit from this iteration: normal
            // completion, break, or sleep cancellation. This prevents captions from
            // getting stuck in pendingCaptions and replaying on the next queue start.
            defer {
                pendingCaptions.removeAll(where: { $0.id == caption.id })
                readyCaptionTranslations.removeValue(forKey: caption.id)
            }

            // Snapshot the current caption into the previous layer at full opacity.
            // It stays visible until the new translation arrives — then we scroll it away.
            capturePreviousCaption()

            // Source-first: show source text immediately while translation is pending
            displayedCaption = caption
            updateCommittedOverlay(
                translatedText: caption.sourceText,
                sourceText: caption.sourceText,
                bumpEpoch: true
            )
            overlayState?.sourceName = caption.sourceName
            overlayState?.draftSourceText = nil
            overlayState?.draftTranslatedText = nil

            // Wait up to 1.5 s for translation; fall back to source text
            let finalText = await waitForTranslatedCaption(id: caption.id, timeout: 1.5)
                ?? caption.sourceText

            guard liveTranscriptionSession != nil else { break }

            updateCommittedOverlay(
                translatedText: finalText,
                sourceText: caption.sourceText,
                lateTranslation: finalText != caption.sourceText
            )
            translationRevisions[caption.id] = (text: finalText, committedAt: Date(), count: 0)

            // New translation is now visible — scroll the previous caption upward
            startPreviousCaptionFade()

            let holdDuration = computeDisplayDuration(
                sourceText: caption.sourceText,
                translatedText: finalText
            )

            do {
                try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            } catch {
                break
            }
            // defer runs here: removes caption from pendingCaptions + readyCaptionTranslations
        }
        // defer runs here: captionDisplayTask = nil
    }

    private func waitForTranslatedCaption(id: UUID, timeout: Double = 1.5) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)

        while Task.isCancelled == false {
            if let translatedText = readyCaptionTranslations[id] {
                return translatedText
            }

            if liveTranscriptionSession == nil {
                return nil
            }

            if Date() >= deadline {
                return nil
            }

            do {
                try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            } catch {
                return nil
            }
        }

        return nil
    }

    private func translateCaption(_ caption: QueuedCaption) {
        captionTranslationTasks[caption.id]?.cancel()

        captionTranslationTasks[caption.id] = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let translatedText = await translatedText(for: caption)
            guard Task.isCancelled == false,
                  liveTranscriptionSession != nil else {
                return
            }

            readyCaptionTranslations[caption.id] = translatedText
            captionTranslationTasks[caption.id] = nil
        }
    }

    private func translatedText(for caption: QueuedCaption) async -> String {
        let sourceLanguageID = currentSourceLanguageID
        let targetLanguageID = outputLanguageID

        guard sourceLanguageID != targetLanguageID else {
            return caption.sourceText
        }

        let raw = await withTaskGroup(of: String.self, returning: String.self) { group in
            group.addTask { [translationService] in
                do {
                    return try await translationService.translate(
                        caption.sourceText,
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )
                } catch {
                    return caption.sourceText
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return caption.sourceText
            }

            let resolvedText = await group.next() ?? caption.sourceText
            group.cancelAll()
            return resolvedText
        }

        // Apply user glossary on top of raw translation
        let currentGlossary = glossary
        return glossaryService.apply(to: raw, glossary: currentGlossary)
    }

    /// Checks whether a candidate revised translation is a "light edit" (Levenshtein ratio ≤ 0.18)
    /// and applies it to the displayed overlay within the allowed 1-revision window.
    private func maybeApplyRevision(captionId: UUID, revised: String) {
        guard var entry = translationRevisions[captionId],
              entry.count < 1,
              Date().timeIntervalSince(entry.committedAt) < 1.0 else { return }

        let ratio = levenshteinDistanceRatio(entry.text, revised)
        guard ratio <= 0.18 else { return }

        entry.text = revised
        entry.count += 1
        translationRevisions[captionId] = entry

        if displayedCaption?.id == captionId {
            updateCommittedOverlay(
                translatedText: revised,
                sourceText: displayedCaption?.sourceText ?? revised,
                lateTranslation: true
            )
        }
    }

    private func levenshteinDistanceRatio(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 0.0 }
        return Double(levenshteinDistance(Array(a), Array(b))) / Double(maxLen)
    }

    private func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count, n = b.count
        var dp = Array(0...n)
        for i in 1...max(m, 1) {
            guard i <= m else { break }
            var prev = dp[0]
            dp[0] = i
            for j in 1...max(n, 1) {
                guard j <= n else { break }
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : 1 + min(prev, dp[j], dp[j-1])
                prev = temp
            }
        }
        return dp[n]
    }

    private func cancelCaptionTranslations() {
        for task in captionTranslationTasks.values {
            task.cancel()
        }

        captionTranslationTasks.removeAll()
    }

    // MARK: - Display duration (strategy §10)

    /// max(min_hold, reading_time, audio_span × sync_factor), clamped to [1.2, 4.5] s
    private func computeDisplayDuration(sourceText: String, translatedText: String) -> Double {
        let displayText = translatedText.isEmpty ? sourceText : translatedText
        let charCount = Double(displayText.count)
        let isCJK = displayText.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
                || (0x3040...0x30FF).contains($0.value)
                || (0xAC00...0xD7AF).contains($0.value)
        }

        let cps: Double = isCJK ? 7.0 : 13.5
        var readingTime = charCount / cps

        // Bilingual factor: both source and translation shown simultaneously
        if inputLanguageID != outputLanguageID {
            readingTime *= 1.15
        }

        // Min hold based on length tier
        let minHold: Double
        switch charCount {
        case ..<10:   minHold = 1.2
        case 10..<21: minHold = 1.6
        default:      minHold = 2.0
        }

        return min(max(minHold, readingTime), 4.5)
    }

    private func sampleText(for languageID: String) -> String {
        switch languageID {
        case "zh-Hans":
            return "欢迎使用 v2s，顶部字幕条已经准备好了。"
        case "ja":
            return "v2s へようこそ。字幕バーの準備ができました。"
        case "ko":
            return "v2s에 오신 것을 환영합니다. 자막 바가 준비되었습니다."
        case "fr":
            return "Bienvenue dans v2s. La barre de sous-titres est prete."
        case "de":
            return "Willkommen bei v2s. Die Untertitel-Leiste ist bereit."
        default:
            return "Welcome to v2s. The subtitle bar is ready."
        }
    }

}

private struct QueuedCaption: Identifiable, Equatable {
    let id: UUID
    let sourceText: String
    let sourceName: String
}

private actor LiveTranslationService {
    private struct LanguagePair: Equatable {
        let source: String
        let target: String
    }

    enum ServiceError: LocalizedError {
        case unavailableOnSystem
        case unsupportedPair(String, String)

        var errorDescription: String? {
            switch self {
            case .unavailableOnSystem:
                return "Translation requires macOS 26 or newer."
            case .unsupportedPair(let source, let target):
                return "Translation is not supported from \(source) to \(target)."
            }
        }
    }

    private var preparedPair: LanguagePair?
    private var sessionStorage: AnyObject?

    func translate(_ text: String, from sourceIdentifier: String, to targetIdentifier: String) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return ""
        }

        guard sourceIdentifier != targetIdentifier else {
            return trimmedText
        }

        guard #available(macOS 26.0, *) else {
            throw ServiceError.unavailableOnSystem
        }

        let sourceLanguage = Locale.Language(identifier: sourceIdentifier)
        let targetLanguage = Locale.Language(identifier: targetIdentifier)
        let availability = LanguageAvailability()
        let availabilityStatus = await availability.status(from: sourceLanguage, to: targetLanguage)

        guard availabilityStatus != .unsupported else {
            throw ServiceError.unsupportedPair(sourceIdentifier, targetIdentifier)
        }

        let requestedPair = LanguagePair(source: sourceIdentifier, target: targetIdentifier)
        let session: TranslationSession

        if let cachedSession = sessionStorage as? TranslationSession,
           preparedPair == requestedPair {
            session = cachedSession
        } else {
            let newSession = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            try await newSession.prepareTranslation()
            sessionStorage = newSession
            preparedPair = requestedPair
            session = newSession
        }

        let response = try await session.translate(trimmedText)
        let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        return translatedText.isEmpty ? trimmedText : translatedText
    }

    func reset() {
        if #available(macOS 26.0, *) {
            (sessionStorage as? TranslationSession)?.cancel()
        }

        sessionStorage = nil
        preparedPair = nil
    }
}
