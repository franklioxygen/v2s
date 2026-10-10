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

    func testJapaneseClauseEndingOnACommaIsAFragment() {
        XCTAssertTrue(isFragment("最初は水をあげすぎてしまい、", language: "ja"))
        XCTAssertTrue(isFragment("そこで近所の園芸店の方に相談したところ、", language: "ja"))
    }

    func testJapaneseClauseEndingOnAParticleIsAFragment() {
        XCTAssertTrue(isFragment("ベランダに小さなプランターをいくつか置いて", language: "ja"))
        XCTAssertTrue(isFragment("来年は", language: "ja"))
        XCTAssertTrue(isFragment("もし皆さんも興味があれば。", language: "ja"))
    }

    // The transcriber can close a lone connective or particle with a full stop at a pause.
    func testJapaneseConnectiveOrParticleClosedByAPauseIsAFragment() {
        XCTAssertTrue(isFragment("そこで。", language: "ja"))
        XCTAssertTrue(isFragment("ただ。", language: "ja"))
        XCTAssertTrue(isFragment("は。", language: "ja"))
        XCTAssertTrue(isFragment("も", language: "ja"))
    }

    func testCompleteJapaneseSentencesAreNotFragments() {
        XCTAssertFalse(isFragment("トマトとバジルを育て始めました。", language: "ja"))
        XCTAssertFalse(isFragment("皆さん、こんにちは。", language: "ja"))
        XCTAssertFalse(isFragment("こんにちは", language: "ja"))
        XCTAssertFalse(isFragment("はい", language: "ja"))
        XCTAssertFalse(isFragment("本当ですか？", language: "ja"))
    }

    func testEnglishClauseEndingOnAConjunctionIsAFragment() {
        XCTAssertTrue(isFragment("I went to the store and", language: "en"))
        XCTAssertTrue(isFragment("Over the last decade,", language: "en"))
        XCTAssertFalse(isFragment("I went to the store.", language: "en"))
    }

    func testOtherLanguagesOnlyTreatACommaAsAFragmentEnding() {
        XCTAssertTrue(isFragment("我们先去，", language: "zh"))
        XCTAssertFalse(isFragment("我们先去", language: "zh"))
    }

    func testHeldFragmentJoinsTheNextTextWithoutItsPauseFullStop() {
        XCTAssertEqual(join("そこで。", "近所の方に相談しました。", language: "ja"), "そこで近所の方に相談しました。")
        XCTAssertEqual(join("最初は水をあげすぎてしまい、", "葉っぱが黄色くなりました。", language: "ja"), "最初は水をあげすぎてしまい、葉っぱが黄色くなりました。")
        XCTAssertEqual(join("I went to the store and", "bought milk.", language: "en"), "I went to the store and bought milk.")
    }

    func testHeldFragmentIsNotRepeatedWhenTheNextTextAlreadyOpensWithIt() {
        XCTAssertEqual(join("ただ。", "ただ台風の時期には大変でした。", language: "ja"), "ただ台風の時期には大変でした。")
    }

    func testHeldFragmentJoinKeepsEitherSideWhenTheOtherIsEmpty() {
        XCTAssertEqual(join("", "近所の方に相談しました。", language: "ja"), "近所の方に相談しました。")
        XCTAssertEqual(join("そこで。", "  ", language: "ja"), "そこで。")
    }

    // A reissued sentence often differs only in kana or a word, and must not be joined
    // to a held fragment.
    func testReissuedSentenceIsNearlyTheSameAsTheCommittedOne() {
        XCTAssertTrue(nearlySame("きゅうりやナスにも挑戦してみたいと考えています。", "きゅうりやなスにも挑戦してみたいと考えています。"))
        XCTAssertTrue(nearlySame("スーパーで買うものよりもずっと甘く感じます。", "スーパーで買うものよりもずっと甘く感じます"))
        XCTAssertFalse(nearlySame("スーパーで買うものよりもずっと甘く感じます。", "台風の時期にはとても大変でした。"))
        XCTAssertFalse(nearlySame("はい。", "いいえ。"))
    }

    private func nearlySame(_ lhs: String, _ rhs: String) -> Bool {
        LiveTranscriptionSession.isNearlySameSentence(
            LiveTranscriptionSession.comparableModernSentence(lhs),
            LiveTranscriptionSession.comparableModernSentence(rhs)
        )
    }

    private func isFragment(_ text: String, language: String?) -> Bool {
        LiveTranscriptionSession.isModernSentenceFragment(text, languageCode: language)
    }

    private func join(_ fragment: String, _ text: String, language: String?) -> String {
        LiveTranscriptionSession.joiningHeldFragment(fragment, to: text, languageCode: language)
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
