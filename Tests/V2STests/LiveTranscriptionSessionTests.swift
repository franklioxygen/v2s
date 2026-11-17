import CoreMedia
import Speech
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

    @MainActor
    func testFallbackKeepsTheDraftTheTranscriberHadNotFinalized() async throws {
        // Review on PR #41: a results-stream or analyzer failure switched to the
        // legacy recognizer and dropped words already shown as the draft.
        for (text, locale) in [("We should leave before it gets dark", "en_US"),
                               ("I went to the store and", "en_US"),
                               ("Deberíamos salir antes de que oscurezca", "es_ES")] {
            let session = LiveTranscriptionSession()
            let received = expectation(description: text)
            received.assertForOverFulfill = false
            var committed: [String] = []
            session.failOverWithPendingDraftForTesting(text, localeIdentifier: locale) { sentence in
                committed.append(sentence.text)
                received.fulfill()
            }
            await fulfillment(of: [received], timeout: 2)
            XCTAssertEqual(committed.joined(separator: " "), text, "A held fragment is flushed too")
        }
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

    // English ends every complete sentence with a full stop, including ones whose last
    // word is also a conjunction.
    func testCompleteEnglishSentencesEndingOnAConjunctionWordAreNotFragments() {
        XCTAssertFalse(isFragment("I think so.", language: "en"))
        XCTAssertFalse(isFragment("I like that.", language: "en"))
        XCTAssertFalse(isFragment("I want to.", language: "en"))
    }

    func testFinalKeepsEveryWordWhenNothingIsFinalizedYet() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        let text = timed([("今日は", 0, 0.5), ("いい天気です。", 0.5, 1.4)])
        XCTAssertEqual(unfinalizedText(text, after: -.infinity), "今日はいい天気です。")
    }

    // A final can reissue words from audio an earlier final already committed.
    func testFinalDropsWordsFromAudioAlreadyFinalized() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        let text = timed([("今日は", 0, 0.5), ("いい", 0.5, 0.8), ("天気", 0.8, 1.2), ("ですね。", 1.2, 1.6)])
        XCTAssertEqual(unfinalizedText(text, after: 0.8), "天気ですね。")
        XCTAssertEqual(unfinalizedText(text, after: 1.6), "")
    }

    // The same words said again cover new audio, so they are kept.
    func testFinalKeepsARepetitionSpokenAfterTheFinalizedAudio() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        let text = timed([("はい。", 0, 0.3), ("はい。", 2.0, 2.3)])
        XCTAssertEqual(unfinalizedText(text, after: 1.0), "はい。")
    }

    func testFinalWithoutWordTimesIsKept() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        XCTAssertEqual(unfinalizedText(AttributedString("はい。"), after: 1.0), "はい。")
    }

    // speech_eval de dialogue: a final reissued 17 s of sentences committed from drafts,
    // without one comma, and eight of them were committed again.
    func testCommittedTextIsFoundDespiteARevisedComma() {
        XCTAssertEqual(pending(after: "Der Blumenstand an der alten Brücke, hat meistens die schönsten.",
                               in: "Der Blumenstand an der alten Brücke hat meistens die schönsten. Klingt gut."),
                       " Klingt gut.")
    }

    // speech_eval de dialogue: a draft respelled a committed word ("Tas" → "Tfas").
    func testCommittedTextIsFoundDespiteARespelledWord() {
        XCTAssertEqual(pending(after: "Hey, kommst du? Ich helfe ihr beim Tas.",
                               in: "Hey, kommst du? Ich helfe ihr beim Tfas. Oh nein."),
                       " Oh nein.")
    }

    func testCommittedChineseIsMatchedCharacterByCharacter() {
        XCTAssertEqual(pending(after: "我们明天去市场。", in: "我们明天去市场，你来吗？"), "你来吗？")
    }

    func testTextThatDoesNotRepeatTheCommittedWordsIsKept() {
        XCTAssertEqual(pending(after: "Das ist wirklich nett von ihr.", in: "Klingt gut, bis morgen."),
                       "Klingt gut, bis morgen.")
    }

    // A final can stop before audio already committed from a draft: the rest of the
    // committed text is what the next result repeats.
    func testFinalEndingInsideTheCommittedTextLeavesItsRest() {
        let overlap = LiveTranscriptionSession.committedOverlap(
            of: "Hola. Buenos días.", in: "Hola.", allowingUnreachedCommitted: true
        )
        XCTAssertEqual(overlap.pendingStart, "Hola.".endIndex)
        XCTAssertEqual(overlap.unreachedCommitted, "Buenos días.")
    }

    func testExactCommittedPrefixDoesNotEndInsideAWord() {
        let text = "Hey, kommst du? Ja."
        XCTAssertEqual(LiveTranscriptionSession.endOfExactPrefix("Hey, kommst du?", in: text).map { String(text[$0...]) },
                       " Ja.")
        XCTAssertNil(LiveTranscriptionSession.endOfExactPrefix("Ich helfe ihr beim Tas", in: "Ich helfe ihr beim Tasche."))
    }

    // Volatile results carry one time range for all their text, so only the text tells
    // which words were committed: speech_eval pt news committed its first sentences
    // three times when the session went by that range instead.
    @MainActor
    func testGrowingDraftDoesNotRecommitItsCommittedSentence() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        let committed = try await commits(of: [
            (volatile("A Câmara aprovou o plano.", 0, 2.0), false, 2.0),
            (volatile("A Câmara aprovou o plano. Segundo as autoridades,", 0, 4.0), false, 4.0),
            (volatile("A Câmara aprovou o plano. Segundo as autoridades, as mudanças reduzem o trânsito.", 0, 6.0), false, 6.0),
        ], locale: "pt_BR", expecting: 2)
        XCTAssertEqual(committed, ["A Câmara aprovou o plano.", "Segundo as autoridades, as mudanças reduzem o trânsito."])
    }

    @MainActor
    func testFinalDoesNotRecommitTextCommittedFromADraft() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        let draft = volatile("Das ist wirklich nett von ihr. Der Blumenstand an der alten Brücke, hat meistens die schönsten.", 0, 4.6)
        let final = timed([("Das ist wirklich nett von ihr.", 0, 1.5),
                           (" Der Blumenstand an der alten Brücke", 1.8, 3.4), (" hat meistens die schönsten.", 3.4, 4.6),
                           (" Klingt gut.", 5.0, 5.8)])
        let committed = try await commits(of: [(draft, false, 4.6), (final, true, 5.8)], locale: "de_DE", expecting: 3)
        XCTAssertEqual(committed, ["Das ist wirklich nett von ihr.",
                                   "Der Blumenstand an der alten Brücke, hat meistens die schönsten.", "Klingt gut."])
    }

    @MainActor
    func testRevisedDraftDoesNotRecommitItsCommittedText() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        let committed = try await commits(of: [
            (volatile("Hey, kommst du? Ich helfe ihr beim Tas.", 0, 3.0), false, 3.0),
            (volatile("Hey, kommst du? Ich helfe ihr beim Tfas. Oh nein.", 0, 4.2), false, 4.2),
        ], locale: "de_DE", expecting: 3)
        XCTAssertEqual(committed, ["Hey, kommst du?", "Ich helfe ihr beim Tas.", "Oh nein."])
    }

    @MainActor
    func testResultAfterAShortFinalDoesNotRecommitTheRestOfTheDraft() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        let committed = try await commits(of: [
            (volatile("Hola. Buenos días.", 0, 3.0), false, 3.0),
            (timed([("Hola.", 0.2, 0.9)]), true, 1.0),
            (volatile("Buenos días. ¿Qué tal?", 1.0, 4.5), false, 4.5),
        ], locale: "es_ES", expecting: 3)
        XCTAssertEqual(committed, ["Hola.", "Buenos días.", "¿Qué tal?"])
    }

    // From a Portuguese replay where the transcriber dropped every full stop for 28 s (#42).
    private static let runOn = "O guia local explica que o animal só sai do esconderijo quando a temperatura cai "
        + "pouco depois do pôr do sol enquanto espera os pesquisadores montam as câmeras e conferem as baterias "
        + "sabendo que talvez tenham apenas uma chance de repente um deles aponta para um tronco caído"

    func testRunOnDraftIsCutBeforeItsLastWords() throws {
        let split = try XCTUnwrap(LiveTranscriptionSession.runOnDraftSplit(in: Self.runOn))
        XCTAssertEqual(split.remainingRawText, "para um tronco caído")
        XCTAssertEqual(split.committedRawText + split.remainingRawText, Self.runOn)
    }

    func testDraftWithinTheLimitOrEndingItsSentenceIsNotCut() {
        XCTAssertNil(LiveTranscriptionSession.runOnDraftSplit(in: String(Self.runOn.prefix(150))))
        XCTAssertNil(LiveTranscriptionSession.runOnDraftSplit(in: Self.runOn + "."))
    }

    func testRunOnDraftIsCutAfterACommaNearTheEnd() throws {
        let text = Self.runOn.replacingOccurrences(of: "baterias sabendo", with: "baterias, sabendo")
        let split = try XCTUnwrap(LiveTranscriptionSession.runOnDraftSplit(in: text))
        XCTAssertTrue(split.committedRawText.hasSuffix("baterias,"), split.committedRawText)
        XCTAssertTrue(split.remainingRawText.hasPrefix(" sabendo que talvez"), split.remainingRawText)
    }

    func testOnlyTheUnfinishedSentenceCountsTowardTheLimit() throws {
        XCTAssertNil(LiveTranscriptionSession.runOnDraftSplit(in: "Eles caminham devagar entre as pedras. "
            + String(Self.runOn.prefix(120))))
        let split = try XCTUnwrap(LiveTranscriptionSession.runOnDraftSplit(in: "Eles caminham devagar. " + Self.runOn))
        XCTAssertTrue(split.committedRawText.hasPrefix("Eles caminham devagar. O guia local"))
        XCTAssertEqual(split.remainingRawText, "para um tronco caído")
    }

    func testRunOnChineseUsesItsOwnLimit() throws {
        let text = "研究人员决定沿着溪流继续前进里面空气清新湿润墙壁上覆盖着多年来动物留下的痕迹导游点亮手电筒在这里展示了几十只小蝎子紧紧抓住石头生物学家感到非常激动"
        XCTAssertNil(LiveTranscriptionSession.runOnDraftSplit(in: String(text.prefix(50))))
        let split = try XCTUnwrap(LiveTranscriptionSession.runOnDraftSplit(in: text))
        XCTAssertEqual(split.committedRawText + split.remainingRawText, text)
        XCTAssertFalse(split.remainingRawText.isEmpty)
        XCTAssertLessThan(split.remainingRawText.count, 16)
    }

    @MainActor
    func testRunOnDraftIsCommittedInPartsWithoutRepeatingWords() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechTranscriber word times need macOS 26") }
        let words = Self.runOn.split(separator: " ")
        let more = " dentro do tronco meio escondido pela sombra aparece um escorpião enorme"
        let committed = try await commits(of: [
            (volatile(words.prefix(18).joined(separator: " "), 0, 7.0), false, 7.0),
            (volatile(Self.runOn, 0, 14.0), false, 14.0),
            (volatile(Self.runOn + more, 0, 18.0), false, 18.0),
            (volatile(Self.runOn + more + ".", 0, 19.0), true, 19.0),
        ], locale: "pt_BR", expecting: 2)
        XCTAssertEqual(committed.count, 2, "Captions: \(committed)")
        XCTAssertEqual(committed.first, String(Self.runOn.dropLast(" para um tronco caído".count)))
        XCTAssertEqual(committed.last, "para um tronco caído" + more + ".")
    }

    private func pending(after committed: String, in text: String) -> String {
        let overlap = LiveTranscriptionSession.committedOverlap(of: committed, in: text, allowingUnreachedCommitted: false)
        return String(text[overlap.pendingStart...])
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

    @available(macOS 26.0, *)
    private func timed(_ words: [(text: String, start: Double, end: Double)]) -> AttributedString {
        words.reduce(into: AttributedString()) { text, word in
            var run = AttributedString(word.text)
            run.audioTimeRange = CMTimeRange(
                start: CMTime(seconds: word.start, preferredTimescale: 1_000),
                end: CMTime(seconds: word.end, preferredTimescale: 1_000)
            )
            text += run
        }
    }

    /// A volatile result: one time range for all of its text, as SpeechTranscriber reports it.
    @available(macOS 26.0, *)
    private func volatile(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
        timed([(text, start, end)])
    }

    /// Feeds results one at a time, each once the session has committed what it will, and
    /// returns every committed caption.
    @available(macOS 26.0, *)
    @MainActor
    private func commits(
        of results: [(text: AttributedString, isFinal: Bool, end: Double)], locale: String, expecting count: Int
    ) async throws -> [String] {
        let session = LiveTranscriptionSession()
        var committed: [String] = []
        for (index, result) in results.enumerated() {
            session.processModernResultForTesting(
                result.text, isFinal: result.isFinal,
                range: CMTimeRange(start: .zero, end: CMTime(seconds: result.end, preferredTimescale: 1_000)),
                localeIdentifier: locale
            ) { sentence in committed.append(sentence.text) }
            // A draft is committed by the silence timer (about 0.6 s), a final at once.
            try await Task.sleep(nanoseconds: index == results.count - 1 ? 1_200_000_000 : 1_000_000_000)
        }
        XCTAssertGreaterThanOrEqual(committed.count, count, "Captions: \(committed)")
        return committed
    }

    @available(macOS 26.0, *)
    private func unfinalizedText(_ text: AttributedString, after boundary: TimeInterval) -> String {
        String(LiveTranscriptionSession.unfinalizedSuffix(of: text, after: boundary).characters)
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
