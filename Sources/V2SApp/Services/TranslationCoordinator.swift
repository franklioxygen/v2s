import Combine
import Foundation
import Translation

/// Serializes all translation work through the single view-anchored
/// `TranslationSession` provided by SwiftUI's `.translationTask` host.
///
/// Operations are queued per language pair; one runner loop owns the active
/// session and drains matching operations. The runner stays parked between
/// sentences so the session (and its loaded translation models) remains warm
/// during a live captioning session, and yields promptly when the language
/// pair changes so a fresh session can be configured.
///
/// Drafts are the exception: where the system has a low-latency model installed
/// (macOS 26.4+), they are translated on a session of their own with it, about ten
/// times faster and slightly less accurate (speech_eval/calibration/STRATEGY.md).
/// Committed captions are always translated by the view-anchored session.
@MainActor
final class TranslationCoordinator: ObservableObject {
    /// How long the runner keeps the current session alive while idle.
    /// Natural pauses between spoken sentences are often seconds long;
    /// exiting early would tear down and respawn a TranslationSession for
    /// nearly every caption. Pair switches do not wait for this timeout —
    /// the runner yields as soon as an operation for another pair arrives.
    private static let runnerIdleTimeout: TimeInterval = 10.0
    /// While live captions run the session stays warm: after 15 s of silence a
    /// sentence took 0.73 s on the same session and 1.10 s on a new one, against
    /// 0.40 s warm (reports/translation-context-experiment/speed-benchmark.txt).
    /// An idle runner re-translates a few words this often, for this long after
    /// the last real request.
    private static let keepWarmInterval: TimeInterval = 6.0
    private static let keepWarmDuration: TimeInterval = 180.0
    private static let translationMemoLimit = 256

    private struct LanguagePair: Hashable {
        let source: String
        let target: String
    }

    private struct MemoKey: Hashable {
        let pair: LanguagePair
        let text: String
    }

    enum Quality {
        /// Committed captions and the transcript: the system's most accurate model.
        case final
        /// Drafts, which a committed caption replaces: the low-latency model where
        /// it is installed, else the same model as `final`.
        case preview
    }

    enum Priority {
        /// Captions on screen or about to be shown, and live drafts.
        case normal
        /// Transcript-only work that runs only when no normal request is waiting.
        case background
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
            priority: Priority,
            continuation: CheckedContinuation<String, Error>
        )

        var id: UUID {
            switch self {
            case .prepare(let id, _, _, _), .translate(let id, _, _, _, _, _):
                return id
            }
        }

        var generation: Int {
            switch self {
            case .prepare(_, let generation, _, _), .translate(_, let generation, _, _, _, _):
                return generation
            }
        }

        var pair: LanguagePair {
            switch self {
            case .prepare(_, _, let pair, _), .translate(_, _, let pair, _, _, _):
                return pair
            }
        }

        var priority: Priority {
            switch self {
            case .prepare:
                return .normal
            case .translate(_, _, _, _, let priority, _):
                return priority
            }
        }
    }

    private enum OperationWaitResult {
        case signaled
        case timedOut
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
    var localeIdentifierForLanguageID: ((String) -> String)?

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
    private var runnerAvailabilityWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var operationSignalWaiters: [UUID: CheckedContinuation<OperationWaitResult, Never>] = [:]
    /// Language pairs confirmed `.installed` this session, so the hot path can
    /// skip the framework availability round-trip on every request.
    private var installedPairs: Set<LanguagePair> = []
    /// Bounded memo of completed translations. Collapses the duplicate work of
    /// re-translating a promoted draft as its committed caption and of repeated
    /// short utterances, and keeps repeated sentences translated consistently.
    private var translationMemo: [MemoKey: String] = [:]
    private var translationMemoOrder: [MemoKey] = []
    var consecutiveTimeouts: Int = 0
    /// Set while live captions run: the runner keeps its session instead of
    /// releasing it after an idle interval.
    var keepsSessionWarm = false
    private var lastTranslatedText: String?
    private var lastRequestedAt = Date.distantPast
    private var lastWaitTimedOut = false

    /// Low-latency sessions per pair, as `TranslationSession`s: a stored property
    /// cannot require a newer system than its type.
    private var previewSessions: [LanguagePair: AnyObject] = [:]
    /// Pairs without an installed low-latency model, or whose model failed.
    private var pairsWithoutPreviewModel: Set<LanguagePair> = []
    /// Pairs for which some translation came from the low-latency model.
    private var pairsWithPreviews: Set<LanguagePair> = []
    /// Low-latency translations, kept apart so no committed caption reuses one.
    private var previewMemo: [MemoKey: String] = [:]
    private var previewMemoOrder: [MemoKey] = []
    /// The latest low-latency request; each waits for the one before it.
    private var previewTail: Task<Void, Never>?
    #if DEBUG
    /// Stands in for an installed low-latency model.
    var previewTranslatorForTesting: ((String) async throws -> String)?

    func markPreviewsServedForTesting(from source: String, to target: String) {
        pairsWithPreviews.insert(LanguagePair(source: source, target: target))
    }

    func memoizedTranslationForTesting(_ text: String, from source: String, to target: String) -> String? {
        translationMemo[MemoKey(pair: LanguagePair(source: source, target: target), text: text)]
    }
    #endif

    /// Whether a draft translation for this pair may have come from the
    /// low-latency model, so a caption promoted from it still needs its own.
    func hasServedPreviews(from source: String, to target: String) -> Bool {
        pairsWithPreviews.contains(LanguagePair(source: source, target: target))
    }

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

    func translate(
        _ text: String,
        from sourceIdentifier: String,
        to targetIdentifier: String,
        context: SentenceTranslationContext? = nil,
        priority: Priority = .normal,
        quality: Quality = .final
    ) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return ""
        }

        guard sourceIdentifier != targetIdentifier else {
            return trimmedText
        }

        // The standalone memo may contain a different meaning of a short phrase
        // (e.g. ただいま -> "now"). Resolve the passage before consulting that memo.
        if let context, context.matchesCaption(trimmedText) {
            do {
                let passage = try await translate(
                    context.sourceText, from: sourceIdentifier, to: targetIdentifier, priority: priority,
                    quality: quality
                )
                if let sentence = context.translatedSentence(from: passage) { return sentence }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A failed or unalignable passage can still be translated individually.
            }
        }

        let pair = LanguagePair(source: sourceIdentifier, target: targetIdentifier)
        if let memoized = translationMemo[MemoKey(pair: pair, text: trimmedText)] {
            return memoized
        }
        if quality == .preview, let previewed = try await previewTranslation(of: trimmedText, pair: pair) {
            return previewed
        }

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
                        priority: priority,
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

            await waitForRunnerAvailability(runnerID: runnerID)
        }

        let runnerGeneration = generation

        // Installed before the cancellation guard: ownership is claimed above, so
        // returning without releasing it would leave the coordinator believing a
        // runner is alive and block every later session activation.
        defer {
            if activeRunnerID == runnerID {
                activeRunnerID = nil
                signalRunnerAvailabilityWaiters()
                if generation == runnerGeneration, let nextIndex = nextPendingOperationIndex() {
                    activate(pair: pendingOperations[nextIndex].pair)
                }
            }
        }

        guard Task.isCancelled == false else {
            return
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

            guard let operation = await nextOperation(
                for: anchoredPair,
                generation: runnerGeneration,
                idleTimeout: keepsSessionWarm ? Self.keepWarmInterval : Self.runnerIdleTimeout
            ) else {
                // Through a pause in live captions, keep the model warm with a few
                // words of the last sentence rather than releasing the session.
                if lastWaitTimedOut, keepsSessionWarm, runnerGeneration == generation, Task.isCancelled == false,
                   Date().timeIntervalSince(lastRequestedAt) < Self.keepWarmDuration,
                   let text = lastTranslatedText {
                    _ = try? await session.translate(String(text.prefix(12)))
                    continue
                }
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

            case .translate(let id, _, let pair, let text, _, let continuation):
                // Several captions can request the same passage before the first
                // request finishes. Recheck here so that passage is translated once.
                if let memoized = translationMemo[MemoKey(pair: pair, text: text)] {
                    finishOperation(id: id, continuation: continuation, result: memoized)
                    continue
                }
                lastTranslatedText = text
                do {
                    let response = try await session.translate(text)
                    let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedText = translatedText.isEmpty ? text : translatedText
                    // Only a real translation is worth remembering. Memoizing the
                    // source-text fallback would pin this sentence to its untranslated
                    // form for the rest of the session and make the caller's
                    // recover-and-reissue retry a no-op.
                    if translatedText.isEmpty == false {
                        memoizeTranslation(resolvedText, pair: pair, sourceText: text)
                    }
                    finishOperation(
                        id: id,
                        continuation: continuation,
                        result: resolvedText
                    )
                } catch {
                    finishOperation(id: id, continuation: continuation, error: error)
                }
            }
        }
    }

    func reset() {
        generation &+= 1
        cancelOutstandingOperations()
        currentPair = nil
        configuration = nil
        installedPairs.removeAll()
        translationMemo.removeAll()
        translationMemoOrder.removeAll()
        resetPreviews()
    }

    private func resetPreviews() {
        if #available(macOS 26.0, *) {
            for session in previewSessions.values {
                (session as? TranslationSession)?.cancel()
            }
        }
        previewSessions.removeAll()
        pairsWithoutPreviewModel.removeAll()
        pairsWithPreviews.removeAll()
        previewMemo.removeAll()
        previewMemoOrder.removeAll()
        previewTail = nil
    }

    /// The low-latency model's translation, or nil when the pair has none installed
    /// or it failed; the caller then translates as for a caption.
    private func previewTranslation(of text: String, pair: LanguagePair) async throws -> String? {
        let key = MemoKey(pair: pair, text: text)
        if let memoized = previewMemo[key] {
            return memoized
        }
        guard pairsWithoutPreviewModel.contains(pair) == false else {
            return nil
        }

        let requestGeneration = generation
        guard let translator = await previewTranslator(for: pair) else {
            return nil
        }
        guard requestGeneration == generation else {
            throw CancellationError()
        }

        let previous = previewTail
        let request = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await translator(text)
        }
        previewTail = Task { _ = try? await request.value }

        let translated: String
        do {
            translated = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Stay on the caption model for this pair rather than fail every draft.
            pairsWithoutPreviewModel.insert(pair)
            previewSessions.removeValue(forKey: pair)
            return nil
        }
        guard requestGeneration == generation else {
            throw CancellationError()
        }

        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        pairsWithPreviews.insert(pair)
        previewMemo[key] = trimmed
        previewMemoOrder.append(key)
        if previewMemoOrder.count > Self.translationMemoLimit {
            previewMemo.removeValue(forKey: previewMemoOrder.removeFirst())
        }
        return trimmed
    }

    /// Translates with the pair's low-latency session, made once it is known to be
    /// installed. Never starts a download: a model the user has not installed is
    /// simply not used.
    private func previewTranslator(for pair: LanguagePair) async -> ((String) async throws -> String)? {
        #if DEBUG
        if let previewTranslatorForTesting {
            return previewTranslatorForTesting
        }
        #endif
        guard #available(macOS 26.4, *) else {
            pairsWithoutPreviewModel.insert(pair)
            return nil
        }

        let session: TranslationSession
        if let existing = previewSessions[pair] as? TranslationSession {
            session = existing
        } else {
            let source = Locale.Language(identifier: localeIdentifier(for: pair.source))
            let target = Locale.Language(identifier: localeIdentifier(for: pair.target))
            let status = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
            guard status == .installed else {
                pairsWithoutPreviewModel.insert(pair)
                return nil
            }
            if let made = previewSessions[pair] as? TranslationSession {
                session = made
            } else {
                session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
                previewSessions[pair] = session
            }
        }
        return { text in try await session.translate(text).targetText }
    }

    /// Invalidate the current TranslationSession so SwiftUI's `.translationTask()`
    /// provides a fresh session. Use this to recover from a stuck translation state
    /// without requiring a full app restart.
    func invalidateSession() {
        configuration?.invalidate()
        activeRunnerID = nil
        signalRunnerAvailabilityWaiters()
        configuration = nil
    }

    /// Full recovery: invalidate the stuck session, reset all state, then immediately
    /// create a fresh configuration for the given language pair so a new runner can start.
    /// The old runner (stuck in session.translate()) will see a generation mismatch and exit.
    func recoverSession(source: String, target: String) {
        var oldConfig = configuration
        // Bump generation so the stuck runner exits when it finally returns
        generation &+= 1
        cancelOutstandingOperations()

        // Invalidate the old session so SwiftUI provides a fresh one
        oldConfig?.invalidate()

        // Immediately create a new configuration for the current pair
        // so SwiftUI's .translationTask() fires with a new session
        currentPair = LanguagePair(source: source, target: target)
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: localeIdentifier(for: source)),
            target: Locale.Language(identifier: localeIdentifier(for: target))
        )
    }

    private func memoizeTranslation(_ translatedText: String, pair: LanguagePair, sourceText: String) {
        let key = MemoKey(pair: pair, text: sourceText)
        if translationMemo[key] == nil {
            translationMemoOrder.append(key)
            if translationMemoOrder.count > Self.translationMemoLimit {
                let evicted = translationMemoOrder.removeFirst()
                translationMemo.removeValue(forKey: evicted)
            }
        }
        translationMemo[key] = translatedText
    }

    private func enqueue(_ operation: PendingOperation) {
        if case .translate = operation { lastRequestedAt = Date() }
        activate(pair: operation.pair)
        pendingOperations.append(operation)
        signalOperationWaiters()
    }

    private func activate(pair: LanguagePair) {
        if activeRunnerID != nil, currentPair != pair {
            return
        }

        if currentPair != pair || configuration == nil {
            currentPair = pair
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: localeIdentifier(for: pair.source)),
                target: Locale.Language(identifier: localeIdentifier(for: pair.target))
            )
            return
        }

        if activeRunnerID == nil {
            // Each TranslationSession is view-anchored and should be refreshed
            // once the previous runner has drained and exited.
            configuration?.invalidate()
        }
    }

    private func cancelOperation(id: UUID) {
        if let index = pendingOperations.firstIndex(where: { $0.id == id }) {
            let operation = pendingOperations.remove(at: index)
            cancel(operation)
            return
        }

        if activeOperationID == id {
            cancelledOperationIDs.insert(id)
        }
    }

    private func cancelOutstandingOperations() {
        cancelledOperationIDs.removeAll()
        if let activeOperationID {
            cancelledOperationIDs.insert(activeOperationID)
        }

        for operation in pendingOperations {
            cancel(operation)
        }

        pendingOperations.removeAll()
        activeRunnerID = nil
        activeOperationID = nil
        consecutiveTimeouts = 0
        signalRunnerAvailabilityWaiters()
        signalOperationWaiters()
    }

    private func cancel(_ operation: PendingOperation) {
        switch operation {
        case .prepare(_, _, _, let continuation):
            continuation.resume(throwing: CancellationError())
        case .translate(_, _, _, _, _, let continuation):
            continuation.resume(throwing: CancellationError())
        }
    }

    /// First queued operation to run: normal requests go ahead of background ones.
    private func nextPendingOperationIndex(
        where matches: (PendingOperation) -> Bool = { _ in true }
    ) -> Int? {
        pendingOperations.firstIndex { matches($0) && $0.priority == .normal }
            ?? pendingOperations.firstIndex(where: matches)
    }

    @available(macOS 15.0, *)
    private func nextOperation(
        for pair: LanguagePair,
        generation: Int,
        idleTimeout: TimeInterval
    ) async -> PendingOperation? {
        let deadline = Date().addingTimeInterval(idleTimeout)
        lastWaitTimedOut = false

        while Task.isCancelled == false {
            guard generation == self.generation else {
                return nil
            }

            if let index = nextPendingOperationIndex(where: {
                $0.pair == pair && $0.generation == generation
            }) {
                // Only background work is left for this pair: yield to another pair's
                // normal work first. The runner exit activates that pair.
                if pendingOperations[index].priority == .background,
                   pendingOperations.contains(where: { $0.priority == .normal && $0.generation == generation }) {
                    return nil
                }
                return pendingOperations.remove(at: index)
            }

            // Any remaining generation-matching operation belongs to a different
            // language pair. It can only be served after this runner exits and a
            // new session is configured, so yield instead of idling out the full
            // timeout.
            if pendingOperations.contains(where: { $0.generation == generation }) {
                return nil
            }

            if await waitForOperationSignal(for: pair, generation: generation, until: deadline) == .timedOut {
                lastWaitTimedOut = true
                return nil
            }
        }

        return nil
    }

    private func waitForRunnerAvailability(runnerID: UUID) async {
        let waiterID = UUID()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if activeRunnerID == nil || activeRunnerID == runnerID {
                    continuation.resume()
                    return
                }

                runnerAvailabilityWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeRunnerAvailabilityWaiter(id: waiterID)
            }
        }
    }

    private func resumeRunnerAvailabilityWaiter(id: UUID) {
        guard let continuation = runnerAvailabilityWaiters.removeValue(forKey: id) else {
            return
        }

        continuation.resume()
    }

    private func signalRunnerAvailabilityWaiters() {
        let waiters = runnerAvailabilityWaiters
        runnerAvailabilityWaiters.removeAll()

        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func waitForOperationSignal(
        for pair: LanguagePair,
        generation: Int,
        until deadline: Date
    ) async -> OperationWaitResult {
        guard deadline.timeIntervalSinceNow > 0 else {
            return .timedOut
        }

        let waiterID = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            let remaining = max(0, deadline.timeIntervalSinceNow)
            if remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                } catch {
                    return
                }
            }

            self?.resumeOperationWaiter(id: waiterID, result: .timedOut)
        }

        return await withTaskCancellationHandler {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<OperationWaitResult, Never>) in
                guard self.generation == generation else {
                    continuation.resume(returning: .signaled)
                    return
                }

                // Wake on any operation of this generation — foreign-pair
                // operations make the runner yield so their pair can activate.
                if self.pendingOperations.contains(where: { $0.generation == generation }) {
                    continuation.resume(returning: .signaled)
                    return
                }

                self.operationSignalWaiters[waiterID] = continuation
            }

            timeoutTask.cancel()
            return result
        } onCancel: {
            timeoutTask.cancel()
            Task { @MainActor [weak self] in
                self?.resumeOperationWaiter(id: waiterID, result: .timedOut)
            }
        }
    }

    private func resumeOperationWaiter(id: UUID, result: OperationWaitResult) {
        guard let continuation = operationSignalWaiters.removeValue(forKey: id) else {
            return
        }

        continuation.resume(returning: result)
    }

    private func signalOperationWaiters() {
        let waiters = operationSignalWaiters
        operationSignalWaiters.removeAll()

        for continuation in waiters.values {
            continuation.resume(returning: .signaled)
        }
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

        if installedPairs.contains(pair) {
            return .installed
        }

        let sourceLanguage = Locale.Language(identifier: localeIdentifier(for: pair.source))
        let targetLanguage = Locale.Language(identifier: localeIdentifier(for: pair.target))
        let availability = LanguageAvailability()
        let availabilityStatus = await availability.status(from: sourceLanguage, to: targetLanguage)

        guard availabilityStatus != .unsupported else {
            throw ServiceError.unsupportedPair(pair.source, pair.target)
        }

        if availabilityStatus == .installed {
            installedPairs.insert(pair)
        }

        return availabilityStatus
    }

    private func localeIdentifier(for languageID: String) -> String {
        localeIdentifierForLanguageID?(languageID)
            ?? LanguageCatalog.translationLocaleIdentifier(for: languageID)
    }
}
