import SwiftUI

struct StatusBarPopoverView: View {
    @ObservedObject var model: AppModel
    let closePopover: () -> Void
    let openSettings: () -> Void
    let quitApp: () -> Void

    // All pickers use this one constant → identical width + right edges align.
    // Derivation: 380 (popover) − 32 (padding) − 18 (GroupBox insets) − 64 (label) − 10 (gap) ≈ 256
    private static let pickerW: CGFloat = 246
    private let labelW: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            sourceSection
            languageSection
            overlaySection
            footerSection
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("v2s").font(.headline)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.sessionBadgeText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            Button {
                let shouldCloseAfterStart = model.sessionState != .running
                model.toggleSession()
                if shouldCloseAfterStart {
                    closePopover()
                }
            } label: {
                SessionActionButtonLabel(
                    title: model.sessionButtonTitle,
                    showsActivity: model.showsSessionWaitIndicator
                )
            }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSessionButtonDisabled)
        }
    }

    // MARK: - Input Source

    private var sourceSection: some View {
        GroupBox("Input Source") {
            VStack(spacing: 8) {
                row("Source") {
                    Picker("", selection: selectedSourceBinding) {
                        Text(model.allSources.isEmpty ? "No sources" : "Choose…")
                            .tag(nil as String?)
                        ForEach(model.allSources) { s in
                            Text("\(s.category.displayName) · \(s.name)")
                                .tag(Optional(s.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: Self.pickerW)
                }
                row(nil) {
                    Button("Refresh Sources") { model.refreshSources() }
                        .buttonStyle(.bordered)
                        .frame(width: Self.pickerW)
                }
            }
        }
    }

    // MARK: - Languages

    private var languageSection: some View {
        GroupBox("Languages") {
            VStack(spacing: 8) {
                row("Input") {
                    Picker("", selection: inputLanguageBinding) {
                        ForEach(LanguageCatalog.common) { o in Text(o.displayName).tag(o.id) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(width: Self.pickerW)
                }
                row("Subtitle") {
                    Picker("", selection: outputLanguageBinding) {
                        ForEach(LanguageCatalog.common) { o in Text(o.displayName).tag(o.id) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(width: Self.pickerW)
                }
                row("Mode") {
                    Picker("", selection: subtitleModeBinding) {
                        ForEach(SubtitleMode.allCases, id: \.self) { m in Text(m.displayName).tag(m) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(width: Self.pickerW)
                }

                if model.languageResourceStatuses.isEmpty == false {
                    row(nil) {
                        LanguageResourceStatusListView(statuses: model.languageResourceStatuses)
                            .frame(width: Self.pickerW, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Overlay

    private var overlaySection: some View {
        GroupBox("Overlay") {
            VStack(spacing: 10) {
                HStack {
                    Button(model.isOverlayVisible ? "Hide Overlay" : "Show Preview") {
                        if model.isOverlayVisible { model.toggleOverlayVisibility() }
                        else { model.showOverlayPreview() }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text("Controls Only")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("1 px White Text Outline", isOn: whiteTextOutlineBinding)
                sliderRow(
                    label: "Opacity",
                    value: overlayOpacityBinding, in: 0.0 ... 1.0,
                    display: "\(Int((model.overlayStyle.backgroundOpacity * 100).rounded()))%"
                )
                sliderRow(
                    label: "Font Size",
                    value: translatedFontBinding, in: 16 ... 34,
                    display: "\(Int(model.overlayStyle.translatedFontSize.rounded()))pt"
                )
                sliderRow(
                    label: "Source Size",
                    value: sourceFontBinding, in: 14 ... 28,
                    display: "\(Int(model.overlayStyle.sourceFontSize.rounded()))pt"
                )
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Open Settings") { openSettings() }.buttonStyle(.bordered)
            Button("Quit") { quitApp() }.buttonStyle(.bordered)
            Spacer()
            if let s = model.selectedSource {
                Text(s.name).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Layout helpers

    /// Trailing-aligned label + Spacer + fixed-width control flush to right edge.
    @ViewBuilder
    private func row<C: View>(_ label: String?, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 10) {
            if let label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: labelW, alignment: .trailing)
            } else {
                Spacer().frame(width: labelW)
            }
            Spacer(minLength: 0)
            control()
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        display: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelW, alignment: .trailing)
            Text(display)
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    // MARK: - Bindings

    private var selectedSourceBinding: Binding<String?> {
        Binding(get: { model.selectedSourceID }, set: { model.selectedSourceID = $0 })
    }
    private var inputLanguageBinding: Binding<String> {
        Binding(get: { model.inputLanguageID }, set: { model.inputLanguageID = $0 })
    }
    private var outputLanguageBinding: Binding<String> {
        Binding(get: { model.outputLanguageID }, set: { model.outputLanguageID = $0 })
    }
    private var subtitleModeBinding: Binding<SubtitleMode> {
        Binding(get: { model.subtitleMode }, set: { model.subtitleMode = $0 })
    }
    private var overlayOpacityBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.backgroundOpacity },
            set: { v in model.updateOverlayStyle { $0.backgroundOpacity = v } }
        )
    }
    private var translatedFontBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.translatedFontSize },
            set: { v in model.updateOverlayStyle { $0.translatedFontSize = v } }
        )
    }
    private var whiteTextOutlineBinding: Binding<Bool> {
        Binding(
            get: { model.overlayStyle.usesWhiteTextOutline },
            set: { v in model.updateOverlayStyle { $0.usesWhiteTextOutline = v } }
        )
    }
    private var sourceFontBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.sourceFontSize },
            set: { v in model.updateOverlayStyle { $0.sourceFontSize = v } }
        )
    }
}
