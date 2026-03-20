import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let dockVisibilityController: DockVisibilityController
    private lazy var subtitleModeInfoWindowController = SubtitleModeInfoWindowController()

    init(model: AppModel, dockVisibilityController: DockVisibilityController) {
        self.dockVisibilityController = dockVisibilityController
        let window = NSWindow()
        let hostingController = NSHostingController(
            rootView: SettingsView(model: model, closeSettings: {}, openSubtitleModeInfo: {})
        )
        window.contentViewController = hostingController
        window.title = "v2s Advanced Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        super.init(window: window)
        window.delegate = self
        hostingController.rootView = SettingsView(
            model: model,
            closeSettings: { [weak self] in
                self?.closeForSessionStart()
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

    private func showSubtitleModeInfo() {
        subtitleModeInfoWindowController.showWindow(nil)
        subtitleModeInfoWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class SubtitleModeInfoWindowController: NSWindowController {
    init() {
        let window = NSWindow()
        let hostingController = NSHostingController(rootView: SubtitleModeInfoView())
        window.contentViewController = hostingController
        window.title = "Subtitle Modes"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct SubtitleModeInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose the subtitle mode based on how much you value latency versus sentence completeness.")
                    .foregroundStyle(.secondary)

                ForEach(SubtitleMode.allCases, id: \.self) { mode in
                    SubtitleModeInfoCard(mode: mode)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct SubtitleModeInfoCard: View {
    let mode: SubtitleMode

    var body: some View {
        let config = ModeConfig.config(for: mode)

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(mode.detail)
                    .foregroundStyle(.secondary)

                Text(mode.longDescription)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Best for: \(mode.bestFor)")
                    Text("Tradeoff: \(mode.tradeoff)")
                    Text(
                        "Targets: first token \(config.firstTokenTargetMs) ms · source commit \(config.commitSourceTargetMs) ms · translation commit \(config.commitTranslationTargetMs) ms"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(mode.displayName)
                .font(.headline)
        }
    }
}

private extension SubtitleMode {
    var longDescription: String {
        switch self {
        case .balanced:
            return "Balances response speed with readable sentence chunks. This is the default choice when you want stable subtitles without making the overlay feel slow."
        case .follow:
            return "Commits earlier and uses shorter chunks so subtitles stay closer to live speech. It reacts fastest, but longer thoughts may be split into more pieces."
        case .reading:
            return "Waits longer for fuller phrases and more complete translations. It reads more smoothly for lectures or dense content, but appears later on screen."
        }
    }

    var bestFor: String {
        switch self {
        case .balanced:
            return "most day-to-day calls, videos, and mixed usage"
        case .follow:
            return "live meetings, streams, and fast back-and-forth conversations"
        case .reading:
            return "lectures, courses, and content where complete sentences matter more"
        }
    }

    var tradeoff: String {
        switch self {
        case .balanced:
            return "not the absolute fastest or the most complete"
        case .follow:
            return "lower latency, but more fragmented subtitle chunks"
        case .reading:
            return "better readability, but higher delay"
        }
    }
}
