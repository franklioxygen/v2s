import Combine
import XCTest
@testable import v2s

/// A sentence leaves the draft line only by moving to the formal line. While the
/// formal line is still being read, the next utterance waits instead of hiding it.
#if DEBUG
@MainActor
final class DraftLineRetentionTests: XCTestCase {
    private let previous = "今日はいろいろなことがあって本当に疲れたけれど、みんなに会えて本当に楽しかったし、また来週も集まりたいな。"

    func testFinalizedDraftStaysVisibleUntilTheFormalLineTakesIt() async throws {
        try await withModel { model in
            showFormal(previous, on: model)
            try await waitUntil { model.overlayState?.sourceText == previous }
            let a = "ただいま。", b = "おかえり。", idA = UUID(), idB = UUID()
            model.receiveDraftForTesting(draft(a, id: idA), language: "ja", target: "ja")
            try await Task.sleep(nanoseconds: 300_000_000)
            enqueue([a], id: idA, on: model)
            model.receiveDraftForTesting(draft(b, id: idB), language: "ja", target: "ja")

            var hidden = 0
            let deadline = Date().addingTimeInterval(6)
            while model.overlayState?.sourceText != a, Date() < deadline {
                if model.overlayState?.draftSourceText != a { hidden += 1 }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(model.overlayState?.sourceText, a)
            XCTAssertEqual(hidden, 0, "The finalized sentence vanished before the formal line showed it")
            try await waitUntil { model.overlayState?.draftSourceText == b }
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [previous])
        }
    }

    func testWaitingUtteranceShortensTheFormalLine() async throws {
        try await withModel { model in
            let formal = "今日は本当に疲れたけど、みんなに会えて楽しかった。"
            showFormal(formal, on: model)
            try await waitUntil { model.overlayState?.sourceText == formal }
            let shownAt = Date()
            let a = "ただいま。", idA = UUID()
            model.receiveDraftForTesting(draft(a, id: idA), language: "ja", target: "ja")
            enqueue([a], id: idA, on: model)
            model.receiveDraftForTesting(draft("おかえり。", id: UUID()), language: "ja", target: "ja")
            try await waitUntil(timeout: 5) { model.overlayState?.sourceText == a }
            // About 2.9 s with one waiting caption; an utterance also waiting
            // for the draft line is queue pressure (about 2.1 s).
            XCTAssertLessThan(Date().timeIntervalSince(shownAt), 2.5)
        }
    }

    func testDraftLineTimeCountsWhenTheSentenceIsPromoted() async throws {
        try await withModel { model in
            showFormal(previous, on: model)
            try await waitUntil { model.overlayState?.sourceText == previous }
            let a = "明日は朝から友達の家に行って、これからのことをゆっくり相談してみようかな。"
            let b = "そうしよう。", idA = UUID(), idB = UUID()
            model.receiveDraftForTesting(draft(a, id: idA), language: "ja", target: "ja")
            try await Task.sleep(nanoseconds: 300_000_000)
            enqueue([a], id: idA, on: model)
            try await waitUntil(timeout: 5) { model.overlayState?.sourceText == a }
            let promotedAt = Date()
            model.receiveDraftForTesting(draft(b, id: idB), language: "ja", target: "ja")
            enqueue([b], id: idB, on: model)
            try await waitUntil(timeout: 5) { model.overlayState?.sourceText == b }
            // The sentence was readable on the draft line for about 3 s while the
            // previous caption finished; it keeps only the 1.6 s formal floor.
            XCTAssertLessThan(Date().timeIntervalSince(promotedAt), 2.2)
        }
    }

    func testPagesReadWhileWaitingAreNotShownAgain() async throws {
        try await withModel { model in
            showFormal(previous, on: model)
            try await waitUntil { model.overlayState?.sourceText == previous }
            let parts = ["今日は晴れです。", "公園で遊びましょう。"], idA = UUID(), idB = UUID()
            model.receiveDraftForTesting(draft(parts.joined(), id: idA), language: "ja", target: "ja")
            try await waitUntil { model.draftPresentation?.sourceText == parts[0] }
            enqueue(parts, id: idA, on: model)
            model.receiveDraftForTesting(draft("また明日。", id: idB), language: "ja", target: "ja")
            var live: [String] = []
            let observation = model.$overlayState.compactMap { $0?.sourceText }.removeDuplicates().sink { live.append($0) }
            defer { observation.cancel() }
            // The pager reaches the second sentence while the formal line is busy.
            try await waitUntil(timeout: 5) { model.draftPresentation?.sourceText == parts[1] }
            try await waitUntil(timeout: 5) { model.overlayState?.sourceText == parts[1] }
            XCTAssertFalse(live.contains(parts[0]), "A page read on the draft line must not return")
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [previous, parts[0]])
            try await waitUntil { model.overlayState?.draftSourceText == "また明日。" }
        }
    }

    private func showFormal(_ text: String, on model: AppModel) {
        model.enqueueRecognizedSentence(RecognizedSentence(text: text, recognitionID: UUID()),
                                        source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja")
    }

    private func enqueue(_ parts: [String], id: UUID, on model: AppModel) {
        for index in parts.indices {
            model.enqueueRecognizedSentence(
                RecognizedSentence(text: parts[index], promotionSegmentID: index == 0 ? id : nil,
                                   translationContext: SentenceTranslationContext(sentences: parts, sentenceIndex: index, draftSegmentID: id),
                                   recognitionID: UUID()),
                source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja")
        }
    }

    private func draft(_ text: String, id: UUID) -> DraftSegment {
        DraftSegment(segmentId: id, sourceText: text, stablePrefixLength: text.count, mutableTailText: "",
                     avgConfidence: 1, startMs: 0, lastUpdateMs: 1, silenceMs: 0, stabilityScore: 1,
                     boundaryScore: 1, chunkScore: 1, vadProbability: 1, words: [])
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "The caption pipeline did not reach the expected state")
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("draft-line-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
