import Combine
import XCTest
@testable import v2s

#if DEBUG
@MainActor
final class CaptionLatencyTests: XCTestCase {
    func testRecordedGreetingDraftDoesNotReceiveASecondFullReadingWindow() async throws {
        try await withModel { model in
            let id = UUID(), sentences = ["ただいま。", "おかえり。"]
            installDraft(sentences.joined(), translation: "我回来了。欢迎回来。", id: id, on: model)
            // The recorded video delivered this combined draft at 26.228s and
            // both finalized sentences at 29.120s. Keep that real handoff delay.
            try await Task.sleep(nanoseconds: 2_892_000_000)
            let duration = try await measureFirstHold(sentences, id: id, on: model)
            XCTAssertGreaterThanOrEqual(duration, 0.95)
            XCTAssertLessThan(duration, 1.5, "Already-read draft text must count toward the formal reading window")
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), ["我回来了。", "欢迎回来。"])
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [sentences[0]])
            print("CAPTION LATENCY recorded greeting: formal first hold=\(duration)s")
        }
    }

    func testSourceOnlyDoesNotWaitForAnInvisibleTranslation() async throws {
        try await withModel { model in
            model.subtitleDisplayMode = .originalOnly
            let duration = try await measureFirstHold(["はい。", "いいえ。"], on: model)
            XCTAssertGreaterThanOrEqual(duration, 1.1)
            XCTAssertLessThan(duration, 1.7)
            let firstCaptionID = try XCTUnwrap(model.transcriptEntries.first?.id)
            model.finishCaptionTranslationForTesting(captionID: firstCaptionID, text: "好。")
            XCTAssertEqual(model.overlayState?.sourceText, "いいえ。")
            XCTAssertEqual(model.overlayState?.history.first?.translatedText, "好。")
            XCTAssertEqual(model.transcriptEntries.first?.translatedText, "好。")
            print("CAPTION LATENCY original only, translation pending: hold=\(duration)s")
        }
    }

    func testChangedFinalTranslationGetsFreshReadingTime() async throws {
        try await withModel { model in
            let id = UUID(), sentences = ["ただいま。", "おかえり。"]
            installDraft(sentences.joined(), translation: "今です。戻って。", id: id, on: model)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let duration = try await measureFirstHold(sentences, id: id, on: model, finalFirstTranslation: "我回来了。")
            XCTAssertGreaterThanOrEqual(duration, 1.95, "A correction is new reading, even if the old draft was visible for a long time")
            XCTAssertEqual(model.transcriptEntries.first?.translatedText, "我回来了。")
        }
    }

    func testFreshlyRevisedDraftDoesNotInheritOldReadingTime() async throws {
        try await withModel { model in
            let id = UUID(), sentences = ["ただいま。", "おかえり。"]
            installDraft(sentences.joined(), translation: "现在。回来。", id: id, on: model)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            var state = try XCTUnwrap(model.overlayState)
            state.setDraftTranslation("我回来了。欢迎回来。", sourceText: sentences.joined(), promotionID: id)
            model.previewOverlayForTesting(state)
            let duration = try await measureFirstHold(sentences, id: id, on: model)
            XCTAssertGreaterThanOrEqual(duration, 1.95)
        }
    }

    func testLateCorrectionResetsCreditAlreadyAppliedToTheCurrentCaption() async throws {
        try await withModel { model in
            let id = UUID(), sentences = ["ただいま。", "おかえり。"]
            installDraft(sentences.joined(), translation: "今です。戻って。", id: id, on: model)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let correction = Task { @MainActor in
                try await Task.sleep(nanoseconds: 600_000_000)
                model.finishCaptionTranslationForTesting(promotionID: id, text: "我回来了。")
            }
            defer { correction.cancel() }
            let duration = try await measureFirstHold(sentences, id: id, on: model)
            XCTAssertGreaterThanOrEqual(duration, 2.5)
            XCTAssertEqual(model.transcriptEntries.first?.translatedText, "我回来了。")
        }
    }

    func testDisplayModeChangeDoesNotCreditPreviouslyHiddenTranslation() async throws {
        try await withModel { model in
            model.subtitleDisplayMode = .originalOnly
            let id = UUID(), sentences = ["ただいま。", "おかえり。"]
            installDraft(sentences.joined(), translation: "我回来了。欢迎回来。", id: id, on: model)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            model.subtitleDisplayMode = .both
            let duration = try await measureFirstHold(sentences, id: id, on: model)
            XCTAssertGreaterThanOrEqual(duration, 1.95)
        }
    }

    func testDraftReadingCreditPreservesOtherLanguagesAndModes() async throws {
        for (language, mode, sentences) in [
            ("en", SubtitleDisplayMode.originalOnly, ["I'm home.", " Welcome back."]),
            ("zh-Hans", .both, ["我回来了。", "欢迎回来。"]),
            ("es", .translatedOnly, ["Ya llegué.", " Bienvenido."])
        ] {
            try await withModel { model in
                model.subtitleDisplayMode = mode
                let id = UUID()
                model.receiveDraftForTesting(draft(sentences.joined(), id: id), language: language, target: language)
                try await Task.sleep(nanoseconds: 2_500_000_000)
                let duration = try await measureFirstHold(sentences, id: id, on: model, language: language, target: language)
                XCTAssertGreaterThanOrEqual(duration, 0.95, language)
                XCTAssertLessThan(duration, 1.5, language)
                XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences.map { $0.trimmingCharacters(in: .whitespaces) })
                print("CAPTION LATENCY draft credit: \(language) \(mode), hold=\(duration)s")
            }
        }
    }

    private func measureFirstHold(_ sentences: [String], id: UUID? = nil, on model: AppModel,
                                  language: String = "ja", target: String = "zh-Hans",
                                  finalFirstTranslation: String? = nil) async throws -> TimeInterval {
        let firstID = id ?? UUID()
        var firstShown: Date?, secondShown: Date?
        let observation = model.$overlayState.compactMap { $0 }.sink { state in
            if state.sourceText == sentences[0], firstShown == nil { firstShown = Date() }
            if state.sourceText == sentences[1].trimmingCharacters(in: .whitespaces), secondShown == nil { secondShown = Date() }
        }
        defer { observation.cancel() }
        for index in sentences.indices {
            model.enqueueRecognizedSentence(
                RecognizedSentence(text: sentences[index], promotionSegmentID: index == 0 ? firstID : nil,
                                   translationContext: id.flatMap { SentenceTranslationContext(sentences: sentences, sentenceIndex: index, draftSegmentID: $0) },
                                   recognitionID: UUID()),
                source: .preview, sourceLanguageID: language, targetLanguageID: target
            )
        }
        if let finalFirstTranslation { model.finishCaptionTranslationForTesting(promotionID: firstID, text: finalFirstTranslation) }
        let deadline = Date().addingTimeInterval(6)
        while secondShown == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        return try XCTUnwrap(secondShown).timeIntervalSince(XCTUnwrap(firstShown))
    }

    private func installDraft(_ text: String, translation: String, id: UUID, on model: AppModel) {
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

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("caption-latency-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
