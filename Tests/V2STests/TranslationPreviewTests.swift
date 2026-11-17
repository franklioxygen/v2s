import Foundation
import Translation
import XCTest
@testable import v2s

#if DEBUG
@MainActor
final class TranslationPreviewTests: XCTestCase {
    private struct ModelFailed: Error {}

    func testDraftsUseTheLowLatencyModelAndKeepItsTranslationsApart() async throws {
        let coordinator = TranslationCoordinator()
        var asked: [String] = []
        coordinator.previewTranslatorForTesting = { text in
            asked.append(text)
            return "预览：\(text)"
        }

        let preview = try await coordinator.translate("ただいま。", from: "ja", to: "zh-Hans", quality: .preview)
        XCTAssertEqual(preview, "预览：ただいま。")
        XCTAssertTrue(coordinator.hasServedPreviews(from: "ja", to: "zh-Hans"))
        XCTAssertFalse(coordinator.hasServedPreviews(from: "ja", to: "en"))
        // A committed caption with the same words must not reuse it.
        XCTAssertNil(coordinator.memoizedTranslationForTesting("ただいま。", from: "ja", to: "zh-Hans"))

        // The same draft again is answered from the low-latency memo.
        _ = try await coordinator.translate("ただいま。", from: "ja", to: "zh-Hans", quality: .preview)
        XCTAssertEqual(asked, ["ただいま。"])

        coordinator.reset()
        XCTAssertFalse(coordinator.hasServedPreviews(from: "ja", to: "zh-Hans"))
    }

    func testADraftSentenceIsTranslatedInItsPassageByTheLowLatencyModel() async throws {
        let coordinator = TranslationCoordinator()
        let context = try XCTUnwrap(SentenceTranslationContext(
            sentences: ["ただいま。", "おかえり。"], sentenceIndex: 1, draftSegmentID: UUID()
        ))
        var asked: [String] = []
        coordinator.previewTranslatorForTesting = { text in
            asked.append(text)
            return text == context.sourceText ? "我回来了。欢迎回来。" : "？"
        }

        let sentence = try await coordinator.translate(
            "おかえり。", from: "ja", to: "zh-Hans", context: context, quality: .preview
        )
        XCTAssertEqual(sentence, "欢迎回来。")
        XCTAssertEqual(asked, [context.sourceText])
    }

    // A model that fails once is not asked again: drafts go back to the caption model.
    func testAFailedLowLatencyModelIsNotAskedAgain() async throws {
        let coordinator = TranslationCoordinator()
        defer { coordinator.reset() }
        var calls = 0
        coordinator.previewTranslatorForTesting = { _ in
            calls += 1
            throw ModelFailed()
        }

        // Without a caption session these wait in the queue until cancelled.
        let first = Task { try await coordinator.translate("ただいま。", from: "ja", to: "zh-Hans", quality: .preview) }
        try await waitUntil { calls == 1 }
        let second = Task { try await coordinator.translate("おかえり。", from: "ja", to: "zh-Hans", quality: .preview) }
        try await Task.sleep(nanoseconds: 200_000_000)
        first.cancel()
        second.cancel()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(coordinator.hasServedPreviews(from: "ja", to: "zh-Hans"))
    }

    func testInstalledLowLatencyModelTranslatesDrafts() async throws {
        guard ProcessInfo.processInfo.environment["V2S_TRANSLATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Set V2S_TRANSLATION_INTEGRATION=1 to test installed Apple translation models")
        }
        guard #available(macOS 26.4, *) else { throw XCTSkip("The low-latency model needs macOS 26.4") }
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")
        guard await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target) == .installed else {
            throw XCTSkip("The English to Simplified Chinese low-latency model is not installed")
        }
        let coordinator = TranslationCoordinator()
        defer { coordinator.reset() }

        // No caption session runs here: a draft that fell back to it would never finish.
        let cold = Date()
        let first = try await withTimeout { try await coordinator.translate(
            "The market opens at nine.", from: "en", to: "zh-Hans", quality: .preview
        ) }
        let coldMs = Int(Date().timeIntervalSince(cold) * 1000)
        let warm = Date()
        let second = try await withTimeout { try await coordinator.translate(
            "We will meet at the old bridge.", from: "en", to: "zh-Hans", quality: .preview
        ) }
        let warmMs = Int(Date().timeIntervalSince(warm) * 1000)
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertTrue(coordinator.hasServedPreviews(from: "en", to: "zh-Hans"))
        print("LOW LATENCY: cold \(coldMs) ms, warm \(warmMs) ms: \(first) / \(second)")
    }

    private func withTimeout(_ body: @escaping @MainActor () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return try XCTUnwrap(result, "The draft was not translated by the low-latency model")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
}
#endif
