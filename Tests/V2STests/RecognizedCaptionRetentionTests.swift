import XCTest
@testable import v2s

@MainActor
final class RecognizedCaptionRetentionTests: XCTestCase {
    func testFinalizedRepeatedAndSimilarUtterancesReachTranscript() throws {
        try withModel { model in
            // Repeated calls occur at 05:05 and 05:08 in the video. A correction
            // of a number is also meaningful speech, even when most words match.
            let spoken = ["ほら", "ほら", "三時に帰ります。", "四時に帰ります。"]
            for text in spoken {
                enqueue(RecognizedSentence(text: text, promotionSegmentID: UUID(), recognitionID: UUID()), on: model)
            }
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), spoken)
        }
    }

    func testReissuedCallbackIsStillDeduplicated() throws {
        try withModel { model in
            let sentence = RecognizedSentence(text: "ほら", recognitionID: UUID())
            enqueue(sentence, on: model)
            enqueue(sentence, on: model)
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), ["ほら"])
        }
    }

    func testBurstLongerThanDisplayQueueKeepsEveryRecognizedSentence() throws {
        try withModel { model in
            let spoken = ["昨日会う約束してたのに。", "連絡が取れない。", "心配してるんだ。", "どこにいるか教えて。", "分かりません。", "私も探してるんです。"]
            for text in spoken {
                enqueue(RecognizedSentence(text: text, recognitionID: UUID()), on: model)
            }
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), spoken)
        }
    }

    func testLegacyTextDeduplicationIsUnchanged() throws {
        try withModel { model in
            for language in ["en", "zh-Hans", "es"] {
                model.stopSession()
                model.clearTranscript()
                for _ in 0..<2 {
                    model.enqueueRecognizedSentence(
                        RecognizedSentence(text: "hello"), source: .preview,
                        sourceLanguageID: language, targetLanguageID: language
                    )
                }
                XCTAssertEqual(model.transcriptEntries.map(\.sourceText), ["hello"])
            }
        }
    }

    private func enqueue(_ sentence: RecognizedSentence, on model: AppModel) {
        model.enqueueRecognizedSentence(sentence, source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja")
    }

    private func withModel(_ body: (AppModel) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v2s-retention-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        defer { model.stopSession() }
        try body(model)
    }
}
