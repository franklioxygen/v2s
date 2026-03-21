import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let model: AppModel
    private let interactionState = OverlayInteractionState()
    private let panel: OverlayPanel
    private let controlsChromePanel: OverlayPanel
    private let scrollbarPanel: OverlayPanel
    private let moveButtonPanel: OverlayPanel
    private let closeButtonPanel: OverlayPanel
    private let resizeButtonPanel: OverlayPanel
    private let subtitleHostingView: NSHostingView<OverlayView>
    private let controlsChromeHostingView: NSHostingView<OverlayControlsChromeView>
    private let scrollbarHostingView: NSHostingView<OverlayHistoryScrollbarView>
    private let moveButtonHostingView: NSHostingView<OverlayMoveButtonView>
    private let closeButtonHostingView: NSHostingView<OverlayCloseButtonView>
    private let resizeButtonHostingView: NSHostingView<OverlayResizeButtonView>
    private var cancellables = Set<AnyCancellable>()
    /// Top-left corner (minX, maxY) of the panel after a user drag. nil = use auto-position.
    private var userDefinedTopLeft: NSPoint?
    private var userDefinedHeight: Double?
    private var liveResizeWidth: Double?
    private var dragStartTopLeft: NSPoint?
    private var resizeDragStartWidth: Double?
    private var resizeDragStartHeight: Double?
    private var resizeDragStartTopLeft: NSPoint?
    private var mouseTrackingTimer: Timer?
    private var workspaceNotificationCancellable: AnyCancellable?

    // MARK: - Genie Animation State
    var trayIconRectProvider: (() -> NSRect?)?
    private var geniePhase: GeniePhase = .idle
    private var panelsShown = false
    private var genieHideWindow: NSWindow?
    private var pendingHideSnapshot: NSWindow?

    private enum GeniePhase {
        case idle, showing, hiding
    }

    init(model: AppModel) {
        self.model = model
        self.panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.controlsChromePanel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: OverlayControlsLayout.stripSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.scrollbarPanel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: OverlayHistoryScrollbarLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.moveButtonPanel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.controlButtonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.closeButtonPanel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.controlButtonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.resizeButtonPanel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.controlButtonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.subtitleHostingView = NSHostingView(
            rootView: OverlayView(model: model, interactionState: interactionState)
        )
        self.controlsChromeHostingView = NSHostingView(rootView: OverlayControlsChromeView())
        self.scrollbarHostingView = NSHostingView(
            rootView: OverlayHistoryScrollbarView(model: model, interactionState: interactionState)
        )
        self.moveButtonHostingView = NSHostingView(
            rootView: OverlayMoveButtonView(
                onMoveDragStart: {},
                onMoveDragChanged: { _ in },
                onMoveDragEnded: {}
            )
        )
        self.closeButtonHostingView = NSHostingView(rootView: OverlayCloseButtonView(model: model))
        self.resizeButtonHostingView = NSHostingView(
            rootView: OverlayResizeButtonView(
                onResizeDragStart: {},
                onResizeDragChanged: { _ in },
                onResizeDragEnded: {}
            )
        )

        configurePanels()
        moveButtonHostingView.rootView = OverlayMoveButtonView(
            onMoveDragStart: { [weak self] in self?.beginControlDrag() },
            onMoveDragChanged: { [weak self] translation in self?.updateControlDrag(with: translation) },
            onMoveDragEnded: { [weak self] in self?.endControlDrag() }
        )
        resizeButtonHostingView.rootView = OverlayResizeButtonView(
            onResizeDragStart: { [weak self] in self?.beginResizeDrag() },
            onResizeDragChanged: { [weak self] translation in self?.updateResizeDrag(with: translation) },
            onResizeDragEnded: { [weak self] in self?.endResizeDrag() }
        )
        bindModel()
        syncWindow()
    }

    deinit {
        mouseTrackingTimer?.invalidate()
    }

    private func configurePanels() {
        configurePanel(panel, acceptsInput: false, level: .statusBar)
        panel.contentView = subtitleHostingView

        configurePanel(controlsChromePanel, acceptsInput: false, level: .statusBar)
        controlsChromePanel.contentView = controlsChromeHostingView

        let controlLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        configurePanel(scrollbarPanel, acceptsInput: true, level: controlLevel)
        scrollbarPanel.contentView = scrollbarHostingView

        configurePanel(moveButtonPanel, acceptsInput: true, level: controlLevel)
        moveButtonPanel.contentView = moveButtonHostingView

        configurePanel(closeButtonPanel, acceptsInput: true, level: controlLevel)
        closeButtonPanel.contentView = closeButtonHostingView

        configurePanel(resizeButtonPanel, acceptsInput: true, level: controlLevel)
        resizeButtonPanel.contentView = resizeButtonHostingView
    }

    private func configurePanel(_ panel: OverlayPanel, acceptsInput: Bool, level: NSWindow.Level) {
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.isFloatingPanel = true
        panel.tabbingMode = .disallowed
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = !acceptsInput
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    private func bindModel() {
        model.$isOverlayVisible
            .sink { [weak self] newVisible in
                guard let self else { return }
                // Capture snapshot synchronously (before SwiftUI re-renders)
                // @Published fires on willSet, so current view content is still intact
                self.captureHideSnapshotIfNeeded(
                    newVisible: newVisible, newState: self.model.overlayState)
                self.scheduleWindowSync()
            }
            .store(in: &cancellables)

        model.$overlayState
            .sink { [weak self] newState in
                guard let self else { return }
                self.captureHideSnapshotIfNeeded(
                    newVisible: self.model.isOverlayVisible, newState: newState)
                self.scheduleWindowSync()
            }
            .store(in: &cancellables)

        model.$overlayStyle
            .sink { [weak self] _ in self?.scheduleWindowSync() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleWindowSync() }
            .store(in: &cancellables)

        workspaceNotificationCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.updateAttachToSourceLevels() }

        model.$overlayStyle
            .map(\.attachToSource)
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateAttachToSourceLevels() }
            .store(in: &cancellables)
    }

    /// Pre-capture a snapshot of the overlay while content is still rendered.
    /// Called synchronously from Combine sinks (during willSet, before SwiftUI updates).
    private func captureHideSnapshotIfNeeded(newVisible: Bool, newState: OverlayPreviewState?) {
        let willShow = newVisible && newState != nil
        guard !willShow, panelsShown, pendingHideSnapshot == nil else { return }
        pendingHideSnapshot = createSnapshotWindow(of: panel, frame: panel.frame)
    }

    private func scheduleWindowSync() {
        DispatchQueue.main.async { [weak self] in
            self?.syncWindow()
        }
    }

    private func syncWindow() {
        let shouldShow = model.isOverlayVisible && model.overlayState != nil

        if shouldShow && !panelsShown {
            // Transition: hidden → visible
            panelsShown = true
            if geniePhase == .hiding { cancelGenieAnimation() }
            updateAttachToSourceLevels()
            positionPanels()
            animateGenieShow()
        } else if !shouldShow && panelsShown {
            // Transition: visible → hidden
            panelsShown = false
            if geniePhase == .showing { cancelGenieAnimation() }
            stopMouseTracking()
            interactionState.updatePassThroughBubble(nil)
            animateGenieHide()
        } else if shouldShow && geniePhase == .idle {
            // Already visible, just update layout
            updateAttachToSourceLevels()
            positionPanels()
            orderFrontAllPanels()
            startMouseTrackingIfNeeded()
            updatePassThroughBubble()
        }
    }

    // MARK: - Genie Effect Animation

    private func animateGenieShow() {
        pendingHideSnapshot?.orderOut(nil)
        pendingHideSnapshot = nil

        guard let trayRect = trayIconRectProvider?() else {
            // No tray rect available – show instantly
            geniePhase = .idle
            orderFrontAllPanels()
            startMouseTrackingIfNeeded()
            updatePassThroughBubble()
            return
        }

        geniePhase = .showing
        let finalFrame = panel.frame
        let duration: TimeInterval = 0.48

        // Start as a tiny strip at the tray icon
        let startFrame = NSRect(
            x: trayRect.midX - 15,
            y: trayRect.minY - 4,
            width: 30,
            height: 8
        )

        // Hide control panels during animation
        let controlPanels = [controlsChromePanel, scrollbarPanel, moveButtonPanel, closeButtonPanel, resizeButtonPanel]
        controlPanels.forEach { $0.alphaValue = 0; $0.orderOut(nil) }

        // Set initial state for main panel
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.orderFrontRegardless()

        // Apply initial perspective warp (tapered toward tray)
        applyPerspectiveTransform(angle: 0.3)

        // Animate perspective back to flat
        animateLayerPerspective(fromAngle: 0.3, toAngle: 0, duration: duration,
                                timing: CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0))

        // Animate frame + alpha
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            self.panel.animator().setFrame(finalFrame, display: true)
            self.panel.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.geniePhase == .showing else { return }
                self.resetLayerTransform()
                self.geniePhase = .idle
                self.positionPanels()
                self.orderFrontAllPanels()
                self.fadeInControlPanels()
                self.startMouseTrackingIfNeeded()
                self.updatePassThroughBubble()
            }
        })
    }

    private func animateGenieHide() {
        // Use the pre-captured snapshot (taken synchronously before SwiftUI re-render)
        let animWindow = pendingHideSnapshot
        pendingHideSnapshot = nil

        guard let trayRect = trayIconRectProvider?() else {
            // No tray rect – hide instantly
            geniePhase = .idle
            orderOutAllPanels()
            animWindow?.orderOut(nil)
            return
        }

        geniePhase = .hiding
        let duration: TimeInterval = 0.42

        // Target: tiny strip at tray icon
        let targetFrame = NSRect(
            x: trayRect.midX - 15,
            y: trayRect.minY - 4,
            width: 30,
            height: 8
        )

        // Hide all real panels immediately
        orderOutAllPanels()

        guard let animWindow else {
            geniePhase = .idle
            return
        }

        animWindow.orderFront(nil)
        animWindow.orderFrontRegardless()
        self.genieHideWindow = animWindow

        // Animate perspective warp on snapshot (flat → tapered toward tray)
        if let layer = animWindow.contentView?.layer {
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = CATransform3DIdentity
            var toT = CATransform3DIdentity
            toT.m34 = -1.0 / 300.0
            toT = CATransform3DRotate(toT, 0.3, 1, 0, 0)
            anim.toValue = toT
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0.0, 1.0, 0.35)
            anim.isRemovedOnCompletion = true
            layer.transform = toT
            layer.add(anim, forKey: "geniePerspective")
        }

        // Animate frame + alpha on snapshot window
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0.0, 1.0, 0.35)
            animWindow.animator().setFrame(targetFrame, display: true)
            animWindow.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                animWindow.orderOut(nil)
                self?.genieHideWindow = nil
                if self?.geniePhase == .hiding {
                    self?.geniePhase = .idle
                }
            }
        })
    }

    private func createSnapshotWindow(of sourcePanel: NSPanel, frame: NSRect) -> NSWindow? {
        guard let contentView = sourcePanel.contentView,
              let bitmapRep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmapRep)

        let image = NSImage(size: contentView.bounds.size)
        image.addRepresentation(bitmapRep)

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.contentView = imageView

        return window
    }

    private func cancelGenieAnimation() {
        panel.contentView?.layer?.removeAllAnimations()
        resetLayerTransform()
        genieHideWindow?.contentView?.layer?.removeAllAnimations()
        genieHideWindow?.orderOut(nil)
        genieHideWindow = nil
        pendingHideSnapshot?.orderOut(nil)
        pendingHideSnapshot = nil
        geniePhase = .idle
    }

    private func applyPerspectiveTransform(angle: CGFloat) {
        guard let contentView = panel.contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        var t = CATransform3DIdentity
        t.m34 = -1.0 / 300.0
        t = CATransform3DRotate(t, angle, 1, 0, 0)
        layer.transform = t
    }

    private func animateLayerPerspective(fromAngle: CGFloat, toAngle: CGFloat,
                                          duration: TimeInterval,
                                          timing: CAMediaTimingFunction) {
        guard let contentView = panel.contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }

        var fromT = CATransform3DIdentity
        if fromAngle != 0 {
            fromT.m34 = -1.0 / 300.0
            fromT = CATransform3DRotate(fromT, fromAngle, 1, 0, 0)
        }

        var toT = CATransform3DIdentity
        if toAngle != 0 {
            toT.m34 = -1.0 / 300.0
            toT = CATransform3DRotate(toT, toAngle, 1, 0, 0)
        }

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = fromT
        anim.toValue = toT
        anim.duration = duration
        anim.timingFunction = timing
        anim.isRemovedOnCompletion = true
        layer.transform = toT
        layer.add(anim, forKey: "geniePerspective")
    }

    private func resetLayerTransform() {
        panel.contentView?.layer?.transform = CATransform3DIdentity
    }

    private func fadeInControlPanels() {
        positionPanels()
        let controlPanels = [controlsChromePanel, scrollbarPanel, moveButtonPanel, closeButtonPanel, resizeButtonPanel]
        controlPanels.forEach { $0.alphaValue = 0; $0.orderFront(nil) }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            controlPanels.forEach { $0.animator().alphaValue = 1.0 }
        }
    }

    // MARK: - Panel Ordering

    private func orderFrontAllPanels() {
        panel.orderFront(nil)
        panel.orderFrontRegardless()

        controlsChromePanel.orderFront(nil)
        controlsChromePanel.orderFrontRegardless()

        scrollbarPanel.orderFront(nil)
        scrollbarPanel.orderFrontRegardless()

        moveButtonPanel.orderFront(nil)
        moveButtonPanel.orderFrontRegardless()

        closeButtonPanel.orderFront(nil)
        closeButtonPanel.orderFrontRegardless()

        resizeButtonPanel.orderFront(nil)
        resizeButtonPanel.orderFrontRegardless()
    }

    private func orderOutAllPanels() {
        panel.orderOut(nil)
        controlsChromePanel.orderOut(nil)
        scrollbarPanel.orderOut(nil)
        moveButtonPanel.orderOut(nil)
        closeButtonPanel.orderOut(nil)
        resizeButtonPanel.orderOut(nil)
    }

    private func positionPanels() {
        guard let screen = currentScreen() else { return }

        let visibleFrame = screen.visibleFrame
        let style = model.overlayStyle
        let width = resolvedPanelWidth(in: visibleFrame, style: style)
        let height = resolvedPanelHeight(in: visibleFrame)

        let originX: Double
        let originY: Double

        if let topLeft = userDefinedTopLeft {
            // Keep the top edge anchored where the user dragged it
            originX = topLeft.x
            originY = topLeft.y - height
        } else {
            originX = visibleFrame.midX - (width / 2)
            originY = visibleFrame.maxY - style.topInset - height
        }

        let overlayFrame = NSRect(x: originX, y: originY, width: width, height: height)
        panel.setFrame(overlayFrame, display: true)

        let chromeFrame = controlsChromeFrame(relativeTo: overlayFrame)
        controlsChromePanel.setFrame(chromeFrame, display: true)

        let scrollbarFrame = historyScrollbarFrame(relativeTo: overlayFrame)
        scrollbarPanel.setFrame(scrollbarFrame, display: true)

        let buttonFrames = controlButtonFrames(relativeTo: chromeFrame)
        moveButtonPanel.setFrame(buttonFrames[0], display: true)
        closeButtonPanel.setFrame(buttonFrames[1], display: true)
        resizeButtonPanel.setFrame(buttonFrames[2], display: true)
    }

    private func resolvedPanelWidth(in visibleFrame: NSRect, style: OverlayStyle) -> Double {
        if let liveResizeWidth {
            return min(max(liveResizeWidth, style.minWidth), style.maxWidth)
        }

        return min(max(visibleFrame.width * style.widthRatio, style.minWidth), style.maxWidth)
    }

    private func controlsChromeFrame(relativeTo overlayFrame: NSRect) -> NSRect {
        let size = OverlayControlsLayout.stripSize
        return NSRect(
            x: overlayFrame.minX + OverlayControlsLayout.outerPadding,
            y: overlayFrame.minY + OverlayControlsLayout.outerPadding,
            width: size.width,
            height: size.height
        )
    }

    private func historyScrollbarFrame(relativeTo overlayFrame: NSRect) -> NSRect {
        NSRect(
            x: overlayFrame.maxX - OverlayControlsLayout.outerPadding - OverlayHistoryScrollbarLayout.panelWidth,
            y: overlayFrame.minY + OverlayControlsLayout.outerPadding,
            width: OverlayHistoryScrollbarLayout.panelWidth,
            height: max(overlayFrame.height - (OverlayControlsLayout.outerPadding * 2), 1)
        )
    }

    private func controlButtonFrames(relativeTo chromeFrame: NSRect) -> [NSRect] {
        let buttonX = chromeFrame.minX + OverlayControlsLayout.controlPaddingX
        let topButtonY = chromeFrame.maxY
            - OverlayControlsLayout.controlPaddingY
            - OverlayControlsLayout.controlSize

        return (0..<3).map { index in
            NSRect(
                x: buttonX,
                y: topButtonY - CGFloat(index) * (OverlayControlsLayout.controlSize + OverlayControlsLayout.controlSpacing),
                width: OverlayControlsLayout.controlSize,
                height: OverlayControlsLayout.controlSize
            )
        }
    }

    private func resolvedPanelHeight(in visibleFrame: NSRect) -> Double {
        let minimumHeight = Self.minimumOverlayHeight
        let maximumHeight = max(minimumHeight, visibleFrame.height * 0.5)
        if let userDefinedHeight {
            return min(max(userDefinedHeight, minimumHeight), maximumHeight)
        }

        return min(max(defaultPanelHeight(), minimumHeight), maximumHeight)
    }

    private func defaultPanelHeight() -> Double {
        let style = model.overlayStyle

        // Base: committed layer (translated + source + internal spacing)
        let base = style.scaledTranslatedFontSize + style.scaledSourceFontSize + 48.0

        // Default height reserves room for the scrollback history and draft rows.
        let historyExtra = style.scaledTranslatedFontSize
            + style.scaledSourceFontSize
            + 20.0

        let draftExtra = style.scaledTranslatedFontSize + style.scaledSourceFontSize + 18.0

        return min(max(base + historyExtra + draftExtra, 88.0), 280.0)
    }

    private func beginControlDrag() {
        dragStartTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    private func updateControlDrag(with translation: CGSize) {
        guard let dragStartTopLeft else { return }

        userDefinedTopLeft = NSPoint(
            x: dragStartTopLeft.x + translation.width,
            y: dragStartTopLeft.y + translation.height
        )
        positionPanels()
    }

    private func endControlDrag() {
        dragStartTopLeft = nil
    }

    private func beginResizeDrag() {
        resizeDragStartWidth = panel.frame.width
        resizeDragStartHeight = panel.frame.height
        resizeDragStartTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    private func updateResizeDrag(with translation: CGSize) {
        guard let resizeDragStartWidth,
              let resizeDragStartHeight,
              let resizeDragStartTopLeft,
              let screen = currentScreen() else {
            return
        }

        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 0 else { return }

        let style = model.overlayStyle
        let rightEdgeX = resizeDragStartTopLeft.x + resizeDragStartWidth
        let maximumWidth = min(style.maxWidth, rightEdgeX - visibleFrame.minX)
        let newWidth = min(max(resizeDragStartWidth - translation.width, style.minWidth), maximumWidth)
        let minimumHeight = Self.minimumOverlayHeight
        let maximumHeight = max(
            minimumHeight,
            min(resizeDragStartTopLeft.y - visibleFrame.minY, visibleFrame.height * 0.5)
        )
        let newHeight = min(max(resizeDragStartHeight - translation.height, minimumHeight), maximumHeight)
        let newWidthRatio = newWidth / visibleFrame.width
        let newLeftX = rightEdgeX - newWidth
        let newTopY = resizeDragStartTopLeft.y

        liveResizeWidth = newWidth
        model.updateOverlayStyle { style in
            style.widthRatio = newWidthRatio
        }
        userDefinedTopLeft = NSPoint(x: newLeftX, y: newTopY)
        userDefinedHeight = newHeight
        positionPanels()
    }

    private func endResizeDrag() {
        liveResizeWidth = nil
        resizeDragStartWidth = nil
        resizeDragStartHeight = nil
        resizeDragStartTopLeft = nil
    }

    private func startMouseTrackingIfNeeded() {
        guard mouseTrackingTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePassThroughBubble()
            }
        }
        mouseTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
    }

    private func updatePassThroughBubble() {
        guard model.isOverlayVisible,
              model.overlayState != nil else {
            interactionState.updateScrollbarRevealProgress(0.0)
            interactionState.updatePassThroughBubble(nil)
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        interactionState.updateScrollbarRevealProgress(
            scrollbarRevealProgress(for: mouseLocation, scrollbarFrame: scrollbarPanel.frame)
        )

        guard model.overlayStyle.clickThrough else {
            interactionState.updatePassThroughBubble(nil)
            return
        }

        let overlayFrame = panel.frame
        guard overlayFrame.contains(mouseLocation) else {
            interactionState.updatePassThroughBubble(nil)
            return
        }

        let interactiveFrames = [
            scrollbarPanel.frame,
            moveButtonPanel.frame,
            closeButtonPanel.frame,
            resizeButtonPanel.frame
        ]
        guard interactiveFrames.contains(where: { $0.contains(mouseLocation) }) == false else {
            interactionState.updatePassThroughBubble(nil)
            return
        }

        interactionState.updatePassThroughBubble(
            OverlayPassThroughBubble(
                center: CGPoint(
                    x: mouseLocation.x - overlayFrame.minX,
                    y: overlayFrame.maxY - mouseLocation.y
                ),
                diameter: Self.passThroughBubbleDiameter
            )
        )
    }

    private func scrollbarRevealProgress(for mouseLocation: NSPoint, scrollbarFrame: NSRect) -> CGFloat {
        let distance = distance(from: mouseLocation, to: scrollbarFrame)
        guard distance < Self.scrollbarRevealDistance else { return 0.0 }
        return 1.0 - (distance / Self.scrollbarRevealDistance)
    }

    private func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0.0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0.0
        }

        return sqrt((dx * dx) + (dy * dy))
    }

    // MARK: - Attach to Source

    private func updateAttachToSourceLevels() {
        let useHighLevel = !model.overlayStyle.attachToSource || isSourceAppFrontmost()
        let contentLevel: NSWindow.Level = useHighLevel ? .statusBar : .normal
        let controlLevel = NSWindow.Level(rawValue: contentLevel.rawValue + 1)

        let allContentPanels: [OverlayPanel] = [panel, controlsChromePanel]
        let allControlPanels: [OverlayPanel] = [scrollbarPanel, moveButtonPanel, closeButtonPanel, resizeButtonPanel]

        for p in allContentPanels {
            p.level = contentLevel
            p.isFloatingPanel = useHighLevel
        }
        for p in allControlPanels {
            p.level = controlLevel
            p.isFloatingPanel = useHighLevel
        }

        if useHighLevel && panelsShown {
            orderFrontAllPanels()
        }
    }

    private func isSourceAppFrontmost() -> Bool {
        guard let source = model.selectedSource,
              source.category == .application else {
            return false
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        if let bundleID = frontmost.bundleIdentifier, bundleID == source.detail {
            return true
        }
        return false
    }

    private func currentScreen() -> NSScreen? {
        if let targetDisplayID = model.overlayStyle.targetDisplayID,
           let matchedScreen = NSScreen.screens.first(where: { $0.displayIDString == targetDisplayID }) {
            return matchedScreen
        }

        let mouseLocation = NSEvent.mouseLocation

        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

// MARK: - Panel

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension OverlayWindowController {
    static let minimumOverlayHeight: Double = 105
    static let passThroughBubbleDiameter: CGFloat = 118
    static let scrollbarRevealDistance: CGFloat = 42

    static let controlButtonSize = CGSize(
        width: OverlayControlsLayout.controlSize,
        height: OverlayControlsLayout.controlSize
    )
}

private extension NSScreen {
    var displayIDString: String? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return screenNumber.stringValue
    }
}
