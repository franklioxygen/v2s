import Foundation
import XCTest
@testable import v2s

final class SentenceBoundaryHeuristicsTests: XCTestCase {
    func testSentenceRangesKeepSingleLetterNameInitialAttached() {
        let text = "Defense Secretary P. Texeth, with a warning to Iran, told troops about the ceasefire."
        let ranges = SentenceBoundaryHeuristics.sentenceRanges(in: text as NSString)

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((text as NSString).substring(with: ranges[0]), text)
    }

    func testSentenceRangesKeepTitleAndSurnameAttached() {
        let text = "Sen. Warner said the vote would proceed. Markets reacted later."
        let ranges = SentenceBoundaryHeuristics.sentenceRanges(in: text as NSString)
        let sentences = ranges.map {
            (text as NSString).substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0], "Sen. Warner said the vote would proceed.")
        XCTAssertEqual(sentences[1], "Markets reacted later.")
    }

    func testSentenceRangesKeepInitialismAndFollowingWordTogether() {
        let text = "The U.S. military responded quickly."
        let ranges = SentenceBoundaryHeuristics.sentenceRanges(in: text as NSString)

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((text as NSString).substring(with: ranges[0]), text)
    }

    func testLikelySentenceTerminatorRejectsDanglingNameInitial() {
        XCTAssertFalse(SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: "Defense Secretary P."))
    }

    func testLikelySentenceTerminatorStillAcceptsRealSentenceEnd() {
        XCTAssertTrue(SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: "This is the end."))
    }
}
