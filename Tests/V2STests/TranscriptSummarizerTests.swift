import XCTest
@testable import v2s

final class TranscriptSummarizerTests: XCTestCase {
    func testExtractiveSummarySelectsRepeatedTopicAndKeepsTranscriptOrder() {
        let transcript = """
        The product launch was delayed by heavy rain. The cafeteria introduced a new lunch menu. \
        Engineers rescheduled the product launch for Tuesday. Safety teams approved the Tuesday launch plan.
        """

        let summary = TranscriptSummarizer.extractiveSummary(text: transcript, languageID: "en")

        XCTAssertTrue(summary.contains("product launch"))
        XCTAssertTrue(summary.contains("Tuesday"))
        XCTAssertFalse(summary.contains("cafeteria"))
        XCTAssertLessThan(
            summary.range(of: "product launch")!.lowerBound,
            summary.range(of: "Tuesday")!.lowerBound
        )
    }

    func testExtractiveSummaryReturnsShortTranscriptUnchanged() {
        let transcript = "A single complete thought."

        XCTAssertEqual(
            TranscriptSummarizer.extractiveSummary(text: transcript, languageID: "en"),
            transcript
        )
    }

    func testExtractiveSummaryPreservesSourceLanguage() {
        let transcript = """
        新产品将在周二发布。团队今天完成了安全检查。发布计划已经获得批准。天气可能影响周二的发布活动。
        """

        let summary = TranscriptSummarizer.extractiveSummary(text: transcript, languageID: "zh-Hans")

        XCTAssertFalse(summary.isEmpty)
        // CJK sentences carry their own full-width terminator, so joining them
        // must not introduce spaces that never appeared in the transcript.
        XCTAssertFalse(summary.contains(" "))
        for sentence in summary.split(separator: "\u{3002}") {
            XCTAssertTrue(transcript.contains(sentence))
        }
    }

    func testExtractiveSummarySeparatesLatinSentencesWithSpace() {
        let transcript = """
        The launch slipped a week. Rain fell hard all morning. \
        Engineers moved the launch to Tuesday. Safety approved the Tuesday launch.
        """

        let summary = TranscriptSummarizer.extractiveSummary(text: transcript, languageID: "en")

        XCTAssertTrue(summary.contains("Tuesday"))
        XCTAssertTrue(summary.contains(". "))
    }

    func testExtractiveSummaryDoesNotAddSpacesAfterFullWidthCJKTerminators() {
        let transcript = "新产品将在周二发布！团队今天完成了安全检查？发布计划已经获得批准。天气可能影响周二的发布活动！"

        let summary = TranscriptSummarizer.extractiveSummary(text: transcript, languageID: "zh-Hans")

        XCTAssertFalse(summary.contains("！ "))
        XCTAssertFalse(summary.contains("？ "))
    }
}
