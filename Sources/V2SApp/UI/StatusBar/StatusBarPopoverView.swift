import SwiftUI

struct StatusBarPopoverView: View {
    @ObservedObject var model: AppModel
    let closePopover: () -> Void
    let openAdvancedSettings: () -> Void
    let showTranscript: () -> Void
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
                VStack(alignment: .trailing, spacing: 4) {
                    VersionLink(
                        versionText: model.appVersionDisplayText,
                        repositoryURL: model.appRepositoryURL,
                        font: .caption2.monospacedDigit()
                    )
                    Text(model.sessionBadgeText)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.fill.tertiary, in: Capsule())
                }
            }
            Button {
                model.toggleSession()
            } label: {
                SessionActionButtonLabel(
                    title: model.sessionButtonTitle,
                    symbolName: model.sessionButtonSymbolName,
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
            SettingsControlRow(label: model.localized(.sourceShort)) {
                SourceMenuPicker(
                    sources: model.allSources,
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    emptyTitle: model.allSources.isEmpty ? model.localized(.noSources) : model.localized(.choose),
                    selection: model.selectedSourceOptionalBinding
                )
            }
            SecondaryRefreshButton(
                title: model.localized(.refreshSources),
                action: model.refreshSources
            )
        }
    }

    // MARK: - Languages

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.languages), icon: "globe")
            SettingsControlRow(label: model.localized(.inputShort)) {
                CommonLanguageMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    selection: model.inputLanguageSelectionBinding
                )
                .disabled(model.isLanguagePairLocked)
            }
            SettingsControlRow(label: model.localized(.subtitleShort)) {
                CommonLanguageMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    selection: model.outputLanguageSelectionBinding
                )
                .disabled(model.isLanguagePairLocked)
            }
            SettingsControlRow(label: model.localized(.modeShort)) {
                SubtitleModeMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    showsDetail: false,
                    selection: model.subtitleModeSelectionBinding
                )
            }
            SettingsControlRow(label: model.localized(.displayShort)) {
                SubtitleDisplayModeMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    selection: model.subtitleDisplayModeSelectionBinding
                )
            }
            LanguageResourcesFooter(model: model)
        }
    }

    // MARK: - Overlay

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(model.localized(.overlay), icon: "rectangle.on.rectangle")
                Spacer()
                Button {
                    showTranscript()
                } label: {
                    Text(model.localized(.transcript))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                SettingsControlRow(label: model.localized(.textOutline)) {
                    Toggle("", isOn: textOutlineEnabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                SettingsControlRow(label: model.localized(.attachToSource)) {
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
    private var textOutlineEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.overlayStyle.showsTextOutline },
            set: { v in model.updateOverlayStyle { $0.showsTextOutline = v } }
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

struct VersionLink: View {
    @Environment(\.openURL) private var openURL

    let versionText: String
    let repositoryURL: URL?
    let font: Font

    var body: some View {
        Group {
            if let repositoryURL {
                Button {
                    openURL(repositoryURL)
                } label: {
                    versionLabel
                }
                .buttonStyle(.plain)
                .help(repositoryURL.absoluteString)
            } else {
                versionLabel
                    .help(versionText)
            }
        }
    }

    private var versionLabel: some View {
        Text(verbatim: versionText)
            .font(font)
            .foregroundStyle(.tertiary)
    }
}
