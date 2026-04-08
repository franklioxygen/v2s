import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel()
    private let updaterService = UpdaterService()
    private let launchAtLoginService = LaunchAtLoginService()
    private let dockVisibilityController = DockVisibilityController()
    private lazy var transcriptWindowController = TranscriptWindowController(model: appModel)
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var overlayWindowController: OverlayWindowController?
    private var sourceRefreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settingsWindowController = SettingsWindowController(
            model: appModel,
            updaterService: updaterService,
            launchAtLoginService: launchAtLoginService,
            dockVisibilityController: dockVisibilityController,
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            },
            quitApp: {
                NSApp.terminate(nil)
            }
        )
        let overlayWindowController = OverlayWindowController(
            model: appModel,
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            }
        )
        let statusBarController = StatusBarController(
            model: appModel,
            openAdvancedSettings: { [weak settingsWindowController] in
                settingsWindowController?.showSettings()
            },
            showTranscript: { [weak self] in
                self?.transcriptWindowController.showTranscript()
            },
            quitApp: {
            NSApp.terminate(nil)
            }
        )

        self.settingsWindowController = settingsWindowController
        self.overlayWindowController = overlayWindowController
        self.statusBarController = statusBarController

        overlayWindowController.trayIconRectProvider = { [weak self] in
            self?.statusBarController?.statusItemScreenRect
        }

        settingsWindowController.showSettings()

        appModel.$sessionState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.updateSourceRefreshTimer(for: state)
            }
            .store(in: &cancellables)
    }

    private func installSourceRefreshTimer(interval: TimeInterval) {
        sourceRefreshTimer?.invalidate()
        sourceRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appModel.refreshSources()
            }
        }
    }

    private func updateSourceRefreshTimer(for state: SessionState) {
        guard state == .running else {
            sourceRefreshTimer?.invalidate()
            sourceRefreshTimer = nil
            return
        }

        installSourceRefreshTimer(interval: 5.0)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        sourceRefreshTimer?.invalidate()
        sourceRefreshTimer = nil
        cancellables.removeAll()
        appModel.persistSettings()
    }
}
