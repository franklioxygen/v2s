import Combine
import Foundation
import AppKit
import Speech
import SwiftUI
import Translation

@MainActor
final class AppModel: ObservableObject {
    private let settingsStore: SettingsStore
    private let sourceCatalogService: SourceCatalogService
    private let translationCoordinator = TranslationCoordinator()
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
    private var usesSystemInterfaceLanguage = true
    private var draftTranslationTask: Task<Void, Never>?
    private var draftClearTask: Task<Void, Never>?
    private var committedCaptionArchiveTask: Task<Void, Never>?
    private var languageResourcePreparationTask: Task<Void, Never>?
    private var lastDraftStablePrefix = ""
    private var lastDraftTranslationSource = ""
    private var draftTranslationGeneration: Int = 0
    private var draftClearGeneration: Int = 0
    private var displayedCaptionLastVisualUpdateAt = Date.distantPast
    private var displayedCaptionLastVisualUpdateWasLateTranslation = false
    // Revision tracking: captionID → (committedTranslation, committedAt, revisionCount)
    private var translationRevisions: [UUID: (text: String, committedAt: Date, count: Int)] = [:]
    private var recentRecognizedCaptionTexts: [(text: String, time: Date)] = []
    private var finalizedDraftPromotionIDs: [(id: UUID, time: Date)] = []
    private var statusDescriptor: StatusDescriptor = .ready
    @Published private(set) var applicationSources: [InputSource] = []
    @Published private(set) var microphoneSources: [InputSource] = []
    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var overlayState: OverlayPreviewState?
    @Published private(set) var languageResourceStatuses: [LanguageResourceStatus] = []
    @Published private(set) var translationHostConfiguration: TranslationSession.Configuration?
    @Published var isOverlayVisible = false
    @Published private(set) var overlayHistoryVisibleCount = 0
    @Published private(set) var overlayHistoryScrollOffset = 0

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
            scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: true)
        }
    }

    @Published var outputLanguageID: String {
        didSet {
            persistSettings()
            syncOverlayPreviewIfNeeded()
            scheduleSelectedLanguageResourcePreparation(
                refreshTranslations: liveTranscriptionSession != nil,
                openSystemSettingsIfNeeded: true
            )
        }
    }

    @Published var interfaceLanguageID: String {
        didSet {
            guard oldValue != interfaceLanguageID else { return }
            usesSystemInterfaceLanguage = false
            persistSettings()
            relocalizeInterface(from: oldValue)
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
        self.usesSystemInterfaceLanguage = settings.interfaceLanguageID == nil
        self.interfaceLanguageID = LanguageCatalog.preferredInterfaceLanguageID(
            storedIdentifier: settings.interfaceLanguageID
        )
        let normalizedOverlayStyle = AppModel.normalizedOverlayStyle(settings.overlayStyle)
        self.overlayStyle = normalizedOverlayStyle
        self.subtitleMode = settings.subtitleMode
        self.glossary = settings.glossary
        self.translationHostConfiguration = nil

        translationCoordinator.onConfigurationChange = { [weak self] configuration in
            self?.translationHostConfiguration = configuration
        }

        isBootstrapping = false
        applyStatusMessage()
        if normalizedOverlayStyle != settings.overlayStyle {
            persistSettings()
        }
        refreshSources()
        scheduleSelectedLanguageResourcePreparation()
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
        if sessionState == .running {
            return localized(.stop)
        }

        if isPreparingSelectedLanguageResources {
            return localized(.wait)
        }

        if hasBlockingLanguageResourceStatuses {
            return localized(.pleaseDownloadLanguageResource)
        }

        return localized(.start)
    }

    var showsSessionWaitIndicator: Bool {
        sessionState != .running && isPreparingSelectedLanguageResources
    }

    var isSessionButtonDisabled: Bool {
        if sessionState == .running {
            return false
        }

        return selectedSource == nil
            || isPreparingSelectedLanguageResources
            || hasBlockingLanguageResourceStatuses
    }

    var sessionBadgeText: String {
        sessionState.displayName(in: resolvedInterfaceLanguageID)
    }

    var resolvedInterfaceLanguageID: String {
        LanguageCatalog.preferredInterfaceLanguageID(storedIdentifier: interfaceLanguageID)
    }

    var interfaceLocale: Locale {
        AppLocalization.locale(for: resolvedInterfaceLanguageID)
    }

    func localized(_ key: AppTextKey, _ arguments: CVarArg...) -> String {
        AppLocalization.formattedString(key, languageID: resolvedInterfaceLanguageID, arguments: arguments)
    }

    private var listeningPlaceholderText: String {
        localized(.listening)
    }

    private var captureStoppedText: String {
        localized(.captureStopped)
    }

    private var unableToStartText: String {
        localized(.unableToStart)
    }

    private var previewInputSource: InputSource {
        InputSource(
            id: InputSource.preview.id,
            name: localized(.previewSource),
            detail: InputSource.preview.detail,
            category: InputSource.preview.category
        )
    }

    private func localizedErrorDescription(_ error: Error) -> String {
        AppLocalization.localizedErrorDescription(error, languageID: resolvedInterfaceLanguageID)
    }

    private func setStatus(_ descriptor: StatusDescriptor) {
        statusDescriptor = descriptor
        applyStatusMessage()
    }

    private func applyStatusMessage() {
        switch statusDescriptor {
        case .ready:
            statusMessage = localized(.ready)
        case .noInputSourcesDetected:
            statusMessage = localized(.noSourcesDetected) + "."
        case .running(let sourceName):
            statusMessage = localized(.runningOnFormat, sourceName)
        case .chooseInputSourceBeforeStarting:
            statusMessage = localized(.chooseInputSourceBeforeStarting)
        case .checkingLanguageResources:
            statusMessage = localized(.checkingLanguageResources)
        case .downloadLanguageResourcesInSystemSettings:
            statusMessage = localized(.downloadRequiredLanguageResourcesSystemSettings)
        case .preparing(let sourceName):
            statusMessage = localized(.preparingSourceFormat, sourceName)
        case .showingOverlayPreview:
            statusMessage = localized(.showingOverlayPreview)
        case .custom(let message):
            statusMessage = message
        }
    }

    private func relocalizeInterface(from oldLanguageID: String) {
        applyStatusMessage()
        relocalizeOverlaySentinelTexts(from: oldLanguageID)

        if liveTranscriptionSession == nil,
           sessionState != .error,
           isOverlayVisible {
            syncOverlayPreviewIfNeeded()
        }

        if languageResourcePreparationTask == nil, languageResourceStatuses.isEmpty == false {
            scheduleSelectedLanguageResourcePreparation(openSystemSettingsIfNeeded: false)
        }
    }

    private func relocalizeOverlaySentinelTexts(from oldLanguageID: String) {
        guard var overlayState else { return }

        let oldListening = AppLocalization.string(.listening, languageID: oldLanguageID)
        let oldCaptureStopped = AppLocalization.string(.captureStopped, languageID: oldLanguageID)
        let oldUnableToStart = AppLocalization.string(.unableToStart, languageID: oldLanguageID)

        if overlayState.translatedText == oldListening {
            overlayState.translatedText = listeningPlaceholderText
        } else if overlayState.translatedText == oldCaptureStopped {
            overlayState.translatedText = captureStoppedText
        } else if overlayState.translatedText == oldUnableToStart {
            overlayState.translatedText = unableToStartText
        }

        self.overlayState = overlayState
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
            setStatus(.running(sourceName: selectedSource?.name ?? localized(.selectedSource)))
        } else {
            setStatus(allSources.isEmpty ? .noInputSourcesDetected : .ready)
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
            setStatus(.chooseInputSourceBeforeStarting)
            return
        }

        resetLiveTextPipeline()
        setStatus(.checkingLanguageResources)
        await awaitSelectedLanguageResourcePreparationIfNeeded()
        guard hasBlockingLanguageResourceStatuses == false else {
            setStatus(.downloadLanguageResourcesInSystemSettings)
            return
        }

        activeInputLanguageID = inputLanguageID
        isOverlayVisible = true
        overlayState = OverlayPreviewState(
            translatedText: listeningPlaceholderText,
            sourceText: localized(.waitingForAudioFromFormat, selectedSource.name),
            sourceName: selectedSource.name
        )
        overlayHistoryScrollOffset = 0
        setStatus(.preparing(sourceName: selectedSource.name))

        let session = LiveTranscriptionSession()
        liveTranscriptionSession = session
        let config = ModeConfig.config(for: subtitleMode)
        let speechLocaleIdentifier = LanguageCatalog.speechLocaleIdentifier(for: inputLanguageID)
        let recognitionHints = recognitionContextualStrings()

        do {
            try await session.start(
                source: selectedSource,
                localeIdentifier: speechLocaleIdentifier,
                interfaceLanguageID: resolvedInterfaceLanguageID,
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
                    self?.setStatus(.custom(message))
                    self?.overlayState = OverlayPreviewState(
                        translatedText: self?.captureStoppedText ?? "",
                        sourceText: message,
                        sourceName: selectedSource.name
                    )
                }
            )

            sessionState = .running
            setStatus(.running(sourceName: selectedSource.name))
        } catch {
            resetLiveTextPipeline()
            liveTranscriptionSession = nil
            sessionState = .error
            let localizedError = localizedErrorDescription(error)
            setStatus(.custom(localizedError))
            overlayState = OverlayPreviewState(
                translatedText: unableToStartText,
                sourceText: localizedError,
                sourceName: selectedSource.name
            )
            overlayHistoryScrollOffset = 0
        }
    }

    func stopSession() {
        resetLiveTextPipeline()
        liveTranscriptionSession?.stop()
        liveTranscriptionSession = nil
        sessionState = .idle
        setStatus(allSources.isEmpty ? .noInputSourcesDetected : .ready)
        isOverlayVisible = false
        overlayState = nil
    }

    func showOverlayPreview() {
        let source = selectedSource ?? previewInputSource
        overlayState = makePreviewState(for: source)
        overlayHistoryScrollOffset = 0
        isOverlayVisible = true

        if sessionState != .running {
            setStatus(.showingOverlayPreview)
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
        overlayStyle = AppModel.normalizedOverlayStyle(style)
    }

    func updateOverlayHistoryVisibleCount(_ count: Int) {
        let clampedCount = max(0, count)
        guard overlayHistoryVisibleCount != clampedCount else { return }
        overlayHistoryVisibleCount = clampedCount
        clampOverlayHistoryScrollOffset()
    }

    func scrollOverlayHistory(by delta: Int) {
        guard delta != 0 else { return }
        setOverlayHistoryScrollOffset(overlayHistoryScrollOffset + delta)
    }

    func setOverlayHistoryScrollOffset(_ offset: Int) {
        let clampedOffset = min(max(offset, 0), overlayHistoryMaxScrollOffset)
        guard overlayHistoryScrollOffset != clampedOffset else { return }
        overlayHistoryScrollOffset = clampedOffset
    }

    func persistSettings() {
        guard isBootstrapping == false else {
            return
        }

        let settings = AppSettings(
            selectedSourceID: selectedSourceID,
            inputLanguageID: inputLanguageID,
            outputLanguageID: outputLanguageID,
            interfaceLanguageID: usesSystemInterfaceLanguage ? nil : interfaceLanguageID,
            overlayStyle: overlayStyle,
            subtitleMode: subtitleMode,
            glossary: glossary
        )

        settingsStore.save(settings)
    }

    private static func normalizedOverlayStyle(_ style: OverlayStyle) -> OverlayStyle {
        var normalized = style
        normalized.translatedFirst = true
        return normalized
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
        LanguageCatalog.displayName(for: identifier, in: resolvedInterfaceLanguageID)
    }

    @available(macOS 15.0, *)
    func runTranslationHost(using session: TranslationSession) async {
        await translationCoordinator.run(using: session)
    }

    func refreshLanguageResources() {
        scheduleSelectedLanguageResourcePreparation()
    }

    private func scheduleSelectedLanguageResourcePreparation(
        refreshTranslations: Bool = false,
        openSystemSettingsIfNeeded: Bool = false
    ) {
        guard isBootstrapping == false else {
            return
        }

        let inputLanguageID = self.inputLanguageID
        let outputLanguageID = self.outputLanguageID

        languageResourcePreparationTask?.cancel()
        languageResourceStatuses = []

        languageResourcePreparationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer { self.languageResourcePreparationTask = nil }

            await self.prepareSelectedLanguageResources(
                inputLanguageID: inputLanguageID,
                outputLanguageID: outputLanguageID,
                openSystemSettingsIfNeeded: openSystemSettingsIfNeeded
            )

            guard Task.isCancelled == false,
                  refreshTranslations,
                  self.hasBlockingLanguageResourceStatuses == false else {
                return
            }

            self.refreshCaptionTranslations()
        }
    }

    private func awaitSelectedLanguageResourcePreparationIfNeeded() async {
        if languageResourcePreparationTask == nil {
            scheduleSelectedLanguageResourcePreparation()
        }

        await languageResourcePreparationTask?.value
    }

    private var isPreparingSelectedLanguageResources: Bool {
        languageResourcePreparationTask != nil
            || languageResourceStatuses.contains(where: { $0.isError == false })
    }

    private var hasBlockingLanguageResourceStatuses: Bool {
        languageResourceStatuses.contains(where: \.isError)
    }

    private func prepareSelectedLanguageResources(
        inputLanguageID: String,
        outputLanguageID: String,
        openSystemSettingsIfNeeded: Bool
    ) async {
        var destinationsToOpen = Set<LanguageResourceSystemSettingsDestination>()
        await withTaskGroup(of: LanguageResourceSystemSettingsDestination?.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    return nil
                }

                return await self.prepareSpeechRecognitionResourceIfNeeded(for: inputLanguageID)
            }

            if inputLanguageID != outputLanguageID {
                group.addTask { [weak self] in
                    guard let self else {
                        return nil
                    }

                    return await self.prepareTranslationResourceIfNeeded(
                        from: inputLanguageID,
                        to: outputLanguageID
                    )
                }
            }

            for await destination in group {
                if let destination {
                    destinationsToOpen.insert(destination)
                }
            }
        }

        guard openSystemSettingsIfNeeded else {
            return
        }

        if destinationsToOpen.contains(.translationLanguages) {
            openSystemSettings(for: .translationLanguages)
        } else if let destination = destinationsToOpen.first {
            openSystemSettings(for: destination)
        }
    }

    private func prepareSpeechRecognitionResourceIfNeeded(
        for languageID: String
    ) async -> LanguageResourceSystemSettingsDestination? {
        guard #available(macOS 26.0, *) else {
            return nil
        }

        let title = localized(.speechTitleFormat, languageName(for: languageID))
        let statusID = "speech:\(languageID)"
        let requestedLocale = Locale(identifier: LanguageCatalog.speechLocaleIdentifier(for: languageID))

        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            upsertLanguageResourceStatus(
                LanguageResourceStatus(
                    id: statusID,
                    kind: .speech,
                    title: title,
                    detail: localized(.speechNotAvailableOnMacOS),
                    progress: nil,
                    isError: true
                )
            )
            return nil
        }

        let transcriber = makeSpeechTranscriber(locale: resolvedLocale)

        do {
            try await ensureSpeechAssetsReady(
                for: [transcriber],
                statusID: statusID,
                title: title
            )
            removeLanguageResourceStatus(id: statusID)
        } catch is CancellationError {
            removeLanguageResourceStatus(id: statusID)
        } catch {
            upsertLanguageResourceStatus(
                LanguageResourceStatus(
                    id: statusID,
                    kind: .speech,
                    title: title,
                    detail: localizedErrorDescription(error),
                    progress: nil,
                    isError: true
                )
            )
        }

        return nil
    }

    @available(macOS 26.0, *)
    private func ensureSpeechAssetsReady(
        for modules: [any SpeechModule],
        statusID: String,
        title: String
    ) async throws {
        let detail = localized(.downloadingSpeechResources)
        let maxPollingRetries = 150 // ~30 seconds at 200ms intervals
        var pollingRetryCount = 0

        while true {
            try Task.checkCancellation()

            switch await AssetInventory.status(forModules: modules) {
            case .installed:
                return
            case .unsupported:
                throw LanguageResourcePreparationError.unsupportedSpeechLanguage
            case .supported:
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await installSpeechAssets(
                        request,
                        statusID: statusID,
                        title: title,
                        detail: detail
                    )
                    return
                }

                pollingRetryCount += 1
                if pollingRetryCount > maxPollingRetries {
                    throw LanguageResourcePreparationError.speechDownloadTimedOut
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            case .downloading:
                // Reset polling count — an active download is making progress
                pollingRetryCount = 0

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            @unknown default:
                pollingRetryCount += 1
                if pollingRetryCount > maxPollingRetries {
                    throw LanguageResourcePreparationError.speechDownloadTimedOut
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: nil,
                        isError: false
                    )
                )
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    @available(macOS 26.0, *)
    private func installSpeechAssets(
        _ request: AssetInstallationRequest,
        statusID: String,
        title: String,
        detail: String
    ) async throws {
        let progressTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while Task.isCancelled == false {
                let progress = normalizedProgressValue(request.progress.fractionCompleted)
                self.upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .speech,
                        title: title,
                        detail: detail,
                        progress: progress,
                        isError: false
                    )
                )

                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                } catch {
                    return
                }
            }
        }

        defer { progressTask.cancel() }

        try await request.downloadAndInstall()
    }

    private func prepareTranslationResourceIfNeeded(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async -> LanguageResourceSystemSettingsDestination? {
        let title = localized(
            .translationTitleFormat,
            languageName(for: sourceLanguageID),
            languageName(for: targetLanguageID)
        )
        let statusID = "translation:\(sourceLanguageID)->\(targetLanguageID)"
        let downloadingDetail = localized(.downloadingTranslationResources)
        let waitingDetail = localized(.waitingTranslationResourcesInstalling)
        let manualDownloadDetail = localized(.manualTranslationDownloadDetail)
        let maxAttempts = 3
        var attemptCount = 0

        while Task.isCancelled == false {
            let availabilityStatus = await translationAvailabilityStatus(
                from: sourceLanguageID,
                to: targetLanguageID
            )

            switch availabilityStatus {
            case .unsupported:
                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                    id: statusID,
                    kind: .translation,
                    title: title,
                    detail: localized(.translationNotSupportedPairOnMacOS),
                    progress: nil,
                    isError: true
                )
                )
                return nil
            case .supported, .installed:
                attemptCount += 1
                if attemptCount > maxAttempts {
                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: manualDownloadDetail,
                            progress: nil,
                            isError: true
                        )
                    )
                    return .translationLanguages
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .translation,
                        title: title,
                        detail: availabilityStatus == .supported ? downloadingDetail : waitingDetail,
                        progress: nil,
                        isError: false
                    )
                )

                do {
                    try await prepareTranslationResourceWithTimeout(
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                } catch is CancellationError {
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                } catch {
                    if let error = error as? LanguageResourcePreparationError,
                       error == .translationDownloadTimedOut {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: manualDownloadDetail,
                                progress: nil,
                                isError: true
                            )
                        )
                        return .translationLanguages
                    }

                    if let serviceError = error as? TranslationCoordinator.ServiceError {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: serviceError.localizedDescription(languageID: resolvedInterfaceLanguageID),
                            progress: nil,
                            isError: true
                        )
                        )
                        return nil
                    }

                    let nsError = error as NSError
                    if nsError.domain == "TranslationErrorDomain", nsError.code == 14 {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: manualDownloadDetail,
                                progress: nil,
                                isError: true
                            )
                        )
                        return .translationLanguages
                    }

                    let refreshedStatus = await translationAvailabilityStatus(
                        from: sourceLanguageID,
                        to: targetLanguageID
                    )

                    if refreshedStatus == .supported || refreshedStatus == .installed {
                        upsertLanguageResourceStatus(
                            LanguageResourceStatus(
                                id: statusID,
                                kind: .translation,
                                title: title,
                                detail: waitingDetail,
                                progress: nil,
                                isError: false
                            )
                        )

                        do {
                            try await Task.sleep(nanoseconds: 800_000_000)
                        } catch {
                            removeLanguageResourceStatus(id: statusID)
                            return nil
                        }

                        continue
                    }

                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: localizedErrorDescription(error),
                            progress: nil,
                            isError: true
                        )
                    )
                    return nil
                }
            @unknown default:
                attemptCount += 1
                if attemptCount > maxAttempts {
                    upsertLanguageResourceStatus(
                        LanguageResourceStatus(
                            id: statusID,
                            kind: .translation,
                            title: title,
                            detail: manualDownloadDetail,
                            progress: nil,
                            isError: true
                        )
                    )
                    return .translationLanguages
                }

                upsertLanguageResourceStatus(
                    LanguageResourceStatus(
                        id: statusID,
                        kind: .translation,
                        title: title,
                        detail: waitingDetail,
                        progress: nil,
                        isError: false
                    )
                )

                do {
                    try await Task.sleep(nanoseconds: 800_000_000)
                } catch {
                    removeLanguageResourceStatus(id: statusID)
                    return nil
                }
            }
        }

        removeLanguageResourceStatus(id: statusID)
        return nil
    }

    private func prepareTranslationResourceWithTimeout(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [translationCoordinator] in
                try await translationCoordinator.prepareIfNeeded(
                    from: sourceLanguageID,
                    to: targetLanguageID
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw LanguageResourcePreparationError.translationDownloadTimedOut
            }

            let result: Void? = try await group.next()
            group.cancelAll()
            _ = result
        }
    }

    @available(macOS 26.0, *)
    private func makeSpeechTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private func normalizedProgressValue(_ fractionCompleted: Double) -> Double? {
        guard fractionCompleted.isFinite, fractionCompleted >= 0 else {
            return nil
        }

        return min(max(fractionCompleted, 0), 1)
    }

    private func translationAvailabilityStatus(
        from sourceLanguageID: String,
        to targetLanguageID: String
    ) async -> LanguageAvailability.Status {
        guard #available(macOS 15.0, *) else {
            return .unsupported
        }

        let sourceLanguage = Locale.Language(identifier: sourceLanguageID)
        let targetLanguage = Locale.Language(identifier: targetLanguageID)
        let availability = LanguageAvailability()
        return await availability.status(from: sourceLanguage, to: targetLanguage)
    }

    private func upsertLanguageResourceStatus(_ status: LanguageResourceStatus) {
        if let existingIndex = languageResourceStatuses.firstIndex(where: { $0.id == status.id }) {
            languageResourceStatuses[existingIndex] = status
        } else {
            languageResourceStatuses.append(status)
        }

        languageResourceStatuses.sort { lhs, rhs in
            if lhs.kind.rawValue == rhs.kind.rawValue {
                return lhs.title < rhs.title
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private func removeLanguageResourceStatus(id: String) {
        languageResourceStatuses.removeAll { $0.id == id }
    }

    private func openSystemSettings(for destination: LanguageResourceSystemSettingsDestination) {
        guard let url = URL(string: destination.urlString) else {
            return
        }

        if NSWorkspace.shared.open(url) == false,
           let fallbackURL = URL(string: "x-apple.systempreferences:") {
            _ = NSWorkspace.shared.open(fallbackURL)
        }
    }

    // MARK: - Draft handler

    private func handlePartialDraft(_ draft: DraftSegment?) {
        guard liveTranscriptionSession != nil else { return }
        if let draft, isFinalizedDraftPromotionID(draft.segmentId) {
            return
        }

        let draftText = sanitizedDisplayText(draft?.sourceText ?? "")
        if draftText.isEmpty {
            if isDraftPromotionPending() {
                return
            }
            scheduleDraftClear()
            return
        }

        cancelCommittedCaptionArchive()
        cancelPendingDraftClear()
        overlayState?.draftSourceText = draftText
        overlayState?.draftStablePrefixLength = min(draft?.stablePrefixLength ?? 0, draftText.count)
        overlayState?.draftPromotionID = draft?.segmentId

        dismissListeningPlaceholderIfNeeded()

        let stablePrefix = String(draftText.prefix(min(draft?.stablePrefixLength ?? 0, draftText.count)))
        lastDraftStablePrefix = stablePrefix

        guard draftText != lastDraftTranslationSource else { return }
        lastDraftTranslationSource = draftText

        if shouldReserveDraftTranslationSlot {
            scheduleDraftTranslation(for: draftText)
        } else {
            draftTranslationTask?.cancel()
            draftTranslationTask = nil
            draftTranslationGeneration &+= 1
            overlayState?.draftTranslatedText = draftText
        }
    }

    private func scheduleDraftClear() {
        draftClearTask?.cancel()
        draftClearGeneration &+= 1
        let generation = draftClearGeneration

        draftClearTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: Self.draftClearDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  liveTranscriptionSession != nil,
                  generation == draftClearGeneration else { return }

            clearDraftOverlay()
            scheduleCommittedCaptionArchiveIfNeeded()
        }
    }

    private func cancelPendingDraftClear() {
        draftClearTask?.cancel()
        draftClearTask = nil
        draftClearGeneration &+= 1
    }

    private func clearDraftOverlay() {
        draftClearTask?.cancel()
        draftClearTask = nil
        overlayState?.draftSourceText = nil
        overlayState?.draftStablePrefixLength = 0
        overlayState?.draftTranslatedText = nil
        overlayState?.draftPromotionID = nil
        lastDraftStablePrefix = ""
        lastDraftTranslationSource = ""
        draftTranslationTask?.cancel()
        draftTranslationTask = nil
        draftTranslationGeneration &+= 1
    }

    private func scheduleDraftTranslation(for text: String) {
        draftTranslationTask?.cancel()
        draftTranslationGeneration &+= 1
        let generation = draftTranslationGeneration
        draftTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep draft translation responsive while still coalescing very fast ASR churn.
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
            guard !Task.isCancelled, liveTranscriptionSession != nil else { return }

            let sourceID = currentSourceLanguageID
            let targetID = outputLanguageID
            guard generation == draftTranslationGeneration else { return }

            guard sourceID != targetID else {
                overlayState?.draftTranslatedText = text
                return
            }

            let translated = await withTaskGroup(of: String?.self, returning: String?.self) { group in
                group.addTask {
                    try? await self.translationCoordinator.translate(text, from: sourceID, to: targetID)
                }
                // Draft translation should feel live; drop stale work quickly.
                group.addTask {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }

            guard !Task.isCancelled,
                  liveTranscriptionSession != nil,
                  generation == draftTranslationGeneration else { return }
            if let translated {
                overlayState?.draftTranslatedText = glossaryService.apply(to: translated, glossary: glossary)
            }
        }
    }

    // MARK: - Overlay history

    /// Archives the current committed caption, then clears the live overlay text.
    private func clearOverlayText() {
        if let currentCaption = currentCommittedCaptionHistoryPayload() {
            appendOverlayHistoryEntry(
                translatedText: currentCaption.translatedText,
                sourceText: currentCaption.sourceText
            )
        }
        cancelCommittedCaptionArchive()
        clearDraftOverlay()
        overlayState?.translatedText = ""
        overlayState?.sourceText = ""
        overlayState?.committedPromotionID = nil
        displayedCaption = nil
        displayedCaptionLastVisualUpdateAt = Date.distantPast
        displayedCaptionLastVisualUpdateWasLateTranslation = false
    }

    /// Archives the currently committed caption into the scrollback history before
    /// the next sentence replaces it.
    private func capturePreviousCaption() {
        guard let currentCaption = currentCommittedCaptionHistoryPayload() else { return }
        appendOverlayHistoryEntry(
            translatedText: currentCaption.translatedText,
            sourceText: currentCaption.sourceText
        )
    }

    private func updateCommittedOverlay(
        translatedText: String,
        sourceText: String,
        promotionID: UUID? = nil,
        bumpEpoch: Bool = false,
        lateTranslation: Bool = false
    ) {
        if bumpEpoch {
            overlayState?.captionEpoch = (overlayState?.captionEpoch ?? 0) + 1
        }

        overlayState?.translatedText = translatedText
        overlayState?.sourceText = sourceText
        if let promotionID {
            overlayState?.committedPromotionID = promotionID
        }
        displayedCaptionLastVisualUpdateAt = Date()
        displayedCaptionLastVisualUpdateWasLateTranslation = lateTranslation
    }

    // MARK: - Settings sync

    private func syncOverlayPreviewIfNeeded() {
        guard liveTranscriptionSession == nil else {
            return
        }

        guard isOverlayVisible || sessionState == .running else {
            return
        }

        let source = selectedSource ?? previewInputSource
        overlayState = makePreviewState(for: source)
        overlayHistoryScrollOffset = 0
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
        let sourceText = sanitizedDisplayText(sentence.text)
        guard sourceText.isEmpty == false else {
            return
        }

        cancelCommittedCaptionArchive()

        if let promotionID = sentence.promotionSegmentID {
            markDraftPromotionFinalized(promotionID)
        }

        guard shouldEnqueueRecognizedSentence(sourceText) else {
            return
        }

        let caption = QueuedCaption(
            id: UUID(),
            promotionID: sentence.promotionSegmentID ?? UUID(),
            sourceText: sourceText,
            sourceName: sourceName
        )

        rememberRecognizedSentence(sourceText)
        pendingCaptions.append(caption)
        translateCaption(caption)

        // Keep the currently displayed caption plus up to two fresh arrivals.
        // This avoids losing the first sentence when a single ASR result is split
        // into two back-to-back captions.
        while pendingCaptions.count > 3 {
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

        setStatus(.running(sourceName: sourceName))
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

    var shouldReserveDraftTranslationSlot: Bool {
        currentSourceLanguageID != outputLanguageID
    }

    private func resetLiveTextPipeline() {
        captionDisplayTask?.cancel()
        captionDisplayTask = nil
        draftClearTask?.cancel()
        draftClearTask = nil
        draftTranslationTask?.cancel()
        draftTranslationTask = nil
        committedCaptionArchiveTask?.cancel()
        committedCaptionArchiveTask = nil
        lastDraftStablePrefix = ""
        lastDraftTranslationSource = ""
        draftTranslationGeneration &+= 1
        draftClearGeneration &+= 1
        cancelCaptionTranslations()
        pendingCaptions.removeAll()
        readyCaptionTranslations.removeAll()
        translationRevisions.removeAll()
        recentRecognizedCaptionTexts.removeAll()
        finalizedDraftPromotionIDs.removeAll()
        displayedCaption = nil
        activeInputLanguageID = nil
        overlayHistoryScrollOffset = 0
        displayedCaptionLastVisualUpdateAt = Date.distantPast
        displayedCaptionLastVisualUpdateWasLateTranslation = false

        translationCoordinator.reset()

        Task {
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
        defer {
            captionDisplayTask = nil
            scheduleCommittedCaptionArchiveIfNeeded()
        }

        while Task.isCancelled == false {
            guard liveTranscriptionSession != nil else { break }
            guard let caption = pendingCaptions.first else {
                // Keep the most recent committed caption in the primary white slot
                // until a newer caption arrives and replaces it.
                break
            }

            // Caption cleanup runs on every exit from this iteration: normal
            // completion, break, or sleep cancellation. This prevents captions from
            // getting stuck in pendingCaptions and replaying on the next queue start.
            defer {
                pendingCaptions.removeAll(where: { $0.id == caption.id })
                readyCaptionTranslations.removeValue(forKey: caption.id)
            }

            // Archive the current caption before the next sentence replaces it.
            capturePreviousCaption()

            // Source-first: show source text immediately while translation is pending
            cancelCommittedCaptionArchive()
            displayedCaption = caption

            // If a draft translation was visible, skip the fade-in so the committed
            // text replaces the draft seamlessly instead of flashing.
            let hadDraftTranslation = overlayState?.draftTranslatedText?.isEmpty == false

            overlayState?.skipCommittedFadeIn = hadDraftTranslation
            updateCommittedOverlay(
                translatedText: caption.sourceText,
                sourceText: caption.sourceText,
                promotionID: caption.promotionID,
                bumpEpoch: true
            )
            overlayState?.sourceName = caption.sourceName
            clearDraftOverlay()

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

    private func normalizedCaptionText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    private func sanitizedDisplayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }

        return containsSubtitleContent(trimmed) ? trimmed : ""
    }

    private func containsSubtitleContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) == false
                && CharacterSet.punctuationCharacters.contains(scalar) == false
                && CharacterSet.symbols.contains(scalar) == false
        }
    }

    private func shouldEnqueueRecognizedSentence(_ text: String) -> Bool {
        let now = Date()
        let normalized = normalizedCaptionText(text)
        recentRecognizedCaptionTexts.removeAll { now.timeIntervalSince($0.time) > 6.0 }

        if normalized.isEmpty {
            return false
        }

        if let displayedCaption,
           normalizedCaptionText(displayedCaption.sourceText) == normalized {
            return false
        }

        if pendingCaptions.contains(where: { normalizedCaptionText($0.sourceText) == normalized }) {
            return false
        }

        return recentRecognizedCaptionTexts.contains(where: { $0.text == normalized }) == false
    }

    private func rememberRecognizedSentence(_ text: String) {
        let now = Date()
        recentRecognizedCaptionTexts.removeAll { now.timeIntervalSince($0.time) > 6.0 }
        recentRecognizedCaptionTexts.append((text: normalizedCaptionText(text), time: now))
    }

    private func markDraftPromotionFinalized(_ id: UUID) {
        let now = Date()
        pruneFinalizedDraftPromotionIDs(now: now)
        finalizedDraftPromotionIDs.removeAll { $0.id == id }
        finalizedDraftPromotionIDs.append((id: id, time: now))
    }

    private func isFinalizedDraftPromotionID(_ id: UUID) -> Bool {
        let now = Date()
        pruneFinalizedDraftPromotionIDs(now: now)
        return finalizedDraftPromotionIDs.contains { $0.id == id }
    }

    private func pruneFinalizedDraftPromotionIDs(now: Date) {
        finalizedDraftPromotionIDs.removeAll { now.timeIntervalSince($0.time) > 12.0 }

        if finalizedDraftPromotionIDs.count > Self.finalizedDraftPromotionLimit {
            finalizedDraftPromotionIDs.removeFirst(
                finalizedDraftPromotionIDs.count - Self.finalizedDraftPromotionLimit
            )
        }
    }

    private func isDraftPromotionPending() -> Bool {
        guard let draftPromotionID = overlayState?.draftPromotionID else {
            return false
        }

        if displayedCaption?.promotionID == draftPromotionID {
            return true
        }

        return pendingCaptions.contains { $0.promotionID == draftPromotionID }
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
            group.addTask {
                do {
                    return try await self.translationCoordinator.translate(
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

    private func cancelCommittedCaptionArchive() {
        committedCaptionArchiveTask?.cancel()
        committedCaptionArchiveTask = nil
    }

    private func scheduleCommittedCaptionArchiveIfNeeded() {
        cancelCommittedCaptionArchive()

        guard liveTranscriptionSession != nil,
              pendingCaptions.isEmpty,
              hasActiveDraftOverlay == false,
              currentCommittedCaptionHistoryPayload() != nil else {
            return
        }

        let elapsed = max(0, Date().timeIntervalSince(displayedCaptionLastVisualUpdateAt))
        let remainingDelay = max(0, Self.committedCaptionIdleArchiveDelay - elapsed)

        committedCaptionArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if remainingDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  liveTranscriptionSession != nil,
                  pendingCaptions.isEmpty,
                  hasActiveDraftOverlay == false,
                  currentCommittedCaptionHistoryPayload() != nil else {
                return
            }

            clearOverlayText()
        }
    }

    private var hasActiveDraftOverlay: Bool {
        sanitizedDisplayText(overlayState?.draftSourceText ?? "").isEmpty == false
    }

    private func currentCommittedCaptionHistoryPayload() -> (translatedText: String, sourceText: String)? {
        guard let current = overlayState,
              displayedCaption != nil,
              current.translatedText.isEmpty == false,
              current.translatedText != listeningPlaceholderText,
              current.translatedText != captureStoppedText,
              current.translatedText != unableToStartText else {
            return nil
        }

        return (current.translatedText, current.sourceText)
    }

    private var overlayHistoryCount: Int {
        overlayState?.history.count ?? 0
    }

    private var overlayHistoryMaxScrollOffset: Int {
        max(0, overlayHistoryCount - max(0, overlayHistoryVisibleCount))
    }

    private func clampOverlayHistoryScrollOffset() {
        overlayHistoryScrollOffset = min(max(overlayHistoryScrollOffset, 0), overlayHistoryMaxScrollOffset)
    }

    private func appendOverlayHistoryEntry(translatedText: String, sourceText: String) {
        guard shouldStoreOverlayHistory(translatedText: translatedText, sourceText: sourceText) else {
            return
        }

        if let lastEntry = overlayState?.history.last,
           lastEntry.translatedText == translatedText,
           lastEntry.sourceText == sourceText {
            return
        }

        if overlayHistoryScrollOffset > 0 {
            overlayHistoryScrollOffset += 1
        }

        overlayState?.history.append(
            OverlayHistoryEntry(
                translatedText: translatedText,
                sourceText: sourceText
            )
        )

        let overflow = max(0, (overlayState?.history.count ?? 0) - Self.overlayHistoryLimit)
        if overflow > 0 {
            overlayState?.history.removeFirst(overflow)
            if overlayHistoryScrollOffset > 0 {
                overlayHistoryScrollOffset = max(0, overlayHistoryScrollOffset - overflow)
            }
        }

        clampOverlayHistoryScrollOffset()
    }

    private func shouldStoreOverlayHistory(translatedText: String, sourceText: String) -> Bool {
        let normalizedTranslated = sanitizedDisplayText(translatedText)
        let normalizedSource = sanitizedDisplayText(sourceText)
        guard normalizedTranslated.isEmpty == false || normalizedSource.isEmpty == false else {
            return false
        }

        switch normalizedTranslated {
        case listeningPlaceholderText, captureStoppedText, unableToStartText:
            return false
        default:
            return true
        }
    }

    private func dismissListeningPlaceholderIfNeeded() {
        guard overlayState?.translatedText == listeningPlaceholderText else {
            return
        }

        overlayState?.translatedText = ""
        overlayState?.sourceText = ""
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
        case "es":
            return "Bienvenido a v2s. La barra de subtitulos ya esta lista."
        case "de":
            return "Willkommen bei v2s. Die Untertitel-Leiste ist bereit."
        case "ja":
            return "v2s へようこそ。字幕バーの準備ができました。"
        case "fr":
            return "Bienvenue dans v2s. La barre de sous-titres est prete."
        case "ko":
            return "v2s에 오신 것을 환영합니다. 자막 바가 준비되었습니다."
        case "ar":
            return "مرحبا بك في v2s. شريط الترجمة جاهز."
        case "pt":
            return "Bem-vindo ao v2s. A barra de legendas esta pronta."
        case "ru":
            return "Добро пожаловать в v2s. Строка субтитров готова."
        default:
            return "Welcome to v2s. The subtitle bar is ready."
        }
    }

}

private enum StatusDescriptor {
    case ready
    case noInputSourcesDetected
    case running(sourceName: String)
    case chooseInputSourceBeforeStarting
    case checkingLanguageResources
    case downloadLanguageResourcesInSystemSettings
    case preparing(sourceName: String)
    case showingOverlayPreview
    case custom(String)
}

private extension AppModel {
    static let overlayHistoryLimit = 120
    static let draftClearDelayNanoseconds: UInt64 = 150_000_000
    static let committedCaptionIdleArchiveDelay: TimeInterval = 0.9
    static let finalizedDraftPromotionLimit = 32
}

private struct QueuedCaption: Identifiable, Equatable {
    let id: UUID
    let promotionID: UUID
    let sourceText: String
    let sourceName: String
}

private enum LanguageResourcePreparationError: LocalizedError, AppLocalizableError {
    case unsupportedSpeechLanguage
    case speechDownloadTimedOut
    case translationDownloadTimedOut

    func localizedDescription(languageID: String) -> String {
        switch self {
        case .unsupportedSpeechLanguage:
            return AppLocalization.string(.speechResourcesNotSupportedOnMacOS, languageID: languageID)
        case .speechDownloadTimedOut:
            return AppLocalization.string(.speechResourceDownloadTimedOut, languageID: languageID)
        case .translationDownloadTimedOut:
            return AppLocalization.string(.translationResourceDownloadTimedOut, languageID: languageID)
        }
    }

    var errorDescription: String? {
        localizedDescription(languageID: "en")
    }
}

private enum LanguageResourceSystemSettingsDestination: Hashable {
    case keyboard
    case translationLanguages

    var urlString: String {
        switch self {
        case .keyboard:
            return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        case .translationLanguages:
            return "x-apple.systempreferences:com.apple.Localization-Settings.extension"
        }
    }
}

struct LanguageResourceStatus: Identifiable, Equatable {
    enum Kind: Int {
        case speech = 0
        case translation = 1
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let progress: Double?
    let isError: Bool
}

@MainActor
private final class TranslationCoordinator: ObservableObject {
    private struct LanguagePair: Equatable {
        let source: String
        let target: String
    }

    private enum PendingOperation {
        case prepare(
            id: UUID,
            generation: Int,
            pair: LanguagePair,
            continuation: CheckedContinuation<Void, Error>
        )
        case translate(
            id: UUID,
            generation: Int,
            pair: LanguagePair,
            text: String,
            continuation: CheckedContinuation<String, Error>
        )

        var id: UUID {
            switch self {
            case .prepare(let id, _, _, _), .translate(let id, _, _, _, _):
                return id
            }
        }

        var generation: Int {
            switch self {
            case .prepare(_, let generation, _, _), .translate(_, let generation, _, _, _):
                return generation
            }
        }

        var pair: LanguagePair {
            switch self {
            case .prepare(_, _, let pair, _), .translate(_, _, let pair, _, _):
                return pair
            }
        }
    }

    enum ServiceError: LocalizedError, AppLocalizableError {
        case unavailableOnSystem
        case unsupportedPair(String, String)

        func localizedDescription(languageID: String) -> String {
            switch self {
            case .unavailableOnSystem:
                return AppLocalization.string(.translationRequiresMacOS15OrNewer, languageID: languageID)
            case .unsupportedPair(let source, let target):
                return AppLocalization.string(
                    .translationUnsupportedFromToFormat,
                    languageID: languageID,
                    source,
                    target
                )
            }
        }

        var errorDescription: String? {
            localizedDescription(languageID: "en")
        }
    }

    var onConfigurationChange: ((TranslationSession.Configuration?) -> Void)?

    private(set) var configuration: TranslationSession.Configuration? {
        didSet {
            onConfigurationChange?(configuration)
        }
    }

    private var currentPair: LanguagePair?
    private var pendingOperations: [PendingOperation] = []
    private var activeRunnerID: UUID?
    private var activeOperationID: UUID?
    private var cancelledOperationIDs: Set<UUID> = []
    private var generation: Int = 0

    func prepareIfNeeded(
        from sourceIdentifier: String,
        to targetIdentifier: String
    ) async throws {
        guard sourceIdentifier != targetIdentifier else {
            return
        }

        let pair = LanguagePair(source: sourceIdentifier, target: targetIdentifier)
        let requestGeneration = generation
        let status = try await availabilityStatus(for: pair)
        guard requestGeneration == generation else {
            throw CancellationError()
        }

        guard status != .installed else {
            return
        }

        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    .prepare(
                        id: operationID,
                        generation: requestGeneration,
                        pair: pair,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelOperation(id: operationID)
            }
        }
    }

    func translate(_ text: String, from sourceIdentifier: String, to targetIdentifier: String) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return ""
        }

        guard sourceIdentifier != targetIdentifier else {
            return trimmedText
        }

        let pair = LanguagePair(source: sourceIdentifier, target: targetIdentifier)
        let requestGeneration = generation
        _ = try await availabilityStatus(for: pair)
        guard requestGeneration == generation else {
            throw CancellationError()
        }

        let operationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    .translate(
                        id: operationID,
                        generation: requestGeneration,
                        pair: pair,
                        text: trimmedText,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelOperation(id: operationID)
            }
        }
    }

    @available(macOS 15.0, *)
    func run(using session: TranslationSession) async {
        let runnerID = UUID()

        while Task.isCancelled == false {
            if activeRunnerID == nil {
                activeRunnerID = runnerID
                break
            }

            if activeRunnerID == runnerID {
                break
            }

            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }

        guard Task.isCancelled == false else {
            return
        }

        let runnerGeneration = generation

        defer {
            if activeRunnerID == runnerID {
                activeRunnerID = nil
            }
        }

        guard runnerGeneration == generation else {
            return
        }

        guard let anchoredPair = currentPair else {
            return
        }

        while Task.isCancelled == false {
            guard runnerGeneration == generation else {
                return
            }

            guard let operation = await nextOperation(for: anchoredPair, generation: runnerGeneration) else {
                return
            }

            activeOperationID = operation.id

            switch operation {
            case .prepare(let id, _, _, let continuation):
                do {
                    try await session.prepareTranslation()
                    finishOperation(id: id, continuation: continuation)
                } catch {
                    finishOperation(id: id, continuation: continuation, error: error)
                }

            case .translate(let id, _, _, let text, let continuation):
                do {
                    let response = try await session.translate(text)
                    let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    finishOperation(
                        id: id,
                        continuation: continuation,
                        result: translatedText.isEmpty ? text : translatedText
                    )
                } catch {
                    finishOperation(id: id, continuation: continuation, error: error)
                }
            }
        }
    }

    func reset() {
        generation &+= 1

        cancelledOperationIDs.removeAll()
        if let activeOperationID {
            cancelledOperationIDs.insert(activeOperationID)
        }

        for operation in pendingOperations {
            switch operation {
            case .prepare(_, _, _, let continuation):
                continuation.resume(throwing: CancellationError())
            case .translate(_, _, _, _, let continuation):
                continuation.resume(throwing: CancellationError())
            }
        }

        pendingOperations.removeAll()
        activeRunnerID = nil
        activeOperationID = nil
        currentPair = nil
        configuration = nil
    }

    private func enqueue(_ operation: PendingOperation) {
        activate(pair: operation.pair)
        pendingOperations.append(operation)
    }

    private func activate(pair: LanguagePair) {
        if currentPair != pair {
            cancelPendingOperations(except: pair)
            currentPair = pair
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: pair.source),
                target: Locale.Language(identifier: pair.target)
            )
        } else if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: pair.source),
                target: Locale.Language(identifier: pair.target)
            )
        }
    }

    private func cancelPendingOperations(except pair: LanguagePair) {
        let survivors = pendingOperations.filter { $0.pair == pair }
        let cancelled = pendingOperations.filter { $0.pair != pair }
        pendingOperations = survivors

        for operation in cancelled {
            switch operation {
            case .prepare(_, _, _, let continuation):
                continuation.resume(throwing: CancellationError())
            case .translate(_, _, _, _, let continuation):
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func cancelOperation(id: UUID) {
        if let index = pendingOperations.firstIndex(where: { $0.id == id }) {
            let operation = pendingOperations.remove(at: index)
            switch operation {
            case .prepare(_, _, _, let continuation):
                continuation.resume(throwing: CancellationError())
            case .translate(_, _, _, _, let continuation):
                continuation.resume(throwing: CancellationError())
            }
            return
        }

        if activeOperationID == id {
            cancelledOperationIDs.insert(id)
        }
    }

    @available(macOS 15.0, *)
    private func nextOperation(for pair: LanguagePair, generation: Int) async -> PendingOperation? {
        while Task.isCancelled == false {
            guard generation == self.generation else {
                return nil
            }

            if let index = pendingOperations.firstIndex(where: {
                $0.pair == pair && $0.generation == generation
            }) {
                return pendingOperations.remove(at: index)
            }

            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return nil
            }
        }

        return nil
    }

    private func finishOperation(
        id: UUID,
        continuation: CheckedContinuation<Void, Error>,
        error: Error? = nil
    ) {
        activeOperationID = nil

        if cancelledOperationIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func finishOperation(
        id: UUID,
        continuation: CheckedContinuation<String, Error>,
        result: String? = nil,
        error: Error? = nil
    ) {
        activeOperationID = nil

        if cancelledOperationIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: result ?? "")
        }
    }

    private func availabilityStatus(for pair: LanguagePair) async throws -> LanguageAvailability.Status {
        guard #available(macOS 15.0, *) else {
            throw ServiceError.unavailableOnSystem
        }

        let sourceLanguage = Locale.Language(identifier: pair.source)
        let targetLanguage = Locale.Language(identifier: pair.target)
        let availability = LanguageAvailability()
        let availabilityStatus = await availability.status(from: sourceLanguage, to: targetLanguage)

        guard availabilityStatus != .unsupported else {
            throw ServiceError.unsupportedPair(pair.source, pair.target)
        }

        return availabilityStatus
    }
}

extension View {
    @ViewBuilder
    func v2sTranslationHost(model: AppModel) -> some View {
        if #available(macOS 15.0, *) {
            self.translationTask(model.translationHostConfiguration) { session in
                await model.runTranslationHost(using: session)
            }
        } else {
            self
        }
    }
}
