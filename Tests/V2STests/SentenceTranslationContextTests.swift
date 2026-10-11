import XCTest
@testable import v2s

final class SentenceTranslationContextTests: XCTestCase {
    private let dialogue = ["ただいま。", "おかえり。"]

    func testDialogueKeepsContextWithoutCombiningDisplayedCaptions() throws {
        let id = UUID()
        let first = try XCTUnwrap(SentenceTranslationContext(sentences: dialogue, sentenceIndex: 0, draftSegmentID: id))
        let second = try XCTUnwrap(SentenceTranslationContext(sentences: dialogue, sentenceIndex: 1, draftSegmentID: id))
        XCTAssertEqual(first.sourceText, "ただいま。おかえり。")
        XCTAssertEqual(first.translatedSentence(from: "我回来了。欢迎回来。"), "我回来了。")
        XCTAssertEqual(second.translatedSentence(from: "我回来了。欢迎回来。"), "欢迎回来。")
        XCTAssertTrue(first.matchesPassage("ただいま。\nおかえり。"))
        XCTAssertFalse(first.matchesCaption("ただいま準備中です。"))
    }

    func testUnalignedTranslationIsNotAssignedToTheWrongSentence() throws {
        let context = try XCTUnwrap(SentenceTranslationContext(sentences: dialogue, sentenceIndex: 0, draftSegmentID: UUID()))
        XCTAssertNil(context.translatedSentence(from: "我回来了，欢迎回来。"))
        XCTAssertNil(context.translatedSentence(from: "我回来了。你好。欢迎回来。"))
        XCTAssertNil(context.translatedSentence(from: ""))
        XCTAssertFalse(context.matchesPassage("ただいま。おかえり。お疲れ様。"))
    }

    func testContextRequiresUnambiguousSourceBoundaries() {
        XCTAssertNil(SentenceTranslationContext(sentences: ["ただいま。"], sentenceIndex: 0, draftSegmentID: UUID()))
        XCTAssertNil(SentenceTranslationContext(sentences: dialogue, sentenceIndex: 2, draftSegmentID: UUID()))
        XCTAssertNil(SentenceTranslationContext(sentences: ["来年は", "野菜を育てます。"], sentenceIndex: 0, draftSegmentID: UUID()))
    }

    func testPromotionAcceptsOnlyInsignificantTerminalFullStopChanges() {
        for (draft, caption) in [("ただいま", "ただいま。"), ("Welcome home", "Welcome home."), ("我回来了", "我回来了。"), ("Ya llegué", "Ya llegué.")] {
            XCTAssertTrue(SentenceTranslationContext.equivalentSource(draft, caption))
        }
        for (draft, caption) in [("ただいま", "ただいま準備中です。"), ("Really?", "Really."), ("Wait...", "Wait."), ("行かない", "行く。"), ("再见，", "再见。"), ("I will return", "I will not return.")] {
            XCTAssertFalse(SentenceTranslationContext.equivalentSource(draft, caption))
        }
    }
}
