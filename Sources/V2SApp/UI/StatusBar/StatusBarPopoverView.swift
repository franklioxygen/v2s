import SwiftUI

struct StatusBarPopoverView: View {
    @ObservedObject var model: AppModel
    let closePopover: () -> Void
    let openAdvancedSettings: () -> Void
    let quitApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sourceSection
                    languageSection
                    overlaySection
                }
                .padding(16)
            }
            Divider().padding(.horizontal, 16)
            footerSection
        }
        .frame(width: 340)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Image(systemName: "captions.bubble.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("v2s")
                        .font(.headline)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(model.sessionBadgeText)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: Capsule())
            }
            Button {
                model.toggleSession()
            } label: {
                SessionActionButtonLabel(
                    title: model.sessionButtonTitle,
                    showsActivity: model.showsSessionWaitIndicator
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isSessionButtonDisabled)
        }
        .padding(16)
    }

    // MARK: - Input Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.inputSource), icon: "mic.fill")
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
            }
            HStack {
                Spacer()
                Button {
                    model.refreshSources()
                } label: {
                    Label(model.localized(.refreshSources), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Languages

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.languages), icon: "globe")
            row(model.localized(.inputShort)) {
                Picker("", selection: inputLanguageBinding) {
                    ForEach(LanguageCatalog.common) { option in
                        Text(option.localizedDisplayName(in: model.resolvedInterfaceLanguageID)).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            row(model.localized(.subtitleShort)) {
                Picker("", selection: outputLanguageBinding) {
                    ForEach(LanguageCatalog.common) { option in
                        Text(option.localizedDisplayName(in: model.resolvedInterfaceLanguageID)).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            row(model.localized(.modeShort)) {
                Picker("", selection: subtitleModeBinding) {
                    ForEach(SubtitleMode.allCases, id: \.self) { mode in
                        Text(mode.displayName(in: model.resolvedInterfaceLanguageID)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            HStack {
                Spacer()
                Button {
                    model.refreshLanguageResources()
                } label: {
                    Label(model.localized(.refreshLanguageResources), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if !model.languageResourceStatuses.isEmpty {
                LanguageResourceStatusListView(statuses: model.languageResourceStatuses)
            }
        }
    }

    // MARK: - Overlay

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(model.localized(.overlay), icon: "rectangle.on.rectangle")
                Spacer()
                Button {
                    if model.isOverlayVisible { model.toggleOverlayVisibility() }
                    else { model.showOverlayPreview() }
                } label: {
                    Text(model.isOverlayVisible ? model.localized(.hideOverlay) : model.localized(.showPreview))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            VStack(spacing: 6) {
                row(model.localized(.textOutline)) {
                    Toggle("", isOn: whiteTextOutlineBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                row(model.localized(.attachToSource)) {
                    Toggle("", isOn: attachToSourceBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            VStack(spacing: 8) {
                compactSlider(
                    label: model.localized(.opacity),
                    value: overlayOpacityBinding, in: 0.0 ... 1.0,
                    display: "\(Int((model.overlayStyle.backgroundOpacity * 100).rounded()))%"
                )
                compactSlider(
                    label: model.localized(.fontSize),
                    value: translatedFontBinding, in: 8 ... 34,
                    display: "\(Int(model.overlayStyle.translatedFontSize.rounded()))pt"
                )
                compactSlider(
                    label: model.localized(.sourceSize),
                    value: sourceFontBinding, in: 5 ... 28,
                    display: "\(Int(model.overlayStyle.sourceFontSize.rounded()))pt"
                )
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button { openAdvancedSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.localized(.advancedSettings))
            Button { quitApp() } label: {
                Text(model.localized(.quit))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            if let s = model.selectedSource {
                Text(s.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            control()
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func compactSlider(
        label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
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
