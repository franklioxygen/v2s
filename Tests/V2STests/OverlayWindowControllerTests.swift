import AppKit
import XCTest
@testable import v2s

final class OverlayWindowControllerTests: XCTestCase {
    @MainActor
    func testRecordingVisibilityUsesNewPublishedStyleValue() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-overlay-window-controller-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }

        let model = AppModel(
            settingsStore: SettingsStore(fileURL: settingsURL),
            sourceCatalogService: SourceCatalogService()
        )
        let controller = OverlayWindowController(model: model, showTranscript: {})

        XCTAssertTrue(controller.panelSharingTypesForTesting.allSatisfy { $0 == .readOnly })

        model.updateOverlayStyle { $0.invisibleInRecording = true }

        XCTAssertTrue(controller.panelSharingTypesForTesting.allSatisfy { $0 == .none })

        model.updateOverlayStyle { $0.invisibleInRecording = false }

        XCTAssertTrue(controller.panelSharingTypesForTesting.allSatisfy { $0 == .readOnly })
    }
}
