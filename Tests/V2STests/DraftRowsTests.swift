import XCTest
@testable import v2s

final class DraftSentenceSplitTests: XCTestCase {
    func testOnlyCompleteSentenceBoundariesBecomeRowsAcrossLanguages() {
        for (text, expected) in [
            ("別の仕事探した方がいいかな。明日友達に相談してみようかな。", ["別の仕事探した方がいいかな。", "明日友達に相談してみようかな。"]),
            ("今日は雨ですが、午後は晴れると思います。", ["今日は雨ですが、午後は晴れると思います。"]),
            ("Dr. Smith paid 3.14 dollars. Then he left.", ["Dr. Smith paid 3.14 dollars.", "Then he left."]),
            ("今天下雨了。我们明天再去。", ["今天下雨了。", "我们明天再去。"]),
            ("Ya llegué. ¿Cómo estás?", ["Ya llegué.", "¿Cómo estás?"]),
            ("The result is 3.14, but we need more data", ["The result is 3.14, but we need more data"])
        ] {
            XCTAssertEqual(DraftSentences.split(text), expected, text)
        }
    }

    func testCurrentLineIsTheNewestCompleteSentence() {
        func rows(_ sources: [String]) -> [OverlayDraftRow] {
            sources.map { OverlayDraftRow(sourceText: $0, translatedText: "", stablePrefixLength: 0) }
        }
        // Recorded at ~50 s: two finished sentences and one still being spoken.
        XCTAssertEqual(DraftSentences.currentRowIndex(in: rows(["いただきますまいは職場の先輩だったが。", "綺麗で優しくて仕事もできる。", "結婚して1年になる"])), 1)
        XCTAssertEqual(DraftSentences.currentRowIndex(in: rows(["夫婦なんだから助け合いましょう。", "ありがとう。"])), 1)
        XCTAssertNil(DraftSentences.currentRowIndex(in: rows(["結婚して1年になる"])), "Only an unfinished sentence: the caption stays current")
        XCTAssertNil(DraftSentences.currentRowIndex(in: []))
        XCTAssertEqual(DraftSentences.currentRowIndex(in: rows(["We met there.", "I called Mr."])), 0, "An abbreviation does not end a sentence")
        XCTAssertEqual(DraftSentences.currentRowIndex(in: rows(["¿Dónde estás?", "「行こう」"])), 0)
    }
}

/// Roll-up drafts: each recognized sentence is its own row as soon as it is
/// heard, and leaves the draft only by becoming a caption.
#if DEBUG
@MainActor
final class DraftRowsTests: XCTestCase {
    func testEverySentenceIsVisibleAtOnceOnItsOwnRow() async throws {
        try await withModel { model in
            install("ただいま。おかえり", "我回来了。欢迎回来", id: UUID(), on: model)
            XCTAssertEqual(model.draftRows.map(\.sourceText), ["ただいま。", "おかえり"])
            XCTAssertEqual(model.draftRows.map(\.translatedText), ["我回来了。", "欢迎回来"])
        }
    }

    func testContinuousSpeechShowsEachNewSentenceImmediately() async throws {
        try await withModel { model in
            // Recorded at 150–157 s: one recognizer draft that keeps growing.
            let id = UUID()
            let first = "ごめんうん、気にしなくていいから知らなくていいよ。"
            install(first, "对不起，嗯，不用在意，你不用知道。", id: id, on: model)
            for grown in [first + "本当に焦りと罪悪", first + "本当に焦りと罪悪感だよ。俺は立た"] {
                receive(grown, id: id, on: model)
                let rows = DraftSentences.split(grown)
                XCTAssertEqual(model.draftRows.map(\.sourceText), rows, "Recognized text must never wait for a page turn")
                XCTAssertEqual(model.draftRows.first?.translatedText, "对不起，嗯，不用在意，你不用知道。",
                               "A finished sentence keeps its translation while the next is heard")
            }
        }
    }

    func testFinishedSentenceKeepsItsTranslationWhileTheTailIsRevised() async throws {
        try await withModel { model in
            let id = UUID(), first = "別の仕事探した方がいいかな。"
            receive(first + "明日友達に", id: id, on: model)
            model.finishDraftRowTranslationForTesting(first, text: "要不要找别的工作呢。")
            model.finishDraftRowTranslationForTesting("明日友達に", text: "明天和朋友")
            XCTAssertEqual(model.draftRows.map(\.translatedText), ["要不要找别的工作呢。", "明天和朋友"])
            receive(first + "明日友達に相談してみようかな。", id: id, on: model)
            XCTAssertEqual(model.draftRows.map(\.translatedText), ["要不要找别的工作呢。", "明天和朋友"],
                           "The revised tail keeps its last translation until the new one arrives")
            model.finishDraftRowTranslationForTesting("明日友達に相談してみようかな。", text: "明天找朋友商量一下吧。")
            XCTAssertEqual(model.draftRows.map(\.translatedText), ["要不要找别的工作呢。", "明天找朋友商量一下吧。"])
        }
    }

    func testFinalizedSentencesLeaveTheDraftAndTheRestStays() async throws {
        try await withModel { model in
            let id = UUID()
            let parts = ["今日は晴れです。", "公園で遊びましょう。", "それから"]
            install(parts.joined(), "今天天气晴朗。一起去公园玩吧。然后", id: id, on: model)
            enqueue(Array(parts.prefix(2)), id: id, on: model)
            try await waitUntil { model.overlayState?.sourceText == parts[1] }
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [parts[0]])
            XCTAssertEqual(model.overlayState?.translatedText, "一起去公园玩吧。")
            XCTAssertEqual(model.draftRows.map(\.sourceText), [parts[2]], "The sentence still being heard stays")
            XCTAssertEqual(model.overlayState?.draftSourceText, parts.joined())
        }
    }

    func testDraftLeavesOnceEverySentenceIsACaption() async throws {
        try await withModel { model in
            let id = UUID(), parts = ["ただいま。", "おかえり。"]
            install(parts.joined(), "我回来了。欢迎回来。", id: id, on: model)
            enqueue(parts, id: id, on: model)
            try await waitUntil { model.overlayState?.sourceText == parts[1] }
            XCTAssertTrue(model.draftRows.isEmpty)
            XCTAssertNil(model.overlayState?.draftSourceText)
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), ["我回来了。", "欢迎回来。"])
        }
    }

    func testRewordedFinalStillReplacesItsOwnRow() async throws {
        try await withModel { model in
            let id = UUID()
            install("まは職場の先輩だった。綺麗で", "她是职场前辈。漂亮", id: id, on: model)
            // The final result corrects a word of the first sentence.
            model.enqueueRecognizedSentence(.init(text: "まいは職場の先輩だった。", promotionSegmentID: id, recognitionID: UUID()),
                                            source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans")
            try await waitUntil { model.overlayState?.sourceText == "まいは職場の先輩だった。" }
            // Until the corrected sentence has a translation its draft stands in for it.
            model.finishCaptionTranslationForTesting(promotionID: id, text: "麻衣是职场前辈。")
            XCTAssertEqual(model.overlayState?.translatedText, "麻衣是职场前辈。")
            XCTAssertEqual(model.draftRows.map(\.sourceText), ["綺麗で"], "The old wording must not stay beside its correction")
        }
    }

    func testCaptionWithoutItsOwnTranslationShowsItsRowsLatestOne() async throws {
        try await withModel { model in
            // Recorded at 51–58 s: the sentence finalized before the translation
            // of its last revision arrived, and the caption line used to be empty.
            let id = UUID(), first = "結婚して1年になるが"
            receive(first, id: id, on: model)
            model.finishDraftRowTranslationForTesting(first, text: "结婚一年了")
            receive(first + "、なんで俺みたいな男と", id: id, on: model)
            XCTAssertEqual(model.draftRows.first?.translatedText, "结婚一年了", "A revision keeps the last translation meanwhile")
            let final = "結婚して1年になるが、なんで俺みたいな男と一緒になってくれたのか"
            model.enqueueRecognizedSentence(.init(text: final, promotionSegmentID: id, recognitionID: UUID()),
                                            source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans")
            XCTAssertEqual(model.overlayState?.sourceText, final)
            XCTAssertEqual(model.overlayState?.translatedText, "结婚一年了")
            XCTAssertTrue(model.overlayState?.committedTranslationIsProvisional == true)
            XCTAssertTrue(model.draftRows.isEmpty)
            XCTAssertEqual(model.transcriptEntries.last?.translatedText, "", "The transcript keeps only real translations")

            // Rolled up into history, the stand-in is still replaced by the real translation.
            model.enqueueRecognizedSentence(.init(text: "今でもわからない", recognitionID: UUID()),
                                            source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans")
            XCTAssertEqual(model.overlayState?.history.last?.translatedText, "结婚一年了")
            let real = "结婚一年了，为什么会和我这样的男人在一起"
            model.finishCaptionTranslationForTesting(promotionID: id, text: real)
            XCTAssertEqual(model.overlayState?.history.last?.translatedText, real)
            XCTAssertEqual(model.transcriptEntries.first?.translatedText, real)
        }
    }

    func testSingleLongSentenceAndCommaClauseStayOneRow() async throws {
        try await withModel { model in
            let source = "今日は一緒に公園を散歩してから、晩ご飯を食べに行きましょう。"
            install(source, "今天我们一起去公园散步，然后再到附近那家餐厅吃晚饭吧。", id: UUID(), on: model)
            XCTAssertEqual(model.draftRows.map(\.sourceText), [source])
        }
    }

    func testOtherLanguagesAndAllDisplayModesKeepOneSentencePerRow() async throws {
        for mode in SubtitleDisplayMode.allCases {
            for (language, source) in [
                ("en", "We should find another place to stay. Tomorrow we can ask our friends for advice."),
                ("zh-Hans", "我们应该重新找一个适合工作的地方。明天去问问朋友们有什么好的建议。"),
                ("es", "Deberíamos buscar otro lugar para vivir. Mañana podemos pedir consejo a nuestros amigos.")
            ] {
                try await withModel { model in
                    model.subtitleDisplayMode = mode
                    install(source, source, id: UUID(), on: model, from: language, to: language)
                    XCTAssertEqual(model.draftRows.map(\.sourceText), DraftSentences.split(source), "\(language) \(mode)")
                    XCTAssertEqual(model.overlayState?.draftSourceText, source)
                }
            }
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
                XCTAssertEqual(model.draftRows.map(\.sourceText), utterance.sentences)
                enqueue(utterance.sentences, id: id, on: model)
                try await waitUntil { model.overlayState?.sourceText == utterance.sentences.last }
            }
            let sentences = utterances.flatMap(\.sentences)
            let history = model.overlayState?.history ?? []
            XCTAssertEqual(history.map(\.sourceText) + [model.overlayState?.sourceText ?? ""], sentences,
                           "Every subtitle line holds exactly one sentence")
            for entry in history {
                XCTAssertLessThanOrEqual(SentenceTranslationContext.splitSentences(entry.translatedText).count, 1, entry.translatedText)
            }
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
        }
    }

    func testNewDraftOrStopClearsRows() async throws {
        try await withModel { model in
            install("今日は晴れです。公園で遊びましょう。", "今天天气晴朗。一起去公园玩吧。", id: UUID(), on: model)
            XCTAssertEqual(model.draftRows.count, 2)
            install("ありがとう。", "谢谢。", id: UUID(), on: model)
            XCTAssertEqual(model.draftRows.map(\.sourceText), ["ありがとう。"])
            model.stopSession()
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(model.draftRows.isEmpty)
        }
    }

    private func receive(_ source: String, id: UUID, on model: AppModel, from: String = "ja", to: String = "zh-Hans") {
        model.receiveDraftForTesting(DraftSegment(segmentId: id, sourceText: source, stablePrefixLength: source.count, mutableTailText: "",
            avgConfidence: 1, startMs: 0, lastUpdateMs: 1, silenceMs: 0, stabilityScore: 1, boundaryScore: 1, chunkScore: 1,
            vadProbability: 1, words: []), language: from, target: to)
    }

    private func install(_ source: String, _ translated: String, id: UUID, on model: AppModel, from: String = "ja", to: String = "zh-Hans") {
        receive(source, id: id, on: model, from: from, to: to)
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
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Draft/caption did not reach the expected state")
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("draft-rows-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
