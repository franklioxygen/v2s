import SwiftUI

struct StatusBarPopoverView: View {
    @ObservedObject var model: AppModel
    let closePopover: () -> Void
    let openAdvancedSettings: () -> Void
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
        .environment(\.locale, model.interfaceLocale)
        .v2sTranslationHost(model: model)
        .onChange(of: model.sessionState) { _, newState in
            if newState == .running {
                closePopover()
            }
        }
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
                model.toggleSession()
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
        GroupBox {
            VStack(spacing: 8) {
                row(model.localized(.sourceShort)) {
                    Picker("", selection: selectedSourceBinding) {
                        Text(model.allSources.isEmpty ? model.localized(.noSources) : model.localized(.choose))
                            .tag(nil as String?)
                        ForEach(model.allSources) { s in
                            Text("\(s.category.displayName(in: model.resolvedInterfaceLanguageID)) · \(s.name)")
                                .tag(Optional(s.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: Self.pickerW)
                }
                row(nil) {
                    Button(model.localized(.refreshSources)) { model.refreshSources() }
                        .buttonStyle(.bordered)
                        .frame(width: Self.pickerW)
                }
            }
        } label: {
            Text(model.localized(.inputSource))
        }
    }

    // MARK: - Languages

    private var languageSection: some View {
        GroupBox {
            VStack(spacing: 8) {
                row(model.localized(.inputShort)) {
                    Picker("", selection: inputLanguageBinding) {
                        ForEach(LanguageCatalog.common) { option in
                            Text(option.localizedDisplayName(in: model.resolvedInterfaceLanguageID)).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(width: Self.pickerW)
                }
                row(model.localized(.subtitleShort)) {
                    Picker("", selection: outputLanguageBinding) {
                        ForEach(LanguageCatalog.common) { option in
                            Text(option.localizedDisplayName(in: model.resolvedInterfaceLanguageID)).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(width: Self.pickerW)
                }
                row(model.localized(.modeShort)) {
                    Picker("", selection: subtitleModeBinding) {
                        ForEach(SubtitleMode.allCases, id: \.self) { mode in
                            Text(mode.displayName(in: model.resolvedInterfaceLanguageID)).tag(mode)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(width: Self.pickerW)
                }
                row(nil) {
                    Button(model.localized(.refreshLanguageResources)) {
                        model.refreshLanguageResources()
                    }
                    .buttonStyle(.bordered)
                    .frame(width: Self.pickerW)
                }

                if model.languageResourceStatuses.isEmpty == false {
                    row(nil) {
                        LanguageResourceStatusListView(statuses: model.languageResourceStatuses)
                            .frame(width: Self.pickerW, alignment: .leading)
                    }
                }
            }
        } label: {
            Text(model.localized(.languages))
        }
    }

    // MARK: - Overlay

    private var overlaySection: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack {
                    Button(model.isOverlayVisible ? model.localized(.hideOverlay) : model.localized(.showPreview)) {
                        if model.isOverlayVisible { model.toggleOverlayVisibility() }
                        else { model.showOverlayPreview() }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text(model.localized(.controlsOnly))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(model.localized(.textOutline), isOn: whiteTextOutlineBinding)
                    .toggleStyle(.switch)
                Toggle(model.localized(.attachToSource), isOn: attachToSourceBinding)
                    .toggleStyle(.switch)
                sliderRow(
                    label: model.localized(.opacity),
                    value: overlayOpacityBinding, in: 0.0 ... 1.0,
                    display: "\(Int((model.overlayStyle.backgroundOpacity * 100).rounded()))%"
                )
                sliderRow(
                    label: model.localized(.fontSize),
                    value: translatedFontBinding, in: 8 ... 34,
                    display: "\(Int(model.overlayStyle.translatedFontSize.rounded()))pt"
                )
                sliderRow(
                    label: model.localized(.sourceSize),
                    value: sourceFontBinding, in: 5 ... 28,
                    display: "\(Int(model.overlayStyle.sourceFontSize.rounded()))pt"
                )
            }
        } label: {
            Text(model.localized(.overlay))
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(model.localized(.advancedSettings)) { openAdvancedSettings() }.buttonStyle(.bordered)
            Button(model.localized(.quit)) { quitApp() }.buttonStyle(.bordered)
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
    private var attachToSourceBinding: Binding<Bool> {
        Binding(
            get: { model.overlayStyle.attachToSource },
            set: { v in model.updateOverlayStyle { $0.attachToSource = v } }
        )
    }
    private var sourceFontBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.sourceFontSize },
            set: { v in model.updateOverlayStyle { $0.sourceFontSize = v } }
        )
    }
}
