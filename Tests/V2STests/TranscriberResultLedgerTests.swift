import CoreMedia
import XCTest
@testable import v2s

final class TranscriberResultLedgerTests: XCTestCase {
    func testCommitsEveryFinalResult() {
        var ledger = TranscriberResultLedger()
        var committed: [String] = []

        committed += commit(&ledger, [("First one.", 0, 2)], range: (0, 2), finalizedThrough: 2)
        committed += commit(&ledger, [(" Second one.", 2, 4)], range: (2, 4), finalizedThrough: 4)

        XCTAssertEqual(committed, ["First one.", "Second one."])
    }

    // The volatile transcriber need not reissue a result that finalization left
    // unchanged, so none of its results commit text, final or not.
    func testDraftResultsNeverCommit() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("Hel", 0, 1)], range: (0, 1))
        XCTAssertEqual(ledger.draftText, "Hel")
        applyDraft(&ledger, [("Hello", 0, 1), (" word", 1, 2)], range: (0, 2))
        XCTAssertEqual(ledger.draftText, "Hello word")
        applyDraft(&ledger, [("Hello,", 0, 1), (" world.", 1, 2)], range: (0, 2))

        XCTAssertEqual(ledger.draftText, "Hello, world.")
        XCTAssertEqual(ledger.committedThrough, .negativeInfinity)
    }

    // A volatile result is a single run for all its text, and the final-only transcriber
    // can end the same words a little earlier.
    func testCommitClearsTheDraftTheVolatileTranscriberNeverReissued() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("Hi there", 0, 2)], range: (0, 2))
        let committed = commit(&ledger, [("Hi", 0, 0.9), (" there.", 0.9, 1.98)], range: (0, 1.98), finalizedThrough: 1.98)

        XCTAssertEqual(committed, ["Hi there."])
        XCTAssertEqual(ledger.draftText, "")
    }

    func testCommitClearsADraftWhoseLastWordFinalizationRevised() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("Hi their", 0, 2)], range: (0, 2))
        _ = commit(&ledger, [("Hi", 0, 0.9), (" there.", 0.9, 1.98)], range: (0, 1.98), finalizedThrough: 1.98)

        XCTAssertEqual(ledger.draftText, "")
    }

    // A commit can cover only the start of a volatile result, which is one piece for all
    // its text. The rest stays in the draft, and is what a failover commits.
    func testPartialCommitKeepsTheRestOfADraftPiece() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("One two three four five six seven eight", 0, 10)], range: (0, 10))
        let committed = commit(
            &ledger,
            [("One", 0, 1), (" two", 1, 2), (" three", 2, 3), (" four", 3, 4), (" five", 4, 5), (" six.", 5, 6)],
            range: (0, 6),
            finalizedThrough: 6
        )

        XCTAssertEqual(committed, ["One two three four five six."])
        XCTAssertEqual(ledger.draftText, "seven eight")
        XCTAssertEqual(ledger.removePending(), "seven eight")
    }

    func testPartialCommitKeepsTheRestWhenFinalizationRevisedWords() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("write the write address then more", 0, 6)], range: (0, 6))
        _ = commit(
            &ledger,
            [("Write", 0, 0.5), (" the", 0.5, 0.8), (" right", 0.8, 1.2), (" address.", 1.2, 4)],
            range: (0, 4),
            finalizedThrough: 4
        )

        XCTAssertEqual(ledger.draftText, "then more")
    }

    func testPartialCommitKeepsTheRestOfCJKText() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("雨が降ったのでそれで", 0, 4)], range: (0, 4))
        _ = commit(&ledger, [("雨が", 0, 1), ("降ったので。", 1, 2.5)], range: (0, 2.5), finalizedThrough: 2.5)

        XCTAssertEqual(ledger.draftText, "それで")
    }

    // The volatile transcriber's results can trail the final-only one's.
    func testDraftResultArrivingAfterAPartialCommitKeepsItsRest() {
        var ledger = TranscriberResultLedger()

        _ = commit(&ledger, [("One", 0, 1), (" two.", 1, 2)], range: (0, 2), finalizedThrough: 2)
        applyDraft(&ledger, [("One two three", 0, 3)], range: (0, 3))

        XCTAssertEqual(ledger.draftText, "three")
    }

    // However late the final result arrives, its text is what is committed, and the
    // draft moving on in the meantime commits nothing.
    func testLateFinalResultCommitsItsOwnText() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("Write the write address", 0, 2)], range: (0, 2))
        applyDraft(&ledger, [("Write the right address.", 0, 2)], range: (0, 2))
        applyDraft(&ledger, [(" Then", 2, 3)], range: (2, 3))
        XCTAssertEqual(ledger.draftText, "Write the right address. Then")

        let committed = commit(
            &ledger,
            [("Write", 0, 0.5), (" the", 0.5, 0.8), (" right", 0.8, 1.2), (" address.", 1.2, 2)],
            range: (0, 2),
            finalizedThrough: 2
        )

        XCTAssertEqual(committed, ["Write the right address."])
        XCTAssertEqual(ledger.draftText, "Then")
    }

    func testRepeatedFinalResultIsIgnored() {
        var ledger = TranscriberResultLedger()

        XCTAssertEqual(commit(&ledger, [("Done.", 0, 1)], range: (0, 1), finalizedThrough: 1), ["Done."])
        XCTAssertEqual(commit(&ledger, [("Done.", 0, 1)], range: (0, 1), finalizedThrough: 1), [])
    }

    func testFinalResultForPartOfDraftKeepsTheVolatileTail() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("One.", 0, 1), (" Two", 1, 2), (" three", 2, 3)], range: (0, 3))
        let committed = commit(&ledger, [("One.", 0, 1)], range: (0, 1), finalizedThrough: 1)

        XCTAssertEqual(committed, ["One."])
        XCTAssertEqual(ledger.draftText, "Two three")
    }

    // The volatile transcriber's results can trail the final-only one's.
    func testDraftResultForCommittedAudioIsIgnored() {
        var ledger = TranscriberResultLedger()

        _ = commit(&ledger, [("Hi there.", 0, 2)], range: (0, 2), finalizedThrough: 2)
        applyDraft(&ledger, [("Hi there.", 0, 2)], range: (0, 2))

        XCTAssertEqual(ledger.draftText, "")
    }

    func testDraftThatStartsJustBeforeTheCommitStays() {
        var ledger = TranscriberResultLedger()

        _ = commit(&ledger, [("One.", 0, 5.1)], range: (0, 5.1), finalizedThrough: 5.1)
        applyDraft(&ledger, [("Next words", 5.09, 8)], range: (5.09, 8))

        XCTAssertEqual(ledger.draftText, "Next words")
    }

    // Nothing final will come for audio before the finalization time, so volatile text
    // there was noise the final pass dropped.
    func testCommitDropsTheDraftBeforeTheFinalizationTime() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("Yes.", 0, 2)], range: (0, 2))
        applyDraft(&ledger, [(" Uh", 2, 3)], range: (2, 3))
        let committed = commit(&ledger, [("Yes.", 0, 2)], range: (0, 2), finalizedThrough: 3)

        XCTAssertEqual(committed, ["Yes."])
        XCTAssertEqual(ledger.draftText, "")
    }

    func testEmptyFinalResultClearsTheDraftItCovers() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("Um", 0, 1)], range: (0, 1))

        XCTAssertEqual(commit(&ledger, [], range: (0, 1), finalizedThrough: 1), [])
        XCTAssertEqual(ledger.draftText, "")
    }

    func testPendingResultsJoinWithSpacesExceptAroundCJK() {
        var latin = TranscriberResultLedger()
        applyDraft(&latin, [("Hello", 0, 1)], range: (0, 1))
        applyDraft(&latin, [("there", 1, 2)], range: (1, 2))
        XCTAssertEqual(latin.draftText, "Hello there")

        var japanese = TranscriberResultLedger()
        applyDraft(&japanese, [("雨が", 0, 1)], range: (0, 1))
        applyDraft(&japanese, [("降った", 1, 2)], range: (1, 2))
        XCTAssertEqual(japanese.draftText, "雨が降った")
    }

    func testRemovePendingReturnsTheDraft() {
        var ledger = TranscriberResultLedger()

        applyDraft(&ledger, [("Almost", 0, 1)], range: (0, 1))

        XCTAssertEqual(ledger.removePending(), "Almost")
        XCTAssertEqual(ledger.draftText, "")
    }

    func testUntimedRunsTakeThePrecedingRunsRange() {
        let pieces = TranscriberResultLedger.pieces(
            from: [
                (text: "¿", audioRange: nil),
                (text: "Yes", audioRange: range(0.5, 1)),
                (text: "?", audioRange: nil),
                (text: " Sure", audioRange: range(1.2, 3))
            ],
            resultRange: range(0, 2)
        )

        XCTAssertEqual(pieces.map(\.range), [range(0.5, 1), range(0.5, 1), range(0.5, 1), range(1.2, 2)])
    }

    private func applyDraft(
        _ ledger: inout TranscriberResultLedger,
        _ runs: [(String, Double, Double)],
        range resultRange: (Double, Double)
    ) {
        ledger.applyDraft(pieces(runs), range: range(resultRange.0, resultRange.1))
    }

    private func commit(
        _ ledger: inout TranscriberResultLedger,
        _ runs: [(String, Double, Double)],
        range resultRange: (Double, Double),
        finalizedThrough: Double
    ) -> [String] {
        let committed = ledger.commit(
            pieces(runs),
            range: range(resultRange.0, resultRange.1),
            resultsFinalizationTime: seconds(finalizedThrough)
        )
        return committed.map { [$0] } ?? []
    }

    private func pieces(_ runs: [(String, Double, Double)]) -> [TranscriberResultLedger.Piece] {
        runs.map { TranscriberResultLedger.Piece(text: $0.0, range: range($0.1, $0.2)) }
    }

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: seconds(start), end: seconds(end))
    }

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 1_000)
    }
}
