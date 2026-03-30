import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let dockVisibilityController: DockVisibilityController
    private let quitApp: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private lazy var subtitleModeInfoWindowController = SubtitleModeInfoWindowController(model: model)

    init(
        model: AppModel,
        updaterService: UpdaterService,
        dockVisibilityController: DockVisibilityController,
        quitApp: @escaping () -> Void
    ) {
        self.model = model
        self.dockVisibilityController = dockVisibilityController
        self.quitApp = quitApp
        let window = NSWindow()
        let hostingController = NSHostingController(
            rootView: SettingsView(model: model, updaterService: updaterService, closeSettings: {}, quitApp: {}, openSubtitleModeInfo: {})
        )
        window.contentViewController = hostingController
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.center()
        super.init(window: window)
        window.delegate = self
        applyLocalizedTitle()
        bindLocalizedTitle()
        hostingController.rootView = SettingsView(
            model: model,
            updaterService: updaterService,
            closeSettings: { [weak self] in
                self?.closeForSessionStart()
            },
            quitApp: { [weak self] in
                self?.quitApp()
            },
            openSubtitleModeInfo: { [weak self] in
                self?.showSubtitleModeInfo()
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        dockVisibilityController.setVisible(true, for: .settingsWindow)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeForSessionStart() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        dockVisibilityController.setVisible(false, for: .settingsWindow)
    }

    private func bindLocalizedTitle() {
        model.$interfaceLanguageID
            .sink { [weak self] _ in
                self?.applyLocalizedTitle()
            }
            .store(in: &cancellables)
    }

    private func applyLocalizedTitle() {
        window?.title = model.localized(.advancedSettingsWindowTitle)
    }

    private func showSubtitleModeInfo() {
        subtitleModeInfoWindowController.showWindow(nil)
        subtitleModeInfoWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class SubtitleModeInfoWindowController: NSWindowController {
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        let window = NSWindow()
        let hostingController = NSHostingController(rootView: SubtitleModeInfoView(model: model))
        window.contentViewController = hostingController
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        applyLocalizedTitle()
        model.$interfaceLanguageID
            .sink { [weak self] _ in
                self?.applyLocalizedTitle()
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyLocalizedTitle() {
        window?.title = model.localized(.subtitleModesWindowTitle)
    }
}

private struct SubtitleModeInfoView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.localized(.subtitleModeIntro))
                    .foregroundStyle(.secondary)

                ForEach(SubtitleMode.allCases, id: \.self) { mode in
                    SubtitleModeInfoCard(model: model, mode: mode)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 420)
        .environment(\.locale, model.interfaceLocale)
    }
}

private struct SubtitleModeInfoCard: View {
    @ObservedObject var model: AppModel
    let mode: SubtitleMode

    var body: some View {
        let config = ModeConfig.config(for: mode)

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(mode.detail(in: model.resolvedInterfaceLanguageID))
                    .foregroundStyle(.secondary)

                Text(mode.longDescription(in: model.resolvedInterfaceLanguageID))
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        model.localized(
                            .bestForFormat,
                            mode.bestFor(in: model.resolvedInterfaceLanguageID)
                        )
                    )
                    Text(
                        model.localized(
                            .tradeoffFormat,
                            mode.tradeoff(in: model.resolvedInterfaceLanguageID)
                        )
                    )
                    Text(
                        model.localized(
                            .targetsFormat,
                            config.firstTokenTargetMs,
                            config.commitSourceTargetMs,
                            config.commitTranslationTargetMs
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(mode.displayName(in: model.resolvedInterfaceLanguageID))
                .font(.headline)
        }
    }
}
