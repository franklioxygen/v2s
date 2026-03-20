import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var interactionState: OverlayInteractionState
    @Namespace private var captionFlowNamespace
    @State private var renderedPassThroughBubble: OverlayPassThroughBubble?
    @State private var passThroughRevealProgress: Double = 0.0
    @State private var lastDraftSlotHeight: CGFloat = 0.0

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
                GeometryReader { proxy in
                    let visibleHistoryCount = historyVisibleCount(for: proxy.size.height, state: state)
                    let visibleHistoryEntries = historyVisibleEntries(
                        from: state.history,
                        visibleCount: visibleHistoryCount
                    )

                    VStack(alignment: .center, spacing: 10) {
                        ForEach(Array(visibleHistoryEntries.enumerated()), id: \.element.id) { index, entry in
                            historyEntry(
                                entry,
                                index: index,
                                totalCount: visibleHistoryEntries.count
                            )
                        }

                        if hasCommittedCaption(state) {
                            committedLayer(state)
                        }

                        draftLayer(state)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .mask(continuousFlowMask)
                    .animation(Self.captionFlowAnimation, value: flowAnimationState(for: state))
                    .onPreferenceChange(DraftSlotHeightPreferenceKey.self) { height in
                        guard height > 0 else { return }
                        let snappedHeight = ceil(height)
                        let downwardDelta = lastDraftSlotHeight - snappedHeight

                        if lastDraftSlotHeight == 0
                            || snappedHeight >= lastDraftSlotHeight
                            || downwardDelta >= Self.draftHeightJitterTolerance {
                            lastDraftSlotHeight = snappedHeight
                        }
                    }
                    .onAppear {
                        model.updateOverlayHistoryVisibleCount(visibleHistoryCount)
                    }
                    .onChange(of: visibleHistoryCount) { _, newCount in
                        model.updateOverlayHistoryVisibleCount(newCount)
                    }
                    .onChange(of: state.history.count) { _, _ in
                        model.updateOverlayHistoryVisibleCount(visibleHistoryCount)
                    }
                    .onChange(of: model.sessionState) { _, newState in
                        if newState != .running {
                            lastDraftSlotHeight = 0
                        }
                    }
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

    // MARK: - Continuous flow

    private func committedLayer(_ state: OverlayPreviewState) -> some View {
        applyingPromotionTransition(
            to: captionPair(
                translated: state.translatedText,
                translatedColor: baseSubtitleColor,
                source: state.sourceText,
                sourceColor: subtitleColor(opacity: 0.82)
            ),
            key: promotionKey(
                sourceText: state.sourceText,
                translatedText: state.translatedText
            )
        )
    }

    private func translatedText(_ text: String, color: Color) -> some View {
        captionText(
            attributedCaptionText(
                text: text,
                fillColor: color
            ),
            rawText: text,
            fontSize: model.overlayStyle.scaledTranslatedFontSize,
            weight: .semibold
        )
    }

    private func sourceText(_ text: String, color: Color) -> some View {
        captionText(
            attributedCaptionText(
                text: text,
                fillColor: color
            ),
            rawText: text,
            fontSize: model.overlayStyle.scaledSourceFontSize,
            weight: .regular
        )
    }

    // MARK: - Draft layer (50–65% opacity, stable prefix slightly brighter)

    private func draftLayer(_ state: OverlayPreviewState) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let draftText = state.draftSourceText, !draftText.isEmpty {
                applyingPromotionTransition(
                    to: VStack(spacing: 2) {
                    if let draftTranslated = state.draftTranslatedText, !draftTranslated.isEmpty {
                        translatedText(
                            draftTranslated,
                            color: subtitleColor(opacity: 0.55)
                        )
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

                    captionText(
                        draftSourceAttributedText(
                            stable: stable,
                            mutable: mutable
                        ),
                        rawText: draftText,
                        fontSize: model.overlayStyle.scaledSourceFontSize,
                        weight: .regular
                    )
                }
                .background(draftSlotHeightReader),
                    key: promotionKey(
                        sourceText: draftText,
                        translatedText: state.draftTranslatedText ?? draftText
                    )
                )
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: draftSlotHeight(for: state),
            maxHeight: draftSlotHeight(for: state),
            alignment: .top
        )
    }

    private func historyEntry(
        _ entry: OverlayHistoryEntry,
        index: Int,
        totalCount: Int
    ) -> some View {
        let ageProgress = totalCount > 1
            ? Double(index) / Double(totalCount - 1)
            : 1.0
        let translatedOpacity = 0.34 + (0.34 * ageProgress)
        let sourceOpacity = 0.22 + (0.24 * ageProgress)

        return captionPair(
            translated: entry.translatedText,
            translatedColor: subtitleColor(opacity: translatedOpacity),
            source: entry.sourceText,
            sourceColor: subtitleColor(opacity: sourceOpacity)
        )
    }

    private func historyVisibleEntries(from history: [OverlayHistoryEntry], visibleCount: Int) -> [OverlayHistoryEntry] {
        let clampedVisibleCount = max(1, visibleCount)
        let maxOffset = max(0, history.count - clampedVisibleCount)
        let offset = min(max(model.overlayHistoryScrollOffset, 0), maxOffset)
        let upperBound = max(0, history.count - offset)
        let lowerBound = max(0, upperBound - clampedVisibleCount)
        return Array(history[lowerBound..<upperBound])
    }

    private func historyVisibleCount(for height: CGFloat, state: OverlayPreviewState) -> Int {
        let availableHeight = max(height - reservedFlowHeight(for: state), 0)
        return max(1, Int((availableHeight / historyRowHeight).rounded(.down)))
    }

    private func reservedFlowHeight(for state: OverlayPreviewState) -> CGFloat {
        var reservedHeight: CGFloat = 0

        if hasCommittedCaption(state) {
            reservedHeight += committedRowHeight
        }

        reservedHeight += draftSlotHeight(for: state)

        if hasCommittedCaption(state) {
            reservedHeight += 10
        }

        return reservedHeight
    }

    private func hasCommittedCaption(_ state: OverlayPreviewState) -> Bool {
        state.translatedText.isEmpty == false || state.sourceText.isEmpty == false
    }

    private func flowAnimationState(for state: OverlayPreviewState) -> OverlayFlowAnimationState {
        OverlayFlowAnimationState(
            captionEpoch: state.captionEpoch,
            translatedText: state.translatedText,
            sourceText: state.sourceText,
            historyIDs: state.history.map(\.id)
        )
    }

    private var historyRowHeight: CGFloat {
        CGFloat(model.overlayStyle.scaledTranslatedFontSize + model.overlayStyle.scaledSourceFontSize + 22.0)
    }

    private var committedRowHeight: CGFloat {
        historyRowHeight
    }

    private func draftSlotHeight(for state: OverlayPreviewState) -> CGFloat {
        max(lastDraftSlotHeight, estimatedDraftRowHeight(for: state))
    }

    private func estimatedDraftRowHeight(for state: OverlayPreviewState) -> CGFloat {
        let translatedHeight = (
            (state.draftTranslatedText?.isEmpty == false) || model.shouldReserveDraftTranslationSlot
        )
            ? CGFloat(model.overlayStyle.scaledTranslatedFontSize + 10.0)
            : 0
        let sourceHeight = CGFloat(model.overlayStyle.scaledSourceFontSize + 14.0)
        return translatedHeight + sourceHeight
    }

    private var draftSlotHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: DraftSlotHeightPreferenceKey.self, value: proxy.size.height)
        }
    }

    private func promotionKey(sourceText: String, translatedText: String) -> String? {
        let normalizedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSource.isEmpty == false {
            return "live-caption:\(normalizedSource)"
        }

        let normalizedTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTranslation.isEmpty == false else { return nil }
        return "live-caption:\(normalizedTranslation)"
    }

    @ViewBuilder
    private func applyingPromotionTransition<Content: View>(
        to content: Content,
        key: String?
    ) -> some View {
        if let key {
            content.matchedGeometryEffect(
                id: key,
                in: captionFlowNamespace,
                properties: .frame,
                anchor: .bottom
            )
        } else {
            content
        }
    }

    private func captionPair(
        translated: String,
        translatedColor: Color,
        source: String,
        sourceColor: Color
    ) -> some View {
        VStack(spacing: Self.captionPairSpacing) {
            if model.overlayStyle.translatedFirst {
                translatedText(
                    translated,
                    color: translatedColor
                )

                if source.isEmpty == false {
                    sourceText(
                        source,
                        color: sourceColor
                    )
                }
            } else {
                if source.isEmpty == false {
                    sourceText(
                        source,
                        color: sourceColor
                    )
                }

                translatedText(
                    translated,
                    color: translatedColor
                )
            }
        }
    }

    private var continuousFlowMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .white.opacity(0.8), location: 0.10),
                .init(color: .white, location: 0.22),
                .init(color: .white, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Background

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(baseBackgroundColor.opacity(model.overlayStyle.backgroundOpacity))
    }

    private func captionText(
        _ attributedText: AttributedString,
        rawText: String,
        fontSize: Double,
        weight: Font.Weight
    ) -> some View {
        ZStack {
            if model.overlayStyle.usesWhiteTextOutline, rawText.isEmpty == false {
                outlineText(
                    rawText,
                    fontSize: fontSize,
                    weight: weight
                )
            }

            Text(attributedText)
                .font(.system(size: fontSize, weight: weight))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private func attributedCaptionText(
        text: String,
        fillColor: Color
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = fillColor
        return attributed
    }

    private func draftSourceAttributedText(
        stable: String,
        mutable: String
    ) -> AttributedString {
        var attributed = AttributedString()

        if stable.isEmpty == false {
            var stablePart = AttributedString(stable)
            stablePart.foregroundColor = subtitleColor(opacity: 0.62)
            attributed += stablePart
        }

        if mutable.isEmpty == false {
            var mutablePart = AttributedString(mutable)
            mutablePart.foregroundColor = subtitleColor(opacity: 0.48)
            attributed += mutablePart
        }

        return attributed
    }

    private func outlineText(
        _ text: String,
        fontSize: Double,
        weight: Font.Weight
    ) -> some View {
        ZStack {
            ForEach(Self.textOutlineOffsets.indices, id: \.self) { index in
                let offset = Self.textOutlineOffsets[index]
                Text(text)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .offset(x: offset.width, y: offset.height)
            }
        }
    }

    private var baseSubtitleColor: Color {
        model.overlayStyle.subtitleColor.color
    }

    private var baseBackgroundColor: Color {
        model.overlayStyle.backgroundColor.color
    }

    private func subtitleColor(opacity: Double) -> Color {
        baseSubtitleColor.opacity(opacity)
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

private extension OverlayView {
    static let captionFlowAnimation = Animation.interactiveSpring(
        response: 0.32,
        dampingFraction: 0.88,
        blendDuration: 0.08
    )
    static let draftHeightJitterTolerance: CGFloat = 6.0
    static let captionPairSpacing: CGFloat = 4.0
    static let textOutlineOffsets: [CGSize] = [
        CGSize(width: -1, height: 0),
        CGSize(width: 1, height: 0),
        CGSize(width: 0, height: -1),
        CGSize(width: 0, height: 1),
        CGSize(width: -1, height: -1),
        CGSize(width: -1, height: 1),
        CGSize(width: 1, height: -1),
        CGSize(width: 1, height: 1)
    ]
}

private struct OverlayFlowAnimationState: Equatable {
    let captionEpoch: Int
    let translatedText: String
    let sourceText: String
    let historyIDs: [UUID]
}

private struct DraftSlotHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0.0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct OverlayTranslationHostModifier: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        // Translation resource preparation can begin before the live session
        // flips to `.running`, so keep a host attached for the lifetime of the overlay view.
        content.v2sTranslationHost(model: model)
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
        .accessibilityLabel(model.localized(.scrollToLatestSubtitle))
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
