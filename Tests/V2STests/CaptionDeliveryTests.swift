import Combine
import XCTest
@testable import v2s

#if DEBUG
@MainActor
final class CaptionDeliveryTests: XCTestCase {
    func testBackToBackSentencePairsAllReachTheScreenInOrder() async throws {
        try await withModel { model in
            let sentences = ["一番です。", "二番です。", "三番です。", "四番です。", "五番です。", "六番です。"]
            var visible: [String] = []
            var shownAt: [Date] = []
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                if !state.sourceText.isEmpty, visible.last != state.sourceText {
                    visible.append(state.sourceText)
                    shownAt.append(Date())
                }
            }
            defer { observation.cancel() }
            for pairStart in stride(from: 0, to: sentences.count, by: 2) {
                let id = UUID(), pair = Array(sentences[pairStart..<(pairStart + 2)])
                for index in pair.indices {
                    let context = try XCTUnwrap(SentenceTranslationContext(sentences: pair, sentenceIndex: index, draftSegmentID: id))
                    model.enqueueRecognizedSentence(
                        RecognizedSentence(text: pair[index], promotionSegmentID: index == 0 ? id : nil,
                                           translationContext: context, recognitionID: UUID()),
                        source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja"
                    )
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try await waitUntil { visible.last == sentences.last }
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
            XCTAssertEqual(visible, sentences, "Being saved in the transcript is not enough: every caption must reach the screen")
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), Array(sentences.dropLast()))
            for (first, next) in zip(shownAt, shownAt.dropFirst()) {
                XCTAssertGreaterThanOrEqual(next.timeIntervalSince(first), 0.95, "Even during catch-up, keep a full second to read short replies")
            }
            print("CAPTION DELIVERY pairs: expected=\(sentences), displayed=\(visible)")
        }
    }

    func testBurstRetainsRepeatedUtterancesAndTheirOwnTranslations() async throws {
        try await withModel { model in
            let sources = ["はい。", "いいえ。", "はい。", "違います。", "そうです。"]
            let translations = ["好。", "不。", "好。", "不对。", "是的。"]
            let ids = sources.map { _ in UUID() }
            var shownIDs: [UUID] = [], shownTranslations: [String] = []
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                if let id = state.committedPromotionID, ids.contains(id),
                   !state.translatedText.isEmpty, shownIDs.last != id {
                    shownIDs.append(id)
                    shownTranslations.append(state.translatedText)
                }
            }
            defer { observation.cancel() }
            for index in sources.indices {
                model.enqueueRecognizedSentence(
                    RecognizedSentence(text: sources[index], promotionSegmentID: ids[index], recognitionID: UUID()),
                    source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans"
                )
                model.finishCaptionTranslationForTesting(promotionID: ids[index], text: translations[index])
            }
            try await waitUntil { shownIDs.last == ids.last }
            XCTAssertEqual(shownIDs, ids)
            XCTAssertEqual(shownTranslations, translations)
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sources)
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), translations)
            print("CAPTION DELIVERY translated: expected=\(sources.count), displayed=\(shownIDs.count)")
        }
    }

    func testFourSentenceBurstRecordedFromTheTestVideoReachesTheScreen() async throws {
        try await withModel { model in
            // Real ASR callbacks recorded at 159.682s in test.mp4. All four
            // arrived together; the old queue removed the second before display.
            let sentences = ["ごめんうん、気にしなくていいから", "知らなくていいよ。", "本当に焦りと罪悪感だよ。", "俺は立たなくなってしまった。"]
            var visible: [String] = []
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                if !state.sourceText.isEmpty, visible.last != state.sourceText { visible.append(state.sourceText) }
            }
            defer { observation.cancel() }
            for sentence in sentences {
                model.enqueueRecognizedSentence(
                    RecognizedSentence(text: sentence, recognitionID: UUID()),
                    source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja"
                )
            }
            try await waitUntil { visible.last == sentences.last }
            XCTAssertEqual(visible, sentences)
            XCTAssertEqual(model.overlayState?.history.map(\.sourceText), Array(sentences.dropLast()))
            print("CAPTION DELIVERY video 159.682s: expected=\(sentences), displayed=\(visible)")
        }
    }

    func testDelayedTranslationKeepsItsPlaceInABacklog() async throws {
        try await withModel { model in
            let sources = ["一番です。", "二番です。", "三番です。", "四番です。"]
            let translations = ["第一。", "第二。", "第三。", "第四。"]
            let ids = sources.map { _ in UUID() }
            var translated: [UUID: String] = [:]
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                if let id = state.committedPromotionID, let index = ids.firstIndex(of: id),
                   state.sourceText == sources[index], state.translatedText == translations[index] {
                    translated[id] = state.translatedText
                }
            }
            defer { observation.cancel() }
            for index in sources.indices {
                model.enqueueRecognizedSentence(
                    RecognizedSentence(text: sources[index], promotionSegmentID: ids[index], recognitionID: UUID()),
                    source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans"
                )
                if index != 1 { model.finishCaptionTranslationForTesting(promotionID: ids[index], text: translations[index]) }
            }
            try await waitUntil { model.overlayState?.committedPromotionID == ids[1] }
            XCTAssertEqual(model.overlayState?.sourceText, sources[1])
            XCTAssertEqual(model.overlayState?.translatedText, "")
            model.finishCaptionTranslationForTesting(promotionID: ids[1], text: translations[1])
            try await waitUntil { translated[ids[3]] != nil }
            XCTAssertEqual(ids.compactMap { translated[$0] }, translations)
            XCTAssertEqual(model.transcriptEntries.map(\.translatedText), translations)
        }
    }

    func testRecordedTenMinuteCaptionStreamIsDeliveredWithoutOmissions() async throws {
        guard let path = ProcessInfo.processInfo.environment["V2S_CAPTION_REPLAY_FILE"] else {
            throw XCTSkip("Set V2S_CAPTION_REPLAY_FILE to replay the recorded video recognition callbacks")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let sentences = text.components(separatedBy: .newlines).compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            return fields.count == 3 && fields[1] == "C" ? String(fields[2]) : nil
        }
        XCTAssertGreaterThan(sentences.count, 3)
        try await withModel { model in
            model.subtitleDisplayMode = .originalOnly
            let ids = sentences.map { _ in UUID() }
            let replayStartedAt = Date()
            var visible: [String] = [], lastID: UUID?
            let observation = model.$overlayState.compactMap { $0 }.sink { state in
                guard let id = state.committedPromotionID, id != lastID else { return }
                lastID = id
                visible.append(state.sourceText)
                if visible.count.isMultiple(of: 10) {
                    print("VIDEO CAPTION REPLAY: displayed \(visible.count)/\(sentences.count)")
                }
            }
            defer { observation.cancel() }
            // Feed all finalized callbacks as a burst to exercise queue pressure.
            // Actual per-caption reading time remains enabled; this is not a
            // second speech-recognition pass or a real-time audio/video playback.
            for index in sentences.indices {
                model.enqueueRecognizedSentence(
                    RecognizedSentence(text: sentences[index], promotionSegmentID: ids[index], recognitionID: UUID()),
                    source: .preview, sourceLanguageID: "ja", targetLanguageID: "ja"
                )
            }
            let deadline = Date().addingTimeInterval(Double(sentences.count) * 5 + 10)
            while lastID != ids.last, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
            XCTAssertEqual(visible, sentences)
            print("VIDEO CAPTION REPLAY COMPLETE: expected=\(sentences.count), displayed=\(visible.count), elapsed=\(Date().timeIntervalSince(replayStartedAt))s")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "The queue did not reach the last sentence")
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("caption-delivery-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        defer { model.stopSession() }
        try await body(model)
    }
}
#endif
