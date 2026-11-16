import XCTest
@testable import v2s

final class JapaneseSentenceAssemblerTests: XCTestCase {
    func testLatePunctuationDoesNotBecomeItsOwnCaption() {
        var assembler = JapaneseSentenceAssembler()
        XCTAssertEqual(assembler.appendFinal("終わりました", start: 0, end: 1, finalizedEnd: 2), ["終わりました"])
        XCTAssertEqual(assembler.appendFinal("。", start: 2, end: 2.1, finalizedEnd: 3), [])
        XCTAssertEqual(assembler.appendFinal("次の話です。", start: 4, end: 5, finalizedEnd: 6), ["次の話です。"])
    }

    func testVideoDialogueDoesNotSplitAtComma() {
        var assembler = JapaneseSentenceAssembler()
        XCTAssertEqual(assembler.appendFinal("いつもごめんね。いや、俺の方こそごめん。", start: 0, end: 4.6, finalizedEnd: 6.42), [
            "いつもごめんね。", "いや、俺の方こそごめん。"
        ])
    }

    func testVideoColloquialSentenceDoesNotJoinNextSentence() {
        var assembler = JapaneseSentenceAssembler()
        let first = "もっと働きたいのに、明日急に休んでって言われちゃって。"
        XCTAssertEqual(assembler.appendFinal(first, start: 34, end: 41, finalizedEnd: 43.2), [first])
        XCTAssertEqual(assembler.appendFinal("別の仕事探した方がいいかな。", start: 43.4, end: 47, finalizedEnd: 49), ["別の仕事探した方がいいかな。"])
    }

    func testVideoNarrationEmitsCompleteSentenceBeforeHoldingOnlyItsTail() {
        var assembler = JapaneseSentenceAssembler()
        let first = "まいは幼い頃に母親を亡くし、父親も数年前に蒸発したらしい。"
        let tail = "だから幸せな家庭に憧れていて、早く子供が欲しいと"
        XCTAssertEqual(assembler.appendFinal(first + tail, start: 70.44, end: 81.8, finalizedEnd: 82.5), [first])
        XCTAssertEqual(assembler.pendingText, tail)
        XCTAssertEqual(assembler.appendFinal("結婚を機に退職して家庭に入った。", start: 82.5, end: 86, finalizedEnd: 88), [tail + "結婚を機に退職して家庭に入った。"])
    }

    func testWholeWordsAreNotMistakenForParticleSuffixes() {
        for text in ["私", "少し", "仕事", "ありがと", "こんにちは", "こんばんは", "はい", "本当ですか？", "待って。", "そういうことだから。", "そこで。", "「待って。」"] {
            XCTAssertFalse(JapaneseSentenceAssembler.isIncomplete(text), text)
        }
        for text in ["最初は水をあげすぎてしまい、", "ベランダに置いて", "来年は", "もし皆さんも興味があれば", "そこで", "は"] {
            XCTAssertTrue(JapaneseSentenceAssembler.isIncomplete(text), text)
        }
    }

    func testAudioGapPreventsConnectingUnrelatedUtterances() {
        var assembler = JapaneseSentenceAssembler()
        XCTAssertEqual(assembler.appendFinal("来年は", start: 0, end: 1, finalizedEnd: 3), [])
        XCTAssertEqual(assembler.appendFinal("こんにちは。", start: 5, end: 6, finalizedEnd: 8), ["来年は", "こんにちは。"])
    }

    func testCallbackDelayDoesNotPreventJoiningAContinuousClause() {
        var assembler = JapaneseSentenceAssembler()
        XCTAssertEqual(assembler.appendFinal("来年は", start: 0, end: 1, finalizedEnd: 1.2), [])
        XCTAssertEqual(assembler.preview(appending: "野菜を育てます"), "来年は野菜を育てます")
        XCTAssertEqual(assembler.appendFinal("野菜を育てます。", start: 1.2, end: 3, finalizedEnd: 5), ["来年は野菜を育てます。"])
    }

    func testRangeDeduplicationKeepsIntentionalRepetitions() {
        var assembler = JapaneseSentenceAssembler()
        XCTAssertEqual(assembler.appendFinal("はい。", start: 0, end: 1, finalizedEnd: 2), ["はい。"])
        XCTAssertEqual(assembler.appendFinal("はい。", start: 0, end: 1, finalizedEnd: 2), [])
        XCTAssertEqual(assembler.appendFinal("はい。", start: 3, end: 4, finalizedEnd: 5), ["はい。"])
    }

    func testOldFinalDoesNotDisplacePendingClause() {
        var assembler = JapaneseSentenceAssembler()
        _ = assembler.appendFinal("終わりました。", start: 0, end: 1, finalizedEnd: 2)
        _ = assembler.appendFinal("次は", start: 3, end: 4, finalizedEnd: 5)
        XCTAssertEqual(assembler.appendFinal("終わった。", start: 0, end: 1, finalizedEnd: 2), [])
        XCTAssertEqual(assembler.pendingText, "次は")
        XCTAssertEqual(assembler.flush(), ["次は"])
        XCTAssertEqual(assembler.flush(), [])
    }
}
