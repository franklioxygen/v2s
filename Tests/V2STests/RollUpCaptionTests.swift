import XCTest
@testable import v2s

/// Roll-up captions: a finalized sentence takes the caption line at once and the
/// previous one rolls up into history. Nothing waits, so nothing is hidden.
#if DEBUG
@MainActor
final class RollUpCaptionTests: XCTestCase {
    private let previous = "今日はいろいろなことがあって本当に疲れたけれど、みんなに会えて本当に楽しかったし、また来週も集まりたいな。"

    func testFinalizedSentenceTakesTheCaptionLineImmediately() async throws {
        try await withModel { model in
            show(previous, on: model)
            try await waitUntil { model.overlayState?.sourceText == previous }
            let a = "ただいま。", b = "おかえり。", idA = UUID()
            model.receiveDraftForTesting(draft(a, id: idA), language: "ja", target: "ja")
            try await Task.sleep(nanoseconds: 200_000_000)
            model.enqueueRecognizedSentence(RecognizedSentence(text: a, promotionSegmentID: idA, recognitionID: UUID()),
                                            source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja")
            model.receiveDraftForTesting(draft(b, id: UUID()), language: "ja", target: "ja")
            // A is on screen at every moment: on its draft row, then the caption line.
            XCTAssertTrue(model.overlayState?.draftSourceText == a || model.overlayState?.sourceText == a)
            try await waitUntil { model.overlayState?.sourceText == a }
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [previous])
            XCTAssertEqual(model.draftRows.map(\.sourceText), [b])
        }
    }

    func testBurstAppearsAtOnceInOrder() async throws {
        try await withModel { model in
            let burst = ["ごめんうん、気にしなくていいから", "知らなくていいよ。", "本当に焦りと罪悪感だよ。", "俺は立たなくなってしまった。"]
            let start = Date()
            for text in burst { show(text, on: model) }
            try await waitUntil { model.overlayState?.sourceText == burst.last }
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "A burst must not be paced one sentence at a time")
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), Array(burst.dropLast()))
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), burst)
        }
    }

    func testNewestCaptionKeepsTheLineForItsReadingTimeWhenNothingFollows() async throws {
        try await withModel { model in
            let text = "俺なんかと結婚しない方がよかったよな。"
            show(text, on: model)
            try await waitUntil { model.overlayState?.sourceText == text }
            let shownAt = Date()
            try await waitUntil(timeout: 8) { model.overlayState?.sourceText.isEmpty == true }
            let held = Date().timeIntervalSince(shownAt)
            XCTAssertGreaterThanOrEqual(held, 1.5, "The newest caption must not fade into history at once")
            XCTAssertLessThan(held, 6.5)
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [text])
        }
    }

    func testCaptionWithoutTranslationAppearsAtOnceAndFillsIn() async throws {
        try await withModel { model in
            let first = "いつもごめんね。", second = "いや、俺の方こそごめん。"
            for text in [first, second] {
                model.enqueueRecognizedSentence(RecognizedSentence(text: text, recognitionID: UUID()),
                                                source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans")
            }
            // Neither sentence waits for a translation.
            try await waitUntil { model.overlayState?.sourceText == second }
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [first])
            let ids = model.transcriptEntries.map(\.id)
            model.finishCaptionTranslationForTesting(captionID: ids[0], text: "总是对不起。")
            model.finishCaptionTranslationForTesting(captionID: ids[1], text: "不，是我对不起。")
            XCTAssertEqual(model.overlayState?.history.first?.translatedText, "总是对不起。")
            XCTAssertEqual(model.overlayState?.translatedText, "不，是我对不起。")
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), ["总是对不起。", "不，是我对不起。"])
        }
    }

    private func show(_ text: String, on model: AppModel) {
        model.enqueueRecognizedSentence(RecognizedSentence(text: text, recognitionID: UUID()),
                                        source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja")
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roll-up-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
