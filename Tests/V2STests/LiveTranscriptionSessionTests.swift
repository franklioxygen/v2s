import CoreMedia
import XCTest
@testable import v2s

final class LiveTranscriptionSessionTests: XCTestCase {
    func testLegacyRecognitionErrorDispositionIgnoresCancellationErrors() {
        XCTAssertEqual(disposition(code: 216), .ignore)
        XCTAssertEqual(disposition(code: 301), .ignore)
    }

    func testLegacyRecognitionErrorDispositionRestartsAfterSilence() {
        XCTAssertEqual(disposition(code: 1110), .restartImmediately)
    }

    func testLegacyRecognitionErrorDispositionStopsAfterServerQuotaError() {
        XCTAssertEqual(
            disposition(
                code: 203,
                message: "Quota limit reached for resource: speech_api, actor_type: user"
            ),
            .stopAndSurface
        )
    }

    // Code 203 also covers transient faults that a restart clears, so the code alone
    // must not end the session.
    func testLegacyRecognitionErrorDispositionRetriesNonQuotaCode203() {
        XCTAssertEqual(disposition(code: 203, message: "Retry"), .retryWithBackoff)
        XCTAssertEqual(disposition(code: 203, message: "Corrupt"), .retryWithBackoff)
    }

    func testLegacyRecognitionErrorDispositionStopsOnQuotaRegardlessOfCode() {
        XCTAssertEqual(
            disposition(code: 1700, message: "Quota limit reached for resource: speech_api"),
            .stopAndSurface
        )
    }

    func testLegacyRecognitionErrorDispositionBacksOffOtherErrors() {
        XCTAssertEqual(disposition(code: 999), .retryWithBackoff)
        XCTAssertEqual(
            LiveTranscriptionSession.legacyRecognitionErrorDisposition(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet
            ),
            .retryWithBackoff
        )
    }

    // A cancellation code from another domain is a real failure, not our own teardown.
    func testLegacyRecognitionErrorDispositionDoesNotIgnoreForeignDomains() {
        XCTAssertEqual(
            LiveTranscriptionSession.legacyRecognitionErrorDisposition(
                domain: NSURLErrorDomain,
                code: 216
            ),
            .retryWithBackoff
        )
    }

    func testCompletedSentenceBoundaryEndsAtLastCompletedSentenceBeforeMoreSpeech() {
        let boundary = LiveTranscriptionSession.completedSentenceBoundary(in: [
            run("Hello", at: 0.4), run(" there.", at: 0.9),
            run(" How", at: 1.3), run(" are you?", at: 2.0),
            run(" I", at: 2.4), run(" was", at: 2.7)
        ])

        XCTAssertEqual(boundary, seconds(2.0))
    }

    // A draft that ends on its terminator is left to the pause timers, which finalize
    // everything taken so far.
    func testCompletedSentenceBoundaryIgnoresTextEndingOnSentence() {
        XCTAssertNil(LiveTranscriptionSession.completedSentenceBoundary(in: [
            run("Hello", at: 0.4), run(" there.", at: 0.9)
        ]))
    }

    func testCompletedSentenceBoundaryIgnoresTextWithoutCompletedSentence() {
        XCTAssertNil(LiveTranscriptionSession.completedSentenceBoundary(in: [
            run("I", at: 0.2), run(" think", at: 0.5), run(" that", at: 0.8)
        ]))
    }

    func testCompletedSentenceBoundaryDoesNotSplitAfterTitleAbbreviation() {
        XCTAssertNil(LiveTranscriptionSession.completedSentenceBoundary(in: [
            run("Ask", at: 0.3), run(" Mr.", at: 0.7), run(" Smith", at: 1.2)
        ]))
    }

    // Punctuation can come as its own run with no audio range; the sentence then ends
    // with the last word that has one.
    func testCompletedSentenceBoundaryUsesLastTimedRunForBarePunctuation() {
        let boundary = LiveTranscriptionSession.completedSentenceBoundary(in: [
            run("Yes", at: 0.5), (text: "。", audioEnd: nil), run("それで", at: 1.4)
        ])

        XCTAssertEqual(boundary, seconds(0.5))
    }

    func testModernVADFinalizationDefersDanglingEnglishConjunction() {
        XCTAssertTrue(defersVADFinalization("I went to the store and", language: "en"))
        XCTAssertTrue(defersVADFinalization("because", language: "en"))
        XCTAssertFalse(defersVADFinalization("I went to the store", language: "en"))
        XCTAssertFalse(defersVADFinalization("Brand new.", language: "en"))
    }

    func testModernVADFinalizationDefersJapaneseParticle() {
        XCTAssertTrue(defersVADFinalization("雨が降ったので", language: "ja"))
        XCTAssertFalse(defersVADFinalization("雨が降りました。", language: "ja"))
    }

    func testModernVADFinalizationDefersTitleAbbreviationInAnyLanguage() {
        XCTAssertTrue(defersVADFinalization("Ask Dr.", language: nil))
    }

    func testModernVADFinalizationDoesNotDeferEmptyDraft() {
        XCTAssertFalse(defersVADFinalization("  ", language: "en"))
    }

    private func run(_ text: String, at audioEndSeconds: Double) -> (text: String, audioEnd: CMTime?) {
        (text: text, audioEnd: seconds(audioEndSeconds))
    }

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 1_000)
    }

    private func defersVADFinalization(_ text: String, language: String?) -> Bool {
        LiveTranscriptionSession.shouldDeferModernVADFinalization(of: text, languageCode: language)
    }

    private func disposition(
        code: Int,
        message: String = ""
    ) -> LiveTranscriptionSession.LegacyRecognitionErrorDisposition {
        LiveTranscriptionSession.legacyRecognitionErrorDisposition(
            domain: "kAFAssistantErrorDomain",
            code: code,
            message: message
        )
    }
}
