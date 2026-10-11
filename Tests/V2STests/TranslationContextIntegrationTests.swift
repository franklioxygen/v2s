import Foundation
import Translation
import XCTest
@testable import v2s

final class TranslationContextIntegrationTests: XCTestCase {
    @MainActor
    func testNativeJapaneseDialogueRetainsMeaningThroughPromotion() async throws {
        guard ProcessInfo.processInfo.environment["V2S_TRANSLATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Set V2S_TRANSLATION_INTEGRATION=1 to test installed Apple translation models")
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let source = Locale.Language(identifier: "ja")
        let target = Locale.Language(identifier: "zh-Hans")
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            throw XCTSkip("Japanese and Simplified Chinese translation models are not installed")
        }
        let session = TranslationSession(installedSource: source, target: target)
        let coordinator = TranslationCoordinator()
        var runner: Task<Void, Never>?
        coordinator.onConfigurationChange = { configuration in
            guard configuration != nil, runner == nil else { return }
            runner = Task { await coordinator.run(using: session) }
        }
        defer {
            runner?.cancel()
            coordinator.reset()
        }

        // Prime the standalone memo first: on the reported model this means “now”.
        // It must never override the same words translated with dialogue context.
        let isolated = try await coordinator.translate("ただいま。", from: "ja", to: "zh-Hans")
        let id = UUID()
        let sentences = ["ただいま。", "おかえり。"]
        let first = try XCTUnwrap(SentenceTranslationContext(sentences: sentences, sentenceIndex: 0, draftSegmentID: id))
        let second = try XCTUnwrap(SentenceTranslationContext(sentences: sentences, sentenceIndex: 1, draftSegmentID: id))
        let passage = try await coordinator.translate(first.sourceText, from: "ja", to: "zh-Hans")
        var state = OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test")
        state.setDraftTranslation(passage, sourceText: first.sourceText, promotionID: id)
        let firstDraft = try XCTUnwrap(state.promotableDraftTranslatedText(for: sentences[0], promotionID: id, context: first))
        let secondDraft = try XCTUnwrap(state.promotableDraftTranslatedText(for: sentences[1], promotionID: id, context: second))
        let firstFinal = try await coordinator.translate(sentences[0], from: "ja", to: "zh-Hans", context: first)
        let secondFinal = try await coordinator.translate(sentences[1], from: "ja", to: "zh-Hans", context: second)
        XCTAssertEqual(firstDraft, firstFinal)
        XCTAssertEqual(secondDraft, secondFinal)
        XCTAssertTrue(firstFinal.contains("回来"), firstFinal)
        XCTAssertFalse(firstFinal.contains("现在"), firstFinal)
        XCTAssertTrue(secondFinal.contains("欢迎"), secondFinal)
        print("PROMOTION: standalone=\(isolated); draft=\(passage); committed=\(firstFinal) / \(secondFinal)")

        // The adverbial sense is still translated normally; no phrase replacement.
        let normal = try await coordinator.translate("ただいま準備中です。", from: "ja", to: "zh-Hans")
        XCTAssertTrue(normal.contains("准备"), normal)
        XCTAssertFalse(normal.contains("回来"), normal)
    }
}
