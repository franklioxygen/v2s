import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let openAdvancedSettings: () -> Void
    private let quitApp: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(
        model: AppModel,
        openAdvancedSettings: @escaping () -> Void,
        quitApp: @escaping () -> Void
    ) {
        self.model = model
        self.openAdvancedSettings = openAdvancedSettings
        self.quitApp = quitApp
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

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
        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: StatusBarPopoverView(
                model: model,
                closePopover: { [weak self] in
                    self?.popover.performClose(nil)
                },
                openAdvancedSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openAdvancedSettings()
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

    func popoverWillShow(_ notification: Notification) {
        startClosingMonitorsIfNeeded()
    }

    func popoverDidClose(_ notification: Notification) {
        stopClosingMonitors()
    }

    private func startClosingMonitorsIfNeeded() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else {
            return
        }

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.closePopoverIfNeeded(for: event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.closePopoverIfNeeded(for: event)
            }
        }
    }

    private func stopClosingMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func closePopoverIfNeeded(for event: NSEvent) {
        guard popover.isShown else {
            return
        }

        let clickPoint = screenPoint(for: event)
        guard clickShouldKeepPopoverOpen(at: clickPoint) == false else {
            return
        }

        popover.performClose(nil)
    }

    private func clickShouldKeepPopoverOpen(at screenPoint: NSPoint) -> Bool {
        if let buttonRect = statusItemScreenRect, buttonRect.contains(screenPoint) {
            return true
        }

        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(screenPoint) {
            return true
        }

        return false
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window = event.window else {
            return NSEvent.mouseLocation
        }

        return window.convertPoint(toScreen: event.locationInWindow)
    }
}
