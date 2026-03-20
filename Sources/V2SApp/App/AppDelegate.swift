import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel()
    private let dockVisibilityController = DockVisibilityController()
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var overlayWindowController: OverlayWindowController?
    private var sourceRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settingsWindowController = SettingsWindowController(
            model: appModel,
            dockVisibilityController: dockVisibilityController,
            quitApp: {
                NSApp.terminate(nil)
            }
        )
        let overlayWindowController = OverlayWindowController(model: appModel)
        let statusBarController = StatusBarController(
            model: appModel
        ) { [weak settingsWindowController] in
            settingsWindowController?.showSettings()
        } quitApp: {
            NSApp.terminate(nil)
        }

        self.settingsWindowController = settingsWindowController
        self.overlayWindowController = overlayWindowController
        self.statusBarController = statusBarController

        overlayWindowController.trayIconRectProvider = { [weak self] in
            self?.statusBarController?.statusItemScreenRect
        }

        settingsWindowController.showSettings()

        sourceRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appModel.refreshSources()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sourceRefreshTimer?.invalidate()
        appModel.persistSettings()
    }
}
