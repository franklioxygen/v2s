import Foundation
import XCTest
@testable import v2s

/// The result sequences here follow what the on-device SFSpeechRecognizer sent for a
/// real microphone recording: untimed partials, punctuation segments that come and go,
/// one timed result at the end of each utterance, and text that starts over after a
/// pause without isFinal.
final class LegacyCommitTrackerTests: XCTestCase {
    /// One segment per space-separated token. Untimed unless `timedFrom` is given.
    private func segments(_ text: String, timedFrom start: TimeInterval? = nil) -> [LegacyTranscriptSegment] {
        var time = start ?? 0
        return text.split(separator: " ").map { token in
            guard start != nil else {
                return LegacyTranscriptSegment(text: String(token), timestamp: 0, duration: 0)
            }
            defer { time += 0.35 }
            return LegacyTranscriptSegment(text: String(token), timestamp: time, duration: 0.3)
        }
    }

    func testUntimedResultsNeverMarkNewWordsCommitted() {
        var tracker = LegacyCommitTracker()
        tracker.markCommitted(through: 5, of: segments("in many ways he argued ."))

        tracker.align(to: segments("in many ways he argued . he nonetheless maintains"))

        XCTAssertEqual(tracker.committedSegmentCount, 6)
    }

    func testPunctuationThatComesAndGoesKeepsTheBoundary() {
        var tracker = LegacyCommitTracker()
        tracker.markCommitted(through: 6, of: segments("is the leader of this process ."))

        XCTAssertFalse(tracker.align(to: segments("is the leader of this process in many")))
        XCTAssertEqual(tracker.committedSegmentCount, 6)

        XCTAssertFalse(tracker.align(to: segments("is the leader of this process . in many ways")))
        XCTAssertEqual(tracker.committedSegmentCount, 7)
    }

    func testRevisedCommittedWordsAreNotCommittedAgain() {
        var tracker = LegacyCommitTracker()
        tracker.markCommitted(through: 5, of: segments("in many ways he argued ."))

        tracker.align(to: segments("in many ways he argues . that he"))

        XCTAssertEqual(tracker.committedSegmentCount, 6)
    }

    func testATimedResultAfterUntimedCommitsKeepsTheBoundary() {
        var tracker = LegacyCommitTracker()
        tracker.markCommitted(through: 5, of: segments("this adds to his comments ."))

        tracker.align(to: segments("this adds to his comments . on nationalism", timedFrom: 9.8))

        XCTAssertEqual(tracker.committedSegmentCount, 6)
    }

    func testTimedResultsAlignByAudioTime() {
        var tracker = LegacyCommitTracker()
        let first = segments("we flew to new york city", timedFrom: 0)
        tracker.markCommitted(through: 4, of: first)

        // The recognizer hears "new york" again as one word over the same audio;
        // counting words would now take "city" as committed too.
        var revised = Array(first.prefix(3))
        revised.append(LegacyTranscriptSegment(text: "Newark", timestamp: first[3].timestamp, duration: 0.65))
        revised.append(first[5])
        let changed = tracker.align(to: revised)

        XCTAssertEqual(tracker.committedSegmentCount, 4)
        XCTAssertEqual(tracker.committedWordCount, 4)
        XCTAssertTrue(changed)
    }

    func testAMergedSegmentCountsAsItsWords() {
        var tracker = LegacyCommitTracker()
        tracker.markCommitted(through: 3, of: segments("a belarusian of russian"))

        var merged = [LegacyTranscriptSegment(text: "A Belarusian", timestamp: 0, duration: 0)]
        merged += segments("of russian belarusian academic")
        tracker.align(to: merged)

        XCTAssertEqual(tracker.committedSegmentCount, 3)
    }

    func testChineseTextSplitDifferentlyKeepsTheBoundary() {
        var tracker = LegacyCommitTracker()
        tracker.markCommitted(through: 1, of: segments("那我们 明天早上"))

        tracker.align(to: segments("那 我们 明天 早上 去 市场 吧"))

        XCTAssertEqual(tracker.committedSegmentCount, 4)
        XCTAssertEqual(LegacyTranscriptSegment(text: "Belarus's 市场", timestamp: 0, duration: 0).words,
                       ["belaruss", "市", "场"])
    }

    func testCommittedTextEndingInsideAMergedSegmentKeepsTheRestPending() {
        var tracker = LegacyCommitTracker()
        tracker.markCommitted(through: 0, of: segments("那我们"))

        let merged = segments("那我们明天 早上")
        tracker.align(to: merged)

        XCTAssertEqual(tracker.committedSegmentCount, 0)
        XCTAssertEqual(tracker.committedWordsInNextSegment, 3)
        XCTAssertEqual(merged[0].utf16Offset(afterWords: 3), 3)

        tracker.markCommitted(through: 3, of: segments("we flew to new"))
        var english = segments("we flew to")
        english.append(LegacyTranscriptSegment(text: "New York", timestamp: 0, duration: 0))
        english += segments("city")
        tracker.align(to: english)

        XCTAssertEqual(tracker.committedSegmentCount, 3)
        XCTAssertEqual(tracker.committedWordsInNextSegment, 1)
        XCTAssertEqual(english[3].utf16Offset(afterWords: 1), 4)
    }

    func testWordOffsetsFollowTheWordCount() {
        let segment = LegacyTranscriptSegment(text: "Belarus's 市场", timestamp: 0, duration: 0)

        XCTAssertEqual(segment.utf16Offset(afterWords: 0), 0)
        XCTAssertEqual(segment.utf16Offset(afterWords: 1), 10)
        XCTAssertEqual(segment.utf16Offset(afterWords: 2), 11)
        XCTAssertEqual(segment.utf16Offset(afterWords: 3), 12)
    }

    func testNothingCommittedLeavesTheWholeResultPending() {
        var tracker = LegacyCommitTracker()

        tracker.align(to: segments(", national protector"))

        XCTAssertEqual(tracker.committedSegmentCount, 0)
    }

    func testTextThatStartsOverIsANewUtterance() {
        var tracker = LegacyCommitTracker()
        let previous = segments("this adds to his comments on belarusian nationalism in which lukashenko and belarusian")
        tracker.markCommitted(through: 4, of: previous)

        XCTAssertTrue(tracker.startsNewUtterance(previous: previous, current: segments("National")))
        XCTAssertTrue(tracker.startsNewUtterance(previous: previous, current: segments("Belarus ,")))
    }

    func testANewUtteranceThatOpensWithTheSameWordIsDetected() {
        let tracker = LegacyCommitTracker()
        let previous = segments("the success of lukashenko stems from the unfinished nation")

        XCTAssertTrue(tracker.startsNewUtterance(previous: previous, current: segments("The")))
    }

    func testRevisionsAreNotNewUtterances() {
        var tracker = LegacyCommitTracker()
        let previous = segments("is the leader of this process .")
        tracker.markCommitted(through: 2, of: previous)

        XCTAssertFalse(tracker.startsNewUtterance(previous: previous, current: segments("is the leader of this process")))
        XCTAssertFalse(tracker.startsNewUtterance(previous: previous, current: segments("is the leader of this")))
        XCTAssertFalse(tracker.startsNewUtterance(previous: previous, current: segments("is the leader of this progress .")))
        XCTAssertFalse(tracker.startsNewUtterance(previous: previous, current: segments("it's the leader of this")))
    }

    func testAResultThatDropsTheOpeningWordsIsNotANewUtterance() {
        var tracker = LegacyCommitTracker()
        let previous = segments("have of russian belarusian academic only from before he argues")
        tracker.markCommitted(through: 9, of: previous)

        // The utterance's closing result had fewer words than were committed.
        let current = segments("russian belarusian academic only from before he argues", timedFrom: 27)
        XCTAssertFalse(tracker.startsNewUtterance(previous: previous, current: current))

        var merged = [LegacyTranscriptSegment(text: "A Belarusian", timestamp: 26.2, duration: 0.6)]
        merged += segments("of russian belarusian", timedFrom: 27)
        XCTAssertFalse(tracker.startsNewUtterance(previous: segments("a belarusian of russian belarusian academic"),
                                                  current: merged))
    }

    func testDifferentWordsAfterAShortUtteranceCommittedInFullStartANewOne() {
        var tracker = LegacyCommitTracker()
        let previous = segments("Hello")
        tracker.markCommitted(through: 0, of: previous)

        XCTAssertTrue(tracker.startsNewUtterance(previous: previous, current: segments("Good")))
        XCTAssertTrue(tracker.startsNewUtterance(previous: previous, current: segments("Good morning")))
        XCTAssertFalse(tracker.startsNewUtterance(previous: previous, current: segments("Hello there")))
    }

    func testATimedRevisionOverCommittedAudioIsNotANewUtterance() {
        var tracker = LegacyCommitTracker()
        let previous = segments("turn on the lights", timedFrom: 5)
        tracker.markCommitted(through: 3, of: previous)

        let revision = segments("turn off lights", timedFrom: 5)
        XCTAssertFalse(tracker.startsNewUtterance(previous: previous, current: revision))
        tracker.align(to: revision)
        XCTAssertEqual(tracker.committedSegmentCount, 3)

        XCTAssertTrue(tracker.startsNewUtterance(previous: previous, current: segments("Okay", timedFrom: 8)))
    }

    func testAnEarlyRevisionOfTheOpeningWordsIsNotANewUtterance() {
        let tracker = LegacyCommitTracker()

        XCTAssertFalse(tracker.startsNewUtterance(previous: segments("in a"), current: segments("Ina")))
    }
}
