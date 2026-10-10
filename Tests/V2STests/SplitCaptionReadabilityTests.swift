import Combine
import XCTest
@testable import v2s

#if DEBUG
@MainActor
final class SplitCaptionReadabilityTests: XCTestCase {
    func testSplitDraftKeepsSentenceBoundariesAndGivesFirstSentenceTimeToRead() async throws {
        try await withModel { model in
            let id = UUID(), sentences = ["ただいま。", "おかえり。"]
            installJapaneseDraft(sentences.joined(), translation: "我回来了。欢迎回来。", id: id, on: model)
            var firstShown: Date?, secondShown: Date?
            var committedTexts: [String] = []
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                if state.sourceText == sentences[0], state.translatedText == "我回来了。", firstShown == nil {
                    firstShown = Date()
                }
                if state.sourceText == sentences[1], secondShown == nil { secondShown = Date() }
                if !state.sourceText.isEmpty { committedTexts.append(state.sourceText) }
            }
            defer { observation.cancel() }
            try enqueuePassage(sentences, id: id, on: model)
            try await waitUntil { firstShown != nil }
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), ["我回来了。", "欢迎回来。"])
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertEqual(model.overlayState?.sourceText, sentences[0])
            XCTAssertTrue(model.overlayState?.history.isEmpty == true)
            try await waitUntil { secondShown != nil }
            let duration = try XCTUnwrap(secondShown).timeIntervalSince(try XCTUnwrap(firstShown))
            XCTAssertGreaterThanOrEqual(duration, 1.95, "The finalized first sentence needs its own reading window")
            XCTAssertEqual(model.overlayState?.sourceText, sentences[1])
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [sentences[0]])
            XCTAssertTrue(committedTexts.allSatisfy { sentences.contains($0) }, "Never merge finalized sentences to fix display timing")
            print("SPLIT CAPTION: first sentence visible for \(duration) seconds; transcript=\(model.transcriptEntries.map(\.sourceText))")
        }
    }

    func testSentencesStaySeparateInEveryDisplayModeAndAcrossLanguages() async throws {
        for mode in SubtitleDisplayMode.allCases {
            for (language, sentences) in [
                ("ja", ["ただいま。", "おかえり。"]),
                ("en", ["I'm home.", " Welcome back."]),
                ("zh-Hans", ["我回来了。", "欢迎回来。"]),
                ("es", ["Ya llegué.", " Bienvenido."])
            ] {
                try await withModel { model in
                    model.subtitleDisplayMode = mode
                    let id = UUID()
                    model.receiveDraftForTesting(draft(sentences.joined(), id: id), language: language, target: language)
                    try enqueuePassage(sentences, id: id, on: model, language: language, target: language)
                    try await waitUntil { model.overlayState?.committedPromotionID == id }
                    XCTAssertEqual(model.overlayState?.sourceText, sentences[0])
                    XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences.map { $0.trimmingCharacters(in: .whitespaces) })
                }
            }
        }
    }

    func testOneSentenceTranslationCannotBeAssignedToTwoFinalCaptions() async throws {
        try await withModel { model in
            let id = UUID(), sentences = ["ただいま。", "おかえり。"]
            installJapaneseDraft(sentences.joined(), translation: "我回来了，欢迎回来。", id: id, on: model)
            try enqueuePassage(sentences, id: id, on: model)
            try await waitUntil { model.overlayState?.committedPromotionID == id }
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
            XCTAssertTrue(model.transcriptEntries.allSatisfy { $0.translatedText.isEmpty })
            XCTAssertTrue(model.overlayState?.isAwaitingCommittedTranslation == true)
            model.finishCaptionTranslationForTesting(promotionID: id, text: "我回来了。")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertEqual(model.overlayState?.sourceText, sentences[0])
            XCTAssertEqual(model.overlayState?.translatedText, "我回来了。")
            XCTAssertNil(model.overlayState?.draftSourceText)
        }
    }

    func testOrdinarySingleSentencesKeepTheirExistingTiming() async throws {
        try await withModel { model in
            let firstID = UUID(), secondID = UUID()
            for (id, text) in [(firstID, "はい。"), (secondID, "いいえ。") ] {
                model.enqueueRecognizedSentence(RecognizedSentence(text: text, promotionSegmentID: id, recognitionID: UUID()),
                                                source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja")
            }
            try await waitUntil { model.overlayState?.committedPromotionID == firstID }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertEqual(model.overlayState?.committedPromotionID, secondID)
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), ["はい。", "いいえ。"])
        }
    }

    func testSplittingAnOlderPassageKeepsTheNewerDraft() async throws {
        try await withModel { model in
            let id = UUID(), nextID = UUID(), sentences = ["ただいま。", "おかえり。"]
            installJapaneseDraft(sentences.joined(), translation: "我回来了。欢迎回来。", id: id, on: model)
            try enqueuePassage(sentences, id: id, on: model)
            model.receiveDraftForTesting(draft("今日もお疲れさま。", id: nextID), target: "ja")
            try await waitUntil { model.overlayState?.committedPromotionID == id }
            XCTAssertEqual(model.overlayState?.sourceText, sentences[0])
            XCTAssertEqual(model.overlayState?.draftPromotionID, nextID)
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
        }
    }

    private func enqueuePassage(_ sentences: [String], id: UUID, on model: AppModel, language: String = "ja", target: String = "zh-Hans") throws {
        for index in sentences.indices {
            let context = try XCTUnwrap(SentenceTranslationContext(sentences: sentences, sentenceIndex: index, draftSegmentID: id))
            model.enqueueRecognizedSentence(
                RecognizedSentence(text: sentences[index], promotionSegmentID: index == 0 ? id : nil,
                                   translationContext: context, recognitionID: UUID()),
                source: .preview, sourceLanguageID: language, targetLanguageID: target
            )
        }
        model.receiveDraftForTesting(nil, language: language, target: target)
    }

    private func installJapaneseDraft(_ text: String, translation: String, id: UUID, on model: AppModel) {
        model.receiveDraftForTesting(draft(text, id: id), target: "ja")
        var state = model.overlayState!
        state.setDraftTranslation(translation, sourceText: text, promotionID: id)
        model.previewOverlayForTesting(state)
    }

    private func draft(_ text: String, id: UUID) -> DraftSegment {
        DraftSegment(segmentId: id, sourceText: text, stablePrefixLength: text.count, mutableTailText: "",
                     avgConfidence: 1, startMs: 0, lastUpdateMs: 1, silenceMs: 0, stabilityScore: 1,
                     boundaryScore: 1, chunkScore: 1, vadProbability: 1, words: [])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "The caption queue did not reach the expected state")
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v2s-split-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
