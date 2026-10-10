import Foundation
import XCTest
@testable import v2s

final class OverlayPreviewStateTests: XCTestCase {
    func testDraftTranslationIsOnlyReturnedForMatchingDraft() {
        let firstPromotionID = UUID()
        let secondPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.draftSourceText = "Change type is not at all."
        state.draftPromotionID = firstPromotionID
        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type is not at all.",
            promotionID: firstPromotionID
        )

        XCTAssertEqual(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: firstPromotionID
            ),
            "Old translation"
        )
        XCTAssertNil(
            state.currentDraftTranslatedText(
                for: "Okay.",
                promotionID: secondPromotionID
            )
        )
    }

    func testMismatchedDraftTranslationIsCleared() {
        let firstPromotionID = UUID()
        let secondPromotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type is not at all.",
            promotionID: firstPromotionID
        )
        state.clearDraftTranslationIfMismatched(
            sourceText: "Okay.",
            promotionID: secondPromotionID
        )

        XCTAssertNil(state.draftTranslatedText)
        XCTAssertNil(state.draftTranslationSourceText)
        XCTAssertNil(state.draftTranslationPromotionID)
    }

    func testSamePromotionDraftTranslationStaysVisibleDuringSourceUpdate() {
        let promotionID = UUID()
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type",
            promotionID: promotionID
        )
        state.clearDraftTranslationIfMismatched(
            sourceText: "Change type is not at all.",
            promotionID: promotionID
        )

        XCTAssertEqual(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            ),
            "Old translation"
        )
        XCTAssertNil(
            state.currentDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: promotionID
            )
        )
    }

    func testNilPromotionDraftTranslationStillRequiresExactSourceMatch() {
        var state = OverlayPreviewState(
            translatedText: "",
            sourceText: "",
            sourceName: "Test"
        )

        state.setDraftTranslation(
            "Old translation",
            sourceText: "Change type",
            promotionID: nil
        )

        XCTAssertNil(
            state.visibleDraftTranslatedText(
                for: "Change type is not at all.",
                promotionID: nil
            )
        )
    }
    func testPromotedTranslationCannotIncludeAnotherSentenceOrAnOldRevision() {
        let cases = [
            ("いつもごめんね。いや、俺の方こそごめん。", "いつもごめんね。"),
            ("First sentence. Second sentence.", "First sentence."),
            ("第一句话。第二句话。", "第一句话。"),
            ("Primera frase. Segunda frase.", "Primera frase."),
            ("Première phrase. Deuxième phrase.", "Première phrase."),
            ("美味しそう食べようん。", "美味しそう食べよう")
        ]
        for (draft, caption) in cases {
            let id = UUID()
            var state = OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test")
            state.setDraftTranslation("draft translation", sourceText: draft, promotionID: id)
            XCTAssertNil(state.currentDraftTranslatedText(for: caption, promotionID: id), draft)
            XCTAssertNil(state.promotableDraftTranslatedText(for: caption, promotionID: id), draft)
            state.setDraftTranslation("caption translation", sourceText: caption, promotionID: id)
            XCTAssertEqual(state.currentDraftTranslatedText(for: caption, promotionID: id), "caption translation")
        }
    }

    func testCorrectDialogueDraftIsPromotedPerSentence() throws {
        let id = UUID()
        let dialogue = ["ただいま。", "おかえり。"]
        var state = OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test")
        state.setDraftTranslation("我回来了。欢迎回来。", sourceText: dialogue.joined(), promotionID: id)
        for (index, expected) in ["我回来了。", "欢迎回来。"].enumerated() {
            let context = try XCTUnwrap(SentenceTranslationContext(sentences: dialogue, sentenceIndex: index, draftSegmentID: id))
            XCTAssertEqual(state.promotableDraftTranslatedText(for: dialogue[index], promotionID: id, context: context), expected)
            XCTAssertNil(state.promotableDraftTranslatedText(for: dialogue[index], promotionID: UUID(), context: context))
        }
    }

    func testPromotionPreservesTranslationWhenASROnlyAddsAFullStop() {
        let id = UUID()
        var state = OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test")
        state.setDraftTranslation("我回来了", sourceText: "ただいま", promotionID: id)
        XCTAssertEqual(state.promotableDraftTranslatedText(for: "ただいま。", promotionID: id), "我回来了")
        XCTAssertNil(state.promotableDraftTranslatedText(for: "ただいま準備中です。", promotionID: id))
    }

    func testPromotionRejectsUnalignedOrRevisedPassages() throws {
        let id = UUID()
        let context = try XCTUnwrap(SentenceTranslationContext(sentences: ["ただいま。", "おかえり。"], sentenceIndex: 0, draftSegmentID: id))
        var state = OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test")
        state.setDraftTranslation("我回来了，欢迎回来。", sourceText: context.sourceText, promotionID: id)
        XCTAssertNil(state.promotableDraftTranslatedText(for: "ただいま。", promotionID: id, context: context))
        state.setDraftTranslation("正在准备。欢迎回来。", sourceText: "ただいま準備中です。おかえり。", promotionID: id)
        XCTAssertNil(state.promotableDraftTranslatedText(for: "ただいま。", promotionID: id, context: context))
    }

}
