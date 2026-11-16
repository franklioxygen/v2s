import Combine
import XCTest
@testable import v2s

final class DraftSentencePagerTests: XCTestCase {
    func testOnlyCompleteSentenceBoundariesBecomePagesAcrossLanguages() {
        for (text, expected) in [
            ("別の仕事探した方がいいかな。明日友達に相談してみようかな。", ["別の仕事探した方がいいかな。", "明日友達に相談してみようかな。"]),
            ("今日は雨ですが、午後は晴れると思います。", ["今日は雨ですが、午後は晴れると思います。"]),
            ("Dr. Smith paid 3.14 dollars. Then he left.", ["Dr. Smith paid 3.14 dollars.", "Then he left."]),
            ("今天下雨了。我们明天再去。", ["今天下雨了。", "我们明天再去。"]),
            ("Ya llegué. ¿Cómo estás?", ["Ya llegué.", "¿Cómo estás?"]),
            ("The result is 3.14, but we need more data", ["The result is 3.14, but we need more data"])
        ] {
            XCTAssertEqual(DraftSentencePager.sentences(in: text), expected, text)
        }
    }

    func testGrowingTailDoesNotRestartFirstPageOrSkipMiddlePage() {
        var pager = DraftSentencePager()
        let id = UUID(), start = Date()
        let first = page("First sentence.", "第一句话。")
        update(&pager, id, [first, page("Second", "第二")], start)
        update(&pager, id, [first, page("Second sentence.", "第二句话。"), page("Third.", "第三句。")], start.addingTimeInterval(1.5))
        XCTAssertEqual(pager.current, first)
        update(&pager, id, [first, page("Second sentence.", "第二句话。"), page("Third.", "第三句。")], start.addingTimeInterval(2.1))
        XCTAssertEqual(pager.current?.sourceText, "Second sentence.")
        // A delayed timer tick advances only one sentence, never straight to the end.
        update(&pager, id, [first, page("Second sentence.", "第二句话。"), page("Third.", "第三句。")], start.addingTimeInterval(20))
        XCTAssertEqual(pager.current?.sourceText, "Third.")
    }

    func testMissingNextTranslationKeepsReadablePageAndCorrectionGetsFreshTime() {
        var pager = DraftSentencePager()
        let id = UUID(), start = Date()
        let first = page("First.", "第一句。")
        update(&pager, id, [first, page("Second.", "")], start)
        update(&pager, id, [first, page("Second.", "")], start.addingTimeInterval(10))
        XCTAssertEqual(pager.current, first)
        update(&pager, id, [page("First.", "修正后的第一句。"), page("Second.", "第二句。")], start.addingTimeInterval(10.1))
        XCTAssertEqual(pager.index, 0)
        update(&pager, id, [page("First.", "修正后的第一句。"), page("Second.", "第二句。")], start.addingTimeInterval(11.9))
        XCTAssertEqual(pager.index, 0)
        update(&pager, id, [page("First.", "修正后的第一句。"), page("Second.", "第二句。")], start.addingTimeInterval(12.2))
        XCTAssertEqual(pager.index, 1)
    }

    func testEarlierSourceRevisionAndNewUtteranceResetToCorrectSentence() {
        var pager = DraftSentencePager()
        let id = UUID(), start = Date()
        let pages = [page("First.", "第一句。"), page("Second.", "第二句。")]
        update(&pager, id, pages, start)
        update(&pager, id, pages, start.addingTimeInterval(3))
        XCTAssertEqual(pager.index, 1)
        update(&pager, id, [page("Corrected first.", "更正第一句。"), pages[1]], start.addingTimeInterval(4))
        XCTAssertEqual(pager.index, 0)
        update(&pager, UUID(), pages, start.addingTimeInterval(5))
        XCTAssertEqual(pager.current, pages[0])
    }

    func testRepeatedSentencesHaveSeparateReadingIntervals() {
        var pager = DraftSentencePager()
        let id = UUID(), start = Date()
        let pages = [page("はい。", "好。"), page("はい。", "好。"), page("ありがとう。", "谢谢。")]
        update(&pager, id, pages, start)
        update(&pager, id, pages, start.addingTimeInterval(2.1))
        XCTAssertEqual(pager.index, 1)
        update(&pager, id, pages, start.addingTimeInterval(3))
        XCTAssertEqual(pager.index, 1)
        update(&pager, id, pages, start.addingTimeInterval(4.2))
        XCTAssertEqual(pager.index, 2)
    }

    private func page(_ source: String, _ translated: String) -> OverlayDraftPage {
        .init(sourceText: source, translatedText: translated, stablePrefixLength: source.count)
    }

    private func update(_ pager: inout DraftSentencePager, _ id: UUID, _ pages: [OverlayDraftPage], _ now: Date) {
        pager.update(id: id, pages: pages, paginate: true, showsSource: true, showsTranslation: true, now: now) { _ in 2 }
    }
}

#if DEBUG
@MainActor
final class DraftSentencePagingTests: XCTestCase {
    func testRecordedLongDraftDisplaysOneSentenceAndPreservesFullPassage() async throws {
        try await withModel { model in
            let source = "別の仕事探した方がいいかな。明日友達に相談してみようかな。"
            let translated = "要不要找一份别的工作呢。明天找朋友商量一下吧。"
            install(source, translated, id: UUID(), on: model)
            XCTAssertEqual(model.draftPresentation?.sourceText, "別の仕事探した方がいいかな。")
            XCTAssertEqual(model.draftPresentation?.translatedText, "要不要找一份别的工作呢。")
            XCTAssertEqual(model.overlayState?.draftSourceText, source)
            XCTAssertEqual(model.overlayState?.draftTranslatedText, translated)
            XCTAssertTrue(model.transcriptEntries.isEmpty, "A volatile page must not finalize ASR")
            try await Task.sleep(nanoseconds: 1_300_000_000)
            XCTAssertEqual(model.draftPresentation?.sourceText, "別の仕事探した方がいいかな。")
            try await waitUntil { model.draftPresentation?.sourceText == "明日友達に相談してみようかな。" }
            XCTAssertEqual(model.draftPresentation?.translatedText, "明天找朋友商量一下吧。")
        }
    }

    func testShortSentencesAreShownOneAtATime() async throws {
        try await withModel { model in
            install("ただいま。おかえり", "我回来了。欢迎回来", id: UUID(), on: model)
            XCTAssertEqual(model.draftPresentation?.sourceText, "ただいま。")
            XCTAssertEqual(model.draftPresentation?.translatedText, "我回来了。")
            install("いつもごめんね。いや、俺の方こそごめん。", "总是对不起。不，是我对不起。", id: UUID(), on: model)
            XCTAssertEqual(model.draftPresentation?.sourceText, "いつもごめんね。")
            XCTAssertEqual(model.draftPresentation?.translatedText, "总是对不起。")
            try await waitUntil { model.draftPresentation?.sourceText == "いや、俺の方こそごめん。" }
            XCTAssertEqual(SentenceTranslationContext.splitSentences(model.draftPresentation?.translatedText ?? "").count, 1)
        }
    }

    func testFirstSentenceKeepsReadingTimeFromBeforeTheSecondArrived() async throws {
        try await withModel { model in
            let id = UUID()
            install("ただいま。", "我回来了。", id: id, on: model)
            XCTAssertNil(model.draftPresentation)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let grewAt = Date()
            install("ただいま。おかえり。", "我回来了。欢迎回来。", id: id, on: model)
            XCTAssertEqual(model.draftPresentation?.sourceText, "ただいま。")
            try await waitUntil { model.draftPresentation?.sourceText == "おかえり。" }
            // 1.5 s of the 2 s page were already read as the whole draft.
            XCTAssertLessThan(Date().timeIntervalSince(grewAt), 1.0)
        }
    }

    func testRecordedDialogueKeepsEverySentenceSeparate() async throws {
        try await withModel { model in
            let utterances: [(sentences: [String], translation: String)] = [
                (["ただいま。", "おかえり"], "我回来了。欢迎回来"),
                (["いつもごめんね。", "いや、俺の方こそごめん。"], "总是对不起。不，是我对不起。"),
                (["美味しそう食べよう"], "看起来很好吃，我们吃吧"),
                (["綺麗で優しくて仕事もできる。"], "她很漂亮，很温柔，而且工作也很能干。")
            ]
            for utterance in utterances {
                let id = UUID()
                install(utterance.sentences.joined(), utterance.translation, id: id, on: model)
                XCTAssertEqual(model.draftPresentation?.sourceText ?? model.overlayState?.draftSourceText, utterance.sentences[0])
                enqueue(utterance.sentences, id: id, on: model)
                try await waitUntil { model.overlayState?.sourceText == utterance.sentences.last }
            }
            let sentences = utterances.flatMap(\.sentences)
            let history = model.overlayState?.history ?? []
            let shown = history.map(\.sourceText) + [model.overlayState?.sourceText ?? ""]
            XCTAssertEqual(shown, sentences, "Every subtitle line holds exactly one sentence")
            for entry in history {
                XCTAssertLessThanOrEqual(SentenceTranslationContext.splitSentences(entry.translatedText).count, 1, entry.translatedText)
            }
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
        }
    }

    func testSingleLongSentenceAndCommaClauseAreNeverTruncated() async throws {
        try await withModel { model in
            let source = "今日は一緒に公園を散歩してから、晩ご飯を食べに行きましょう。"
            install(source, "今天我们一起去公园散步，然后再到附近那家餐厅吃晚饭吧。", id: UUID(), on: model)
            XCTAssertNil(model.draftPresentation)
            XCTAssertEqual(model.overlayState?.draftSourceText, source)
        }
    }

    func testTailGrowthAndSourceCorrectionKeepReadableDraftUntilReplacementArrives() async throws {
        try await withModel { model in
            let id = UUID(), first = "別の仕事探した方がいいかな。"
            install(first + "明日友達に相談してみようかな。", "要不要找一份别的工作呢。明天找朋友商量一下吧。", id: id, on: model)
            let page = try XCTUnwrap(model.draftPresentation)
            var state = try XCTUnwrap(model.overlayState)
            state.draftSourceText = first + "明日友達に相談してみようかな。それから"
            model.previewOverlayForTesting(state)
            XCTAssertEqual(model.draftPresentation?.translatedText, page.translatedText)
            state.draftSourceText = "別の学校探した方がいいかな。明日友達に相談してみようかな。それから"
            model.previewOverlayForTesting(state)
            XCTAssertEqual(model.draftPresentation, page, "Retain the readable old page while its revision is translated")
            state.setDraftTranslation("要不要找一所别的学校呢。明天找朋友商量一下吧。然后", sourceText: state.draftSourceText!, promotionID: id)
            model.previewOverlayForTesting(state)
            XCTAssertEqual(model.draftPresentation?.sourceText, "別の学校探した方がいいかな。")
            XCTAssertEqual(model.draftPresentation?.translatedText, "要不要找一所别的学校呢。")
            XCTAssertTrue(model.transcriptEntries.isEmpty)
        }
    }

    func testUnalignedTranslationWaitsForSentenceTranslationsWithoutCuttingWords() async throws {
        try await withModel { model in
            let id = UUID(), source = "別の仕事探した方がいいかな。明日友達に相談してみようかな。"
            let combined = "要不要换个工作呢，明天找我的朋友好好商量一下再做决定吧。"
            install(source, combined, id: id, on: model)
            XCTAssertNil(model.draftPresentation, "Keep existing readable text while sentence translations are pending")
            model.finishDraftSentenceTranslationForTesting(index: 0, text: "要换个工作吗。")
            XCTAssertEqual(model.draftPresentation?.translatedText, "要换个工作吗。")
            try await Task.sleep(nanoseconds: 2_100_000_000)
            XCTAssertEqual(model.draftPresentation?.translatedText, "要换个工作吗。", "Do not advance to a blank translation")
            model.finishDraftSentenceTranslationForTesting(index: 1, text: "明天问问朋友吧。")
            XCTAssertEqual(model.draftPresentation?.translatedText, "明天问问朋友吧。")
            enqueue(DraftSentencePager.sentences(in: source), id: id, on: model)
            // The reader is on the second page; the first is archived, not shown again.
            try await waitUntil { model.overlayState?.sourceText == "明日友達に相談してみようかな。" }
            XCTAssertEqual(model.overlayState?.translatedText, "明天问问朋友吧。")
            XCTAssertEqual(model.overlayState?.history.map(\.translatedText), ["要换个工作吗。"])
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), ["要换个工作吗。", "明天问问朋友吧。"])
        }
    }

    func testPagedDraftFinalizesEverySentenceAndKeepsTheirTranslations() async throws {
        try await withModel { model in
            let id = UUID(), parts = ["別の仕事探した方がいいかな。", "明日友達に相談してみようかな。"]
            install(parts.joined(), "要不要找一份别的工作呢。明天找朋友商量一下吧。", id: id, on: model)
            enqueue(parts, id: id, on: model)
            try await waitUntil { model.overlayState?.committedPromotionID == id }
            XCTAssertEqual(model.overlayState?.sourceText, parts[0])
            XCTAssertNil(model.draftPresentation)
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), parts)
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), ["要不要找一份别的工作呢。", "明天找朋友商量一下吧。"])
            try await waitUntil { model.overlayState?.sourceText == parts[1] }
            XCTAssertEqual(model.overlayState?.history.first?.sourceText, parts[0])
        }
    }

    func testFinishedPageIsNotShownAgainWhenThePassageFinalizes() async throws {
        try await withModel { model in
            let id = UUID(), parts = ["別の仕事探した方がいいかな。", "明日友達に相談してみようかな。"]
            install(parts.joined(), "要不要找一份别的工作呢。明天找朋友商量一下吧。", id: id, on: model)
            try await waitUntil { model.draftPresentation?.sourceText == parts[1] }
            var committed: [String] = []
            let observation = model.$overlayState.compactMap { $0?.sourceText }.removeDuplicates().sink { committed.append($0) }
            defer { observation.cancel() }
            let finalizedAt = Date()
            enqueue(parts, id: id, on: model)
            try await waitUntil { model.overlayState?.sourceText == parts[1] }
            XCTAssertLessThan(Date().timeIntervalSince(finalizedAt), 0.5, "The open page promotes in place")
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(committed.contains(parts[0]), "A finished page must not return as the live caption")
            XCTAssertEqual(model.overlayState?.translatedText, "明天找朋友商量一下吧。")
            XCTAssertNil(model.overlayState?.draftSourceText)
            XCTAssertNil(model.draftPresentation)
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [parts[0]])
            XCTAssertEqual(model.overlayState?.history.map(\.translatedText), ["要不要找一份别的工作呢。"])
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), parts)
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), ["要不要找一份别的工作呢。", "明天找朋友商量一下吧。"])

            // A later caption translation still reaches the archived sentence.
            let archivedID = try XCTUnwrap(model.transcriptEntries.first?.id)
            model.finishCaptionTranslationForTesting(captionID: archivedID, text: "是不是该换份工作呢。")
            XCTAssertEqual(model.overlayState?.history.first?.translatedText, "是不是该换份工作呢。")
            XCTAssertEqual(model.transcriptEntries.first?.translatedText, "是不是该换份工作呢。")
        }
    }

    func testFinishedPagesFollowThePreviousCaptionAndOnlyUnreadPagesWait() async throws {
        try await withModel { model in
            let previous = UUID()
            enqueue(["ありがとう。"], id: previous, on: model)
            try await waitUntil { model.overlayState?.sourceText == "ありがとう。" }
            let id = UUID(), parts = ["別の仕事探した方がいいかな。", "明日友達に相談してみようかな。", "それから決めよう。"]
            install(parts.joined(), "要不要找一份别的工作呢。明天找朋友商量一下吧。然后再决定吧。", id: id, on: model)
            try await waitUntil { model.draftPresentation?.sourceText == parts[1] }
            enqueue(parts, id: id, on: model)
            try await waitUntil { model.overlayState?.sourceText == parts[1] }
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), ["ありがとう。", parts[0]])
            // The unread third sentence still gets its own turn after the open page.
            try await waitUntil { model.overlayState?.sourceText == parts[2] }
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), ["ありがとう。", parts[0], parts[1]])
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), ["ありがとう。"] + parts)
        }
    }

    func testFinalizingOnlyFinishedPagesRetiresTheirDraft() async throws {
        try await withModel { model in
            let id = UUID(), parts = ["別の仕事探した方がいいかな。", "明日友達に相談してみようかな。"]
            install(parts.joined(), "要不要找一份别的工作呢。明天找朋友商量一下吧。", id: id, on: model)
            try await waitUntil { model.draftPresentation?.sourceText == parts[1] }
            model.enqueueRecognizedSentence(.init(text: parts[0], promotionSegmentID: id,
                translationContext: SentenceTranslationContext(sentences: parts, sentenceIndex: 0, draftSegmentID: id), recognitionID: UUID()),
                source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans")
            try await waitUntil { model.overlayState?.history.map(\.sourceText) == [parts[0]] }
            XCTAssertEqual(model.overlayState?.sourceText, "")
            XCTAssertNil(model.overlayState?.draftSourceText, "No caption owns the old draft any more")
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), [parts[0]])
        }
    }

    func testOpenPageCountsItsVisibleTimeWhenItPromotes() async throws {
        try await withModel { model in
            let id = UUID(), parts = ["別の仕事探した方がいいかな。",
                                      "明日は朝から友達の家に行って、これからのことをゆっくり相談してみようかな。",
                                      "それから決めよう。"]
            install(parts.joined(), "要不要找一份别的工作呢。明天一早去朋友家，慢慢商量一下以后的打算吧。然后再决定吧。", id: id, on: model)
            try await waitUntil { model.draftPresentation?.sourceText == parts[1] }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertEqual(model.draftPresentation?.sourceText, parts[1])
            enqueue(parts, id: id, on: model)
            try await waitUntil { model.overlayState?.sourceText == parts[1] }
            let promotedAt = Date()
            try await waitUntil { model.overlayState?.sourceText == parts[2] }
            let hold = Date().timeIntervalSince(promotedAt)
            // Already read for 1.5 s as a page: only the formal floor (about
            // 1.3-1.5 s) remains before the unread third sentence, not 2.5 s or more.
            XCTAssertGreaterThanOrEqual(hold, 1.1)
            XCTAssertLessThan(hold, 2.0)
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), parts.prefix(2).map { $0 })
        }
    }

    func testOtherLanguagesAndAllDisplayModesKeepSentenceBoundaries() async throws {
        for mode in SubtitleDisplayMode.allCases {
            for (language, source) in [
                ("en", "We should find another place to stay. Tomorrow we can ask our friends for advice."),
                ("zh-Hans", "我们应该重新找一个适合工作的地方。明天去问问朋友们有什么好的建议。"),
                ("es", "Deberíamos buscar otro lugar para vivir. Mañana podemos pedir consejo a nuestros amigos.")
            ] {
                try await withModel { model in
                    model.subtitleDisplayMode = mode
                    install(source, source, id: UUID(), on: model, from: language, to: language)
                    XCTAssertEqual(model.draftPresentation?.sourceText, DraftSentencePager.sentences(in: source)[0], "\(language) \(mode)")
                    XCTAssertEqual(model.overlayState?.draftSourceText, source)
                }
            }
        }
    }

    func testNewDraftOrStopClearsPaging() async throws {
        try await withModel { model in
            let id = UUID(), source = "今日は晴れです。公園で遊びましょう。"
            install(source, "今天天气晴朗。一起去公园玩吧。", id: id, on: model)
            XCTAssertEqual(model.draftPresentation?.sourceText, "今日は晴れです。")
            install("ありがとう。", "谢谢。", id: UUID(), on: model)
            XCTAssertNil(model.draftPresentation)
            XCTAssertEqual(model.overlayState?.draftSourceText, "ありがとう。")
            model.stopSession()
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNil(model.draftPresentation)
        }
    }

    private func install(_ source: String, _ translated: String, id: UUID, on model: AppModel, from: String = "ja", to: String = "zh-Hans") {
        model.receiveDraftForTesting(DraftSegment(segmentId: id, sourceText: source, stablePrefixLength: source.count, mutableTailText: "",
            avgConfidence: 1, startMs: 0, lastUpdateMs: 1, silenceMs: 0, stabilityScore: 1, boundaryScore: 1, chunkScore: 1, vadProbability: 1, words: []), language: from, target: to)
        var state = model.overlayState!
        state.setDraftTranslation(translated, sourceText: source, promotionID: id)
        model.previewOverlayForTesting(state, sourceLanguageID: from, targetLanguageID: to)
    }

    private func enqueue(_ parts: [String], id: UUID, on model: AppModel) {
        for index in parts.indices {
            model.enqueueRecognizedSentence(.init(text: parts[index], promotionSegmentID: index == 0 ? id : nil,
                translationContext: SentenceTranslationContext(sentences: parts, sentenceIndex: index, draftSegmentID: id), recognitionID: UUID()),
                source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(7)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Draft/caption did not reach the expected sentence")
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("draft-pages-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
