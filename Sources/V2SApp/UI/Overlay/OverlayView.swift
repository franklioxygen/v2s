import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var interactionState: OverlayInteractionState
    @State private var committedOpacity: Double = 1.0
    @State private var renderedPassThroughBubble: OverlayPassThroughBubble?
    @State private var passThroughRevealProgress: Double = 0.0

    var body: some View {
        ZStack {
            subtitleContent
                .mask(passThroughMask)

            passThroughBubble
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncPassThroughBubble(interactionState.passThroughBubble)
        }
        .onChange(of: interactionState.passThroughBubble) { _, bubble in
            syncPassThroughBubble(bubble)
        }
        .modifier(OverlayTranslationHostModifier(model: model))
    }

    @ViewBuilder
    private var subtitleContent: some View {
        Group {
            if let state = model.overlayState {
                VStack(alignment: .center, spacing: 6) {
                    historyLayer(state)
                    committedLayer(state)
                    draftLayer(state)
                }
                .padding(.leading, 20)
                .padding(.trailing, 20 + OverlayHistoryScrollbarLayout.panelWidth + OverlayHistoryScrollbarLayout.contentSpacing)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundView)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, OverlayControlsLayout.outerPadding)
        .padding(.vertical, OverlayControlsLayout.outerPadding)
    }

    // MARK: - History layer

    @ViewBuilder
    private func historyLayer(_ state: OverlayPreviewState) -> some View {
        if state.hasHistory {
            GeometryReader { proxy in
                let visibleCount = historyVisibleCount(for: proxy.size.height)
                let visibleEntries = historyVisibleEntries(from: state.history, visibleCount: visibleCount)

                VStack(spacing: 8) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        historyEntry(entry)

                        if index < visibleEntries.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .onAppear {
                    model.updateOverlayHistoryVisibleCount(visibleCount)
                }
                .onChange(of: visibleCount) { _, newCount in
                    model.updateOverlayHistoryVisibleCount(newCount)
                }
                .onChange(of: state.history.count) { _, _ in
                    model.updateOverlayHistoryVisibleCount(visibleCount)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    // MARK: - Committed caption layer (main display, fades in on each new sentence)

    @ViewBuilder
    private func committedLayer(_ state: OverlayPreviewState) -> some View {
        VStack(spacing: 4) {
            if model.overlayStyle.translatedFirst {
                translatedText(for: state)
                sourceText(for: state)
            } else {
                sourceText(for: state)
                translatedText(for: state)
            }
        }
        .opacity(committedOpacity)
        .onChange(of: state.captionEpoch) { _, _ in
            if state.skipCommittedFadeIn {
                // Draft translation was visible — replace instantly, no flash.
                committedOpacity = 1.0
            } else {
                committedOpacity = 0.0
                withAnimation(.easeOut(duration: 0.3)) {
                    committedOpacity = 1.0
                }
            }
        }
    }

    private func translatedText(for state: OverlayPreviewState) -> some View {
        Text(state.translatedText)
            .font(.system(size: model.overlayStyle.scaledTranslatedFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    private func sourceText(for state: OverlayPreviewState) -> some View {
        Text(state.sourceText)
            .font(.system(size: model.overlayStyle.scaledSourceFontSize, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Draft layer (50–65% opacity, stable prefix slightly brighter)

    @ViewBuilder
    private func draftLayer(_ state: OverlayPreviewState) -> some View {
        if let draftText = state.draftSourceText, !draftText.isEmpty {
            VStack(spacing: 2) {
                if let draftTranslated = state.draftTranslatedText, !draftTranslated.isEmpty {
                    Text(draftTranslated)
                        .font(.system(size: model.overlayStyle.scaledTranslatedFontSize, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                } else if model.shouldReserveDraftTranslationSlot {
                    Text(" ")
                        .font(.system(size: model.overlayStyle.scaledTranslatedFontSize, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                        .hidden()
                        .accessibilityHidden(true)
                }

                let prefixLen = min(state.draftStablePrefixLength, draftText.count)
                let stable = String(draftText.prefix(prefixLen))
                let mutable = String(draftText.dropFirst(prefixLen))

                (
                    Text(stable).foregroundStyle(Color.white.opacity(0.62))
                        + Text(mutable).foregroundStyle(Color.white.opacity(0.48))
                )
                .font(.system(size: model.overlayStyle.scaledSourceFontSize, weight: .regular))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func historyEntry(_ entry: OverlayHistoryEntry) -> some View {
        VStack(spacing: 3) {
            Text(entry.translatedText)
                .font(.system(size: model.overlayStyle.scaledTranslatedFontSize * 0.78, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            if entry.sourceText.isEmpty == false {
                Text(entry.sourceText)
                    .font(.system(size: model.overlayStyle.scaledSourceFontSize * 0.78, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func historyVisibleEntries(from history: [OverlayHistoryEntry], visibleCount: Int) -> [OverlayHistoryEntry] {
        let clampedVisibleCount = max(1, visibleCount)
        let maxOffset = max(0, history.count - clampedVisibleCount)
        let offset = min(max(model.overlayHistoryScrollOffset, 0), maxOffset)
        let upperBound = max(0, history.count - offset)
        let lowerBound = max(0, upperBound - clampedVisibleCount)
        return Array(history[lowerBound..<upperBound])
    }

    private func historyVisibleCount(for height: CGFloat) -> Int {
        let rowHeight = (model.overlayStyle.scaledTranslatedFontSize * 0.78)
            + (model.overlayStyle.scaledSourceFontSize * 0.78)
            + 24.0
        return max(1, Int((height / rowHeight).rounded(.down)))
    }

    // MARK: - Background

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(model.overlayStyle.backgroundOpacity))
    }

    @ViewBuilder
    private var passThroughBubble: some View {
        if let hint = renderedPassThroughBubble {
            OverlayPassThroughBubbleView()
                .frame(width: hint.diameter, height: hint.diameter)
                .position(x: hint.center.x, y: hint.center.y)
                .scaleEffect(0.92 + (0.08 * passThroughRevealProgress))
                .opacity(passThroughRevealProgress)
                .allowsHitTesting(false)
        }
    }

    private var passThroughMask: some View {
        Rectangle()
            .fill(Color.white)
            .overlay {
                if let hint = renderedPassThroughBubble {
                    Circle()
                        .fill(
                            RadialGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: 0.38),
                                    .init(color: .black.opacity(0.68), location: 0.58),
                                    .init(color: .black.opacity(0.28), location: 0.76),
                                    .init(color: .clear, location: 1.0)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: hint.diameter * 0.5
                            )
                        )
                        .frame(width: hint.diameter, height: hint.diameter)
                        .position(x: hint.center.x, y: hint.center.y)
                        .scaleEffect(0.92 + (0.08 * passThroughRevealProgress))
                        .opacity(passThroughRevealProgress)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }

    private func syncPassThroughBubble(_ bubble: OverlayPassThroughBubble?) {
        if let bubble {
            renderedPassThroughBubble = bubble

            guard passThroughRevealProgress < 1.0 else { return }
            withAnimation(Self.passThroughTransitionAnimation) {
                passThroughRevealProgress = 1.0
            }
            return
        }

        guard renderedPassThroughBubble != nil else { return }
        withAnimation(Self.passThroughTransitionAnimation) {
            passThroughRevealProgress = 0.0
        }
    }
}

private struct OverlayTranslationHostModifier: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        if model.sessionState == .running {
            content.v2sTranslationHost(model: model)
        } else {
            content
        }
    }
}

struct OverlayControlsChromeView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.black.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .frame(width: OverlayControlsLayout.stripSize.width, height: OverlayControlsLayout.stripSize.height)
    }
}

struct OverlayMoveButtonView: View {
    let onMoveDragStart: () -> Void
    let onMoveDragChanged: (CGSize) -> Void
    let onMoveDragEnded: () -> Void

    @State private var isMoveDragging = false

    var body: some View {
        OverlayDragHandle(
            onDragStart: {
                isMoveDragging = true
                onMoveDragStart()
            },
            onDragChanged: { translation in
                onMoveDragChanged(translation)
            },
            onDragEnded: {
                if isMoveDragging {
                    onMoveDragEnded()
                }
                isMoveDragging = false
            }
        )
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
        .background(Circle().fill(Color.white.opacity(0.12)))
        .overlay(
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .allowsHitTesting(false)
        )
    }
}

struct OverlayCloseButtonView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.stopSession() } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
    }
}

struct OverlayResizeButtonView: View {
    let onResizeDragStart: () -> Void
    let onResizeDragChanged: (CGSize) -> Void
    let onResizeDragEnded: () -> Void

    var body: some View {
        OverlayDragHandle(
            onDragStart: onResizeDragStart,
            onDragChanged: onResizeDragChanged,
            onDragEnded: onResizeDragEnded
        )
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
        .background(Circle().fill(Color.white.opacity(0.12)))
        .overlay(
            OverlayResizeGlyph()
                .frame(width: 10, height: 10)
                .allowsHitTesting(false)
        )
    }
}

struct OverlayHistoryScrollbarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var interactionState: OverlayInteractionState

    var body: some View {
        let revealProgress = interactionState.scrollbarRevealProgress
        let latestButtonRevealProgress = latestButtonRevealProgress(for: revealProgress)

        GeometryReader { proxy in
            let trackHeight = resolvedTrackHeight(
                in: proxy.size.height,
                latestButtonRevealProgress: latestButtonRevealProgress
            )
            let metrics = scrollbarMetrics(trackHeight: trackHeight)
            let trackWidth = resolvedTrackWidth(for: revealProgress)

            ZStack(alignment: .bottom) {
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(Color.white.opacity(0.035 + (0.055 * revealProgress)))
                        .frame(width: trackWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    Capsule()
                        .fill(
                            Color.white.opacity(
                                metrics.canScroll
                                    ? (0.28 + (0.32 * revealProgress))
                                    : (0.12 + (0.10 * revealProgress))
                            )
                        )
                        .frame(
                            width: trackWidth,
                            height: metrics.thumbHeight
                        )
                        .frame(maxWidth: .infinity, alignment: .top)
                        .offset(y: metrics.thumbTop)

                    OverlayHistoryScrollbarInputLayer(
                        currentOffset: model.overlayHistoryScrollOffset,
                        maxScrollOffset: metrics.maxScrollOffset,
                        thumbHeight: metrics.thumbHeight,
                        onOffsetChange: { model.setOverlayHistoryScrollOffset($0) },
                        onStepScroll: { model.scrollOverlayHistory(by: $0) }
                    )
                }
                .frame(height: trackHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                latestButton(revealProgress: latestButtonRevealProgress)
            }
            .animation(.easeOut(duration: 0.16), value: revealProgress)
            .animation(.easeOut(duration: 0.18), value: latestButtonRevealProgress)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.vertical, OverlayHistoryScrollbarLayout.verticalPadding)
    }

    private func scrollbarMetrics(trackHeight: CGFloat) -> OverlayHistoryScrollbarMetrics {
        let totalCount = max(model.overlayState?.history.count ?? 0, 0)
        let visibleCount = max(1, model.overlayHistoryVisibleCount)
        let maxScrollOffset = max(0, totalCount - visibleCount)
        let clampedTrackHeight = max(trackHeight, OverlayHistoryScrollbarLayout.minimumThumbHeight)
        let visibilityRatio = totalCount > 0
            ? min(1.0, CGFloat(visibleCount) / CGFloat(max(totalCount, visibleCount)))
            : 1.0
        let thumbHeight = max(
            OverlayHistoryScrollbarLayout.minimumThumbHeight,
            clampedTrackHeight * visibilityRatio
        )
        let travel = max(clampedTrackHeight - thumbHeight, 0)
        let progressFromTop: CGFloat

        if maxScrollOffset > 0 {
            progressFromTop = 1.0 - (CGFloat(model.overlayHistoryScrollOffset) / CGFloat(maxScrollOffset))
        } else {
            progressFromTop = 1.0
        }

        return OverlayHistoryScrollbarMetrics(
            maxScrollOffset: maxScrollOffset,
            thumbHeight: min(thumbHeight, clampedTrackHeight),
            thumbTop: travel * progressFromTop,
            canScroll: maxScrollOffset > 0
        )
    }

    private func resolvedTrackWidth(for revealProgress: CGFloat) -> CGFloat {
        OverlayHistoryScrollbarLayout.trackWidth
            + ((OverlayHistoryScrollbarLayout.expandedTrackWidth - OverlayHistoryScrollbarLayout.trackWidth) * revealProgress)
    }

    private func resolvedTrackHeight(in totalHeight: CGFloat, latestButtonRevealProgress: CGFloat) -> CGFloat {
        let reservedHeight = latestButtonReservedHeight(for: latestButtonRevealProgress)
        return max(totalHeight - reservedHeight, OverlayHistoryScrollbarLayout.minimumThumbHeight)
    }

    private func latestButtonReservedHeight(for revealProgress: CGFloat) -> CGFloat {
        let fullHeight = OverlayControlsLayout.controlSize + OverlayHistoryScrollbarLayout.buttonSpacing
        return fullHeight * revealProgress
    }

    private func latestButtonRevealProgress(for revealProgress: CGFloat) -> CGFloat {
        guard model.overlayHistoryScrollOffset > 0 else { return 0.0 }
        return revealProgress
    }

    private func latestButton(revealProgress: CGFloat) -> some View {
        Button {
            model.setOverlayHistoryScrollOffset(0)
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
        .frame(width: OverlayControlsLayout.controlSize, height: OverlayControlsLayout.controlSize)
        .opacity(revealProgress)
        .scaleEffect(0.9 + (0.1 * revealProgress))
        .allowsHitTesting(revealProgress > 0.05)
        .animation(.easeOut(duration: 0.16), value: revealProgress)
        .accessibilityLabel("Scroll to latest subtitle")
    }
}

enum OverlayControlsLayout {
    static let outerPadding: CGFloat = 4
    static let leadingInset: CGFloat = 10
    static let controlPaddingX: CGFloat = 5
    static let controlPaddingY: CGFloat = 7
    static let controlSize: CGFloat = 22
    static let controlSpacing: CGFloat = 6

    static var stripSize: CGSize {
        CGSize(
            width: controlSize + (controlPaddingX * 2),
            height: (controlSize * 3) + (controlSpacing * 2) + (controlPaddingY * 2)
        )
    }
}

enum OverlayHistoryScrollbarLayout {
    static let panelWidth: CGFloat = 28
    static let trackWidth: CGFloat = 4
    static let expandedTrackWidth: CGFloat = OverlayControlsLayout.controlSize
    static let contentSpacing: CGFloat = 10
    static let verticalPadding: CGFloat = 8
    static let buttonSpacing: CGFloat = 8
    static let minimumThumbHeight: CGFloat = 36

    static var panelSize: CGSize {
        CGSize(width: panelWidth, height: 120)
    }
}

private struct OverlayHistoryScrollbarMetrics {
    var maxScrollOffset: Int
    var thumbHeight: CGFloat
    var thumbTop: CGFloat
    var canScroll: Bool
}

private struct OverlayHistoryScrollbarInputLayer: NSViewRepresentable {
    let currentOffset: Int
    let maxScrollOffset: Int
    let thumbHeight: CGFloat
    let onOffsetChange: (Int) -> Void
    let onStepScroll: (Int) -> Void

    func makeNSView(context: Context) -> OverlayHistoryScrollbarInputView {
        let view = OverlayHistoryScrollbarInputView()
        view.currentOffset = currentOffset
        view.maxScrollOffset = maxScrollOffset
        view.thumbHeight = thumbHeight
        view.onOffsetChange = onOffsetChange
        view.onStepScroll = onStepScroll
        return view
    }

    func updateNSView(_ nsView: OverlayHistoryScrollbarInputView, context: Context) {
        nsView.currentOffset = currentOffset
        nsView.maxScrollOffset = maxScrollOffset
        nsView.thumbHeight = thumbHeight
        nsView.onOffsetChange = onOffsetChange
        nsView.onStepScroll = onStepScroll
    }
}

final class OverlayHistoryScrollbarInputView: NSView {
    var currentOffset = 0
    var maxScrollOffset = 0
    var thumbHeight: CGFloat = OverlayHistoryScrollbarLayout.minimumThumbHeight
    var onOffsetChange: ((Int) -> Void)?
    var onStepScroll: ((Int) -> Void)?

    private var isDraggingThumb = false

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDraggingThumb = true
        updateOffset(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingThumb else { return }
        updateOffset(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingThumb {
            updateOffset(for: event)
        }
        isDraggingThumb = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return }

        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }

        let divisor: CGFloat = event.hasPreciseScrollingDeltas ? 12.0 : 1.0
        let magnitude = max(1, Int((abs(delta) / divisor).rounded(.awayFromZero)))
        onStepScroll?(delta > 0 ? magnitude : -magnitude)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateOffset(for event: NSEvent) {
        guard maxScrollOffset > 0 else {
            onOffsetChange?(0)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        onOffsetChange?(resolvedOffset(forThumbCenterY: point.y))
    }

    private func resolvedOffset(forThumbCenterY thumbCenterY: CGFloat) -> Int {
        let clampedThumbHeight = min(max(thumbHeight, 0), bounds.height)
        let travel = max(bounds.height - clampedThumbHeight, 0)
        guard travel > 0 else { return 0 }

        let thumbTop = min(max(thumbCenterY - (clampedThumbHeight / 2), 0), travel)
        let progressFromBottom = 1.0 - (thumbTop / travel)
        return Int((progressFromBottom * CGFloat(maxScrollOffset)).rounded())
    }
}

private struct OverlayDragHandle: NSViewRepresentable {
    let onDragStart: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> OverlayDragHandleView {
        let view = OverlayDragHandleView()
        view.onDragStart = onDragStart
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: OverlayDragHandleView, context: Context) {
        nsView.onDragStart = onDragStart
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }
}

final class OverlayDragHandleView: NSView {
    var onDragStart: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartPointInScreen: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard let startPoint = screenPoint(for: event) else { return }
        dragStartPointInScreen = startPoint
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPointInScreen,
              let currentPoint = screenPoint(for: event) else {
            return
        }

        onDragChanged?(
            CGSize(
                width: currentPoint.x - dragStartPointInScreen.x,
                height: currentPoint.y - dragStartPointInScreen.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        if dragStartPointInScreen != nil {
            onDragEnded?()
        }
        dragStartPointInScreen = nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        guard let window else { return nil }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

private struct OverlayResizeGlyph: View {
    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            let color = Color.white.opacity(0.65)
            let start = CGPoint(x: 2, y: size.height - 2)
            let end = CGPoint(x: size.width - 2, y: 2)

            var diagonal = Path()
            diagonal.move(to: start)
            diagonal.addLine(to: end)
            context.stroke(diagonal, with: .color(color), style: stroke)

            var startHead = Path()
            startHead.move(to: start)
            startHead.addLine(to: CGPoint(x: start.x + 2.6, y: start.y))
            startHead.move(to: start)
            startHead.addLine(to: CGPoint(x: start.x, y: start.y - 2.6))
            context.stroke(startHead, with: .color(color), style: stroke)

            var endHead = Path()
            endHead.move(to: end)
            endHead.addLine(to: CGPoint(x: end.x - 2.6, y: end.y))
            endHead.move(to: end)
            endHead.addLine(to: CGPoint(x: end.x, y: end.y + 2.6))
            context.stroke(endHead, with: .color(color), style: stroke)
        }
    }
}

@MainActor
final class OverlayInteractionState: ObservableObject {
    @Published private(set) var passThroughBubble: OverlayPassThroughBubble?
    @Published private(set) var scrollbarRevealProgress: CGFloat = 0.0

    func updatePassThroughBubble(_ bubble: OverlayPassThroughBubble?) {
        guard needsUpdate(from: passThroughBubble, to: bubble) else { return }
        passThroughBubble = bubble
    }

    func updateScrollbarRevealProgress(_ progress: CGFloat) {
        let clampedProgress = min(max(progress, 0.0), 1.0)
        guard abs(scrollbarRevealProgress - clampedProgress) > 0.01 else { return }
        scrollbarRevealProgress = clampedProgress
    }

    private func needsUpdate(from current: OverlayPassThroughBubble?, to next: OverlayPassThroughBubble?) -> Bool {
        switch (current, next) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case let (.some(current), .some(next)):
            return abs(current.center.x - next.center.x) > 0.5
                || abs(current.center.y - next.center.y) > 0.5
                || abs(current.diameter - next.diameter) > 0.5
        }
    }
}

struct OverlayPassThroughBubble: Equatable {
    var center: CGPoint
    var diameter: CGFloat
}

private struct OverlayPassThroughBubbleView: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.42),
                        .init(color: Color.black.opacity(0.12), location: 0.68),
                        .init(color: Color.black.opacity(0.07), location: 0.84),
                        .init(color: .clear, location: 1.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 58
                )
            )
            .blur(radius: 1.6)
    }
}

private extension OverlayView {
    static let passThroughTransitionDuration: Double = 0.18
    static let passThroughTransitionAnimation = Animation.easeOut(duration: passThroughTransitionDuration)
}
