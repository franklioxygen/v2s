import Combine
import XCTest
@testable import v2s

#if DEBUG
@MainActor
final class CaptionPacingTests: XCTestCase {
    func testNewArrivalsShortenAnAlreadyRunningLongHoldWithoutSkipping() async throws {
        try await withModel { model in
            model.subtitleDisplayMode = .originalOnly
            let source = "今日は仕事が早く終わったので、駅前のお店で買い物をしてから家に帰ることにしました。"
            let texts = [source, "おかえり。", "ありがとう。"]
            var shown: [String] = [], times: [Date] = []
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                if !state.sourceText.isEmpty, shown.last != state.sourceText {
                    shown.append(state.sourceText)
                    times.append(Date())
                }
            }
            defer { observation.cancel() }
            enqueue(source, on: model)
            try await waitUntil { shown.count == 1 }
            try await Task.sleep(nanoseconds: 400_000_000)
            for text in texts.dropFirst() { enqueue(text, on: model) }
            try await waitUntil { shown.count == texts.count }
            XCTAssertEqual(shown, texts)
            let hold = try XCTUnwrap(times.dropFirst().first).timeIntervalSince(try XCTUnwrap(times.first))
            XCTAssertLessThan(hold, 3.1, "A new queue must shorten the in-progress hold, not wait for its old timer")
            XCTAssertGreaterThan(hold, 1.5, "Do not flash a long caption just to drain the queue")
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), texts)
            print("CAPTION PACING arrivals: long caption held \(hold)s; all \(shown.count) captions displayed")
        }
    }

    func testQuietLongCaptionKeepsItsReadingTime() async throws {
        try await withModel { model in
            model.subtitleDisplayMode = .originalOnly
            let text = "今日は仕事が早く終わったので、駅前のお店で買い物をしてから家に帰ることにしました。"
            enqueue(text, on: model)
            try await waitUntil { model.overlayState?.sourceText == text }
            try await Task.sleep(nanoseconds: 3_500_000_000)
            XCTAssertEqual(model.overlayState?.sourceText, text, "An isolated long caption still needs reading time")
        }
    }

    func testCatchUpPreservesEnglishChineseAndSpanishInDifferentDisplayModes() async throws {
        let examples: [(String, SubtitleDisplayMode, [String])] = [
            ("en", .translatedOnly, ["I finished work early today, so I am going to buy some groceries near the station before I come home.", "Welcome home.", "Thanks."]),
            ("zh-Hans", .both, ["今天工作结束得比较早，所以我打算先去车站附近买点东西，然后再回家准备晚饭。", "欢迎回来。", "谢谢。"]),
            ("es", .originalOnly, ["Hoy terminé de trabajar temprano, así que voy a comprar algunas cosas cerca de la estación antes de volver a casa.", "Bienvenido.", "Gracias."])
        ]
        for (language, mode, sentences) in examples {
            try await withModel { model in
                model.subtitleDisplayMode = mode
                var visible: [String] = [], dates: [Date] = []
                let observation = model.$overlayState.compactMap { $0 }.sink { state in
                    if !state.sourceText.isEmpty, visible.last != state.sourceText {
                        visible.append(state.sourceText)
                        dates.append(Date())
                    }
                }
                defer { observation.cancel() }
                for text in sentences {
                    model.enqueueRecognizedSentence(
                        RecognizedSentence(text: text, promotionSegmentID: UUID(), recognitionID: UUID()),
                        source: .preview, sourceLanguageID: language, targetLanguageID: language
                    )
                }
                try await waitUntil { visible.count == sentences.count }
                XCTAssertEqual(visible, sentences)
                XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
                let duration = try XCTUnwrap(dates.dropFirst().first).timeIntervalSince(try XCTUnwrap(dates.first))
                XCTAssertLessThan(duration, 3.2, language)
                XCTAssertGreaterThan(duration, 1.5, language)
                print("CAPTION PACING language: \(language) \(mode.rawValue), long hold=\(duration)s")
            }
        }
    }

    func testIdenticalTranslationDoesNotRestartTheHold() async throws {
        try await checkTranslationUpdate(originalOnly: false, repeatedTranslation: true)
    }

    func testHiddenTranslationDoesNotRestartOriginalOnlyReading() async throws {
        try await checkTranslationUpdate(originalOnly: true, repeatedTranslation: false)
    }

    func testChangedLateTranslationGetsReadingTimeEvenWithABacklog() async throws {
        try await withModel { model in
            let firstID = UUID(), secondID = UUID(), thirdID = UUID()
            let start = Date()
            var secondShown: Date?
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                if state.committedPromotionID == secondID, secondShown == nil { secondShown = Date() }
            }
            defer { observation.cancel() }
            for (id, text, translation) in [(firstID, "今です。", "现在。"), (secondID, "はい。", "好。"), (thirdID, "どうぞ。", "请。") ] {
                enqueue(text, id: id, on: model, target: "zh-Hans")
                model.finishCaptionTranslationForTesting(promotionID: id, text: translation)
            }
            try await waitUntil { model.overlayState?.committedPromotionID == firstID }
            try await Task.sleep(nanoseconds: 650_000_000)
            let correctionAt = Date()
            let correction = "这才是校正后的完整翻译。"
            model.finishCaptionTranslationForTesting(promotionID: firstID, text: correction)
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertEqual(model.overlayState?.committedPromotionID, firstID)
            XCTAssertEqual(model.overlayState?.translatedText, correction)
            try await waitUntil { secondShown != nil }
            let duration = try XCTUnwrap(secondShown).timeIntervalSince(correctionAt)
            XCTAssertGreaterThanOrEqual(duration, 1.0)
            XCTAssertLessThan(duration, 2.8)
            XCTAssertEqual(model.transcriptEntries.first?.translatedText, correction)
            print("CAPTION PACING correction: new translation readable for \(duration)s; total \(Date().timeIntervalSince(start))s")
        }
    }

    private func checkTranslationUpdate(originalOnly: Bool, repeatedTranslation: Bool) async throws {
        try await withModel { model in
            if originalOnly { model.subtitleDisplayMode = .originalOnly }
            let firstID = UUID(), secondID = UUID()
            var firstShown: Date?, secondShown: Date?
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                if state.committedPromotionID == firstID, firstShown == nil { firstShown = Date() }
                if state.committedPromotionID == secondID, secondShown == nil { secondShown = Date() }
            }
            defer { observation.cancel() }
            for (id, text, translation) in [(firstID, "はい。", "好。"), (secondID, "いいえ。", "不。") ] {
                enqueue(text, id: id, on: model, target: "zh-Hans")
                model.finishCaptionTranslationForTesting(promotionID: id, text: translation)
            }
            try await waitUntil { firstShown != nil }
            try await Task.sleep(nanoseconds: 750_000_000)
            model.finishCaptionTranslationForTesting(promotionID: firstID, text: repeatedTranslation ? "好。" : "好的，没问题。")
            try await waitUntil { secondShown != nil }
            let duration = try XCTUnwrap(secondShown).timeIntervalSince(try XCTUnwrap(firstShown))
            XCTAssertGreaterThanOrEqual(duration, 1.1)
            XCTAssertLessThan(duration, 1.6, "An unchanged visible caption must not restart its timer")
            print("CAPTION PACING duplicate/hidden: originalOnly=\(originalOnly), hold=\(duration)s")
        }
    }

    private func enqueue(_ text: String, id: UUID = UUID(), on model: AppModel, target: String = "ja") {
        model.enqueueRecognizedSentence(RecognizedSentence(text: text, promotionSegmentID: id, recognitionID: UUID()),
                                        source: .preview, sourceLanguageID: "ja", targetLanguageID: target)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Caption did not arrive")
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("caption-pacing-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
