import Foundation
import Translation
import XCTest
@testable import v2s
final class OtherTranslationRegressionTests: XCTestCase {
    @MainActor func testEnglish() async throws { try await check("The meeting starts at three. Please wait here.", from: "en", to: "zh-Hans") }
    @MainActor func testChinese() async throws { try await check("今天我们去公园散步，然后一起吃晚饭。", from: "zh-Hans", to: "en") }
    @MainActor func testSpanish() async throws { try await check("Buenos días. Hoy vamos a visitar el parque.", from: "es", to: "zh-Hans") }
    @MainActor private func check(_ text: String, from: String, to: String) async throws {
        guard ProcessInfo.processInfo.environment["V2S_TRANSLATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Set V2S_TRANSLATION_INTEGRATION=1 to test installed Apple translation models")
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26") }
        let source = Locale.Language(identifier: from), target = Locale.Language(identifier: to)
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { throw XCTSkip("Models not installed for \(from)-\(to)") }
        let session = TranslationSession(installedSource: source, target: target)
        let expected = try await session.translate(text).targetText
        let coordinator = TranslationCoordinator()
        var runner: Task<Void, Never>?
        coordinator.onConfigurationChange = { configuration in
            guard configuration != nil, runner == nil else { return }
            runner = Task { await coordinator.run(using: session) }
        }
        defer { runner?.cancel(); coordinator.reset() }
        let actual = try await coordinator.translate(text, from: from, to: to)
        let memo = try await coordinator.translate(text, from: from, to: to)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(memo, expected)
        print("OTHER TRANSLATION \(from)->\(to): \(actual)")
    }
}
