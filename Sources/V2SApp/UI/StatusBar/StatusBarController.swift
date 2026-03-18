import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController {
    private let model: AppModel
    private let openSettings: () -> Void
    private let quitApp: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, openSettings: @escaping () -> Void, quitApp: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.quitApp = quitApp
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureStatusItem()
        configurePopover()
        bindModel()
        updateStatusIcon(for: model.sessionState)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.action = #selector(togglePopover(_:))
        button.target = self
        button.imagePosition = .imageOnly
        button.toolTip = "v2s"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: StatusBarPopoverView(
                model: model,
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openSettings()
                },
                quitApp: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.quitApp()
                }
            )
        )
    }

    private func bindModel() {
        model.$sessionState
            .sink { [weak self] state in
                self?.updateStatusIcon(for: state)
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(for state: SessionState) {
        let symbolName: String

        switch state {
        case .idle:
            symbolName = "captions.bubble"
        case .running:
            symbolName = "captions.bubble.fill"
        case .error:
            symbolName = "exclamationmark.bubble"
        }

        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "v2s status icon"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Screen rect of the status bar button, for animation targeting.
    var statusItemScreenRect: NSRect? {
        guard let button = statusItem.button,
              let window = button.window else { return nil }
        let rect = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rect)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
