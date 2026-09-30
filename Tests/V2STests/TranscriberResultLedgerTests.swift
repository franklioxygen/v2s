import CoreMedia
import XCTest
@testable import v2s

final class TranscriberResultLedgerTests: XCTestCase {
    // The docs let a volatile result be finalized by a later result's
    // resultsFinalizationTime without ever being reissued as final.
    func testCommitsResultsFinalizedWithoutBeingReissued() {
        var ledger = TranscriberResultLedger()
        var committed: [String] = []

        committed += apply(&ledger, [("First one.", 0, 2)], range: (0, 2), finalizedThrough: 0)
        committed += apply(&ledger, [(" Second one.", 2, 4)], range: (2, 4), finalizedThrough: 2)
        committed += apply(&ledger, [(" Third one.", 4, 6)], range: (4, 6), finalizedThrough: 6)

        XCTAssertEqual(committed, ["First one.", "Second one. Third one."])
        XCTAssertEqual(ledger.draftText, "")
    }

    func testRevisedVolatileResultIsReplacedNotRepeated() {
        var ledger = TranscriberResultLedger()
        var committed: [String] = []

        committed += apply(&ledger, [("Hel", 0, 1)], range: (0, 1), finalizedThrough: 0)
        XCTAssertEqual(ledger.draftText, "Hel")
        committed += apply(&ledger, [("Hello", 0, 1), (" word", 1, 2)], range: (0, 2), finalizedThrough: 0)
        XCTAssertEqual(ledger.draftText, "Hello word")
        committed += apply(&ledger, [("Hello,", 0, 1), (" world.", 1, 2)], range: (0, 2), finalizedThrough: 2)

        XCTAssertEqual(committed, ["Hello, world."])
        XCTAssertEqual(ledger.draftText, "")
    }

    func testRepeatedFinalResultIsIgnored() {
        var ledger = TranscriberResultLedger()

        XCTAssertEqual(apply(&ledger, [("Done.", 0, 1)], range: (0, 1), finalizedThrough: 1), ["Done."])
        XCTAssertEqual(apply(&ledger, [("Done.", 0, 1)], range: (0, 1), finalizedThrough: 1), [])
    }

    func testFinalResultForPartOfDraftKeepsTheVolatileTail() {
        var ledger = TranscriberResultLedger()

        _ = apply(&ledger, [("One.", 0, 1), (" Two", 1, 2), (" three", 2, 3)], range: (0, 3), finalizedThrough: 0)
        let committed = apply(&ledger, [("One.", 0, 1)], range: (0, 1), finalizedThrough: 1)

        XCTAssertEqual(committed, ["One."])
        XCTAssertEqual(ledger.draftText, "Two three")
    }

    // Finalization that leaves a draft unchanged need not reissue it; the volatile
    // range moving past it is then the only sign it is final.
    func testFinalizingWithoutAResultCommitsTheUnchangedDraft() {
        var ledger = TranscriberResultLedger()

        _ = apply(&ledger, [("Hi", 0, 1), (" there", 1, 2)], range: (0, 2), finalizedThrough: 0)

        XCTAssertEqual(ledger.finalize(through: seconds(2)), "Hi there")
        XCTAssertEqual(ledger.draftText, "")
    }

    func testFinalizingStopsAtTheGivenTime() {
        var ledger = TranscriberResultLedger()

        _ = apply(&ledger, [("One.", 0, 1), (" Two", 1, 2)], range: (0, 2), finalizedThrough: 0)

        XCTAssertEqual(ledger.finalize(through: seconds(1)), "One.")
        XCTAssertEqual(ledger.draftText, "Two")
        XCTAssertNil(ledger.finalize(through: seconds(1)))
    }

    func testResultAfterFinalizationDoesNotRepeatFinalText() {
        var ledger = TranscriberResultLedger()

        _ = apply(&ledger, [("Hi", 0, 1), (" there", 1, 2)], range: (0, 2), finalizedThrough: 0)
        _ = ledger.finalize(through: seconds(2))
        let committed = apply(&ledger, [("Hi there", 0, 2)], range: (0, 2), finalizedThrough: 2)

        XCTAssertEqual(committed, [])
    }

    func testPendingResultsJoinWithSpacesExceptAroundCJK() {
        var latin = TranscriberResultLedger()
        _ = apply(&latin, [("Hello", 0, 1)], range: (0, 1), finalizedThrough: 0)
        _ = apply(&latin, [("there", 1, 2)], range: (1, 2), finalizedThrough: 0)
        XCTAssertEqual(latin.draftText, "Hello there")

        var japanese = TranscriberResultLedger()
        _ = apply(&japanese, [("雨が", 0, 1)], range: (0, 1), finalizedThrough: 0)
        _ = apply(&japanese, [("降った", 1, 2)], range: (1, 2), finalizedThrough: 0)
        XCTAssertEqual(japanese.draftText, "雨が降った")
    }

    func testRemovePendingReturnsTheDraft() {
        var ledger = TranscriberResultLedger()

        _ = apply(&ledger, [("Almost", 0, 1)], range: (0, 1), finalizedThrough: 0)

        XCTAssertEqual(ledger.removePending(), "Almost")
        XCTAssertEqual(ledger.draftText, "")
        XCTAssertNil(ledger.pendingEnd)
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

    private func apply(
        _ ledger: inout TranscriberResultLedger,
        _ runs: [(String, Double, Double)],
        range resultRange: (Double, Double),
        finalizedThrough: Double
    ) -> [String] {
        let pieces = runs.map { TranscriberResultLedger.Piece(text: $0.0, range: range($0.1, $0.2)) }
        let finalized = ledger.apply(
            pieces,
            range: range(resultRange.0, resultRange.1),
            resultsFinalizationTime: seconds(finalizedThrough)
        )
        return finalized.map { [$0] } ?? []
    }

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: seconds(start), end: seconds(end))
    }

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 1_000)
    }
}
