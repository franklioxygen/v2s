import Combine
import XCTest
@testable import v2s

#if DEBUG
@MainActor
final class DraftHandoffTests: XCTestCase {
    func testEmptyRecognizerUpdatesKeepDraftUntilItsFinalResultArrives() async throws {
        try await withModel { model in
            let id = UUID()
            model.receiveDraftForTesting(draft("ただいま。", id: id), target: "ja")
            model.receiveDraftForTesting(nil, target: "ja")
            // Longer than the old 150 ms clear timer.
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(model.overlayState?.draftSourceText, "ただいま。")
            XCTAssertEqual(model.overlayState?.draftPromotionID, id)
            enqueue("ただいま。", id: id, on: model, target: "ja")
            try await waitUntil { model.overlayState?.committedPromotionID == id }
            XCTAssertNil(model.overlayState?.draftSourceText)
            XCTAssertEqual(model.overlayState?.sourceText, "ただいま。")
        }
    }

    func testEarlierCaptionCannotClearANewerUtteranceInAnyLanguage() async throws {
        for (language, first, next) in [
            ("ja", "ただいま。", "おかえり。"),
            ("en", "I'm home.", "Welcome back."),
            ("zh-Hans", "我回来了。", "欢迎回来。"),
            ("es", "Ya estoy en casa.", "Bienvenido.")
        ] {
            try await withModel { model in
                let firstID = UUID(), nextID = UUID()
                model.receiveDraftForTesting(draft(first, id: firstID), language: language, target: language)
                enqueue(first, id: firstID, on: model, language: language, target: language)
                // The next ASR partial can arrive before the display queue runs.
                model.receiveDraftForTesting(draft(next, id: nextID), language: language, target: language)
                try await waitUntil { model.overlayState?.committedPromotionID == firstID }
                XCTAssertEqual(model.overlayState?.draftSourceText, next, language)
                XCTAssertEqual(model.overlayState?.draftPromotionID, nextID, language)
            }
        }
    }

    func testRevisedSourceKeepsProvisionalTranslationUntilFinalTranslationArrives() async throws {
        try await withModel { model in
            let id = UUID()
            let initial = "今日は公園へ。", final = "今日は公園へ行きます。"
            installTranslatedDraft(initial, translation: "今天去公园。", id: id, on: model)
            var states: [OverlayPreviewState] = []
            let observation = model.$overlayState.compactMap { $0 }.sink { states.append($0) }
            defer { observation.cancel() }
            enqueue(final, id: id, on: model)
            model.receiveDraftForTesting(nil)
            try await waitUntil { model.overlayState?.committedPromotionID == id }
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(model.overlayState?.draftTranslatedText, "今天去公园。")
            XCTAssertTrue(model.overlayState?.isAwaitingCommittedTranslation == true)
            XCTAssertEqual(model.overlayState?.translatedText, "")
            XCTAssertEqual(model.transcriptEntries.last?.translatedText, "")

            // The display queue's 3-second translation timeout must not blank
            // the draft either; a late translation can still take over.
            try await Task.sleep(nanoseconds: 3_100_000_000)
            XCTAssertTrue(model.overlayState?.isAwaitingCommittedTranslation == true)
            XCTAssertEqual(model.overlayState?.draftTranslatedText, "今天去公园。")

            model.finishCaptionTranslationForTesting(promotionID: id, text: "今天我要去公园。")
            try await waitUntil { model.overlayState?.translatedText == "今天我要去公园。" }
            XCTAssertNil(model.overlayState?.draftSourceText)
            XCTAssertEqual(model.transcriptEntries.last?.translatedText, "今天我要去公园。")
            XCTAssertTrue(states.allSatisfy { state in
                state.draftTranslatedText == "今天去公园。" || state.translatedText == "今天我要去公园。"
            }, "Every published state must retain the draft or its final replacement")
        }
    }

    func testValidatedDraftTranslationPromotesImmediately() async throws {
        try await withModel { model in
            let id = UUID()
            installTranslatedDraft("ただいま。", translation: "我回来了。", id: id, on: model)
            enqueue("ただいま。", id: id, on: model)
            try await waitUntil { model.overlayState?.committedPromotionID == id }
            XCTAssertEqual(model.overlayState?.translatedText, "我回来了。")
            XCTAssertNil(model.overlayState?.draftSourceText)
        }
    }

    func testLateTranslationDoesNotClearTheFollowingDraft() async throws {
        try await withModel { model in
            let id = UUID(), nextID = UUID()
            installTranslatedDraft("今日は公園へ。", translation: "今天去公园。", id: id, on: model)
            enqueue("今日は公園へ行きます。", id: id, on: model)
            try await waitUntil { model.overlayState?.isAwaitingCommittedTranslation == true }
            model.receiveDraftForTesting(draft("一緒に行こう。", id: nextID), target: "ja")
            model.finishCaptionTranslationForTesting(promotionID: id, text: "今天我要去公园。")
            XCTAssertEqual(model.overlayState?.draftPromotionID, nextID)
            XCTAssertEqual(model.overlayState?.draftSourceText, "一緒に行こう。")
        }
    }

    func testOriginalOnlyDoesNotWaitForTranslation() async throws {
        try await withModel { model in
            let id = UUID()
            installTranslatedDraft("今日は公園へ。", translation: "今天去公园。", id: id, on: model)
            model.subtitleDisplayMode = .originalOnly
            enqueue("今日は公園へ行きます。", id: id, on: model)
            try await waitUntil { model.overlayState?.committedPromotionID == id }
            XCTAssertNil(model.overlayState?.draftSourceText)
            XCTAssertEqual(model.overlayState?.sourceText, "今日は公園へ行きます。")
        }
    }

    func testStoppingSessionClearsAHeldDraft() async throws {
        try await withModel { model in
            let id = UUID()
            installTranslatedDraft("今日は公園へ。", translation: "今天去公园。", id: id, on: model)
            enqueue("今日は公園へ行きます。", id: id, on: model)
            try await waitUntil { model.overlayState?.isAwaitingCommittedTranslation == true }
            model.stopSession()
            XCTAssertFalse(model.overlayState?.hasActiveDraftLayer == true)
        }
    }

    private func installTranslatedDraft(_ text: String, translation: String, id: UUID, on model: AppModel) {
        model.receiveDraftForTesting(draft(text, id: id))
        var state = model.overlayState!
        state.setDraftTranslation(translation, sourceText: text, promotionID: id)
        model.previewOverlayForTesting(state)
    }

    private func enqueue(_ text: String, id: UUID, on model: AppModel, language: String = "ja", target: String = "zh-Hans") {
        model.enqueueRecognizedSentence(
            RecognizedSentence(text: text, promotionSegmentID: id, recognitionID: UUID()),
            source: .preview, sourceLanguageID: language, targetLanguageID: target
        )
    }

    private func draft(_ text: String, id: UUID) -> DraftSegment {
        DraftSegment(segmentId: id, sourceText: text, stablePrefixLength: text.count, mutableTailText: "",
                     avgConfidence: 1, startMs: 0, lastUpdateMs: 1, silenceMs: 0, stabilityScore: 1,
                     boundaryScore: 1, chunkScore: 1, vadProbability: 1, words: [])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "The caption pipeline did not reach the expected state")
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v2s-handoff-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
