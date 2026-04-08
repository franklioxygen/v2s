import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updaterService: UpdaterService
    @ObservedObject var launchAtLoginService: LaunchAtLoginService
    let closeSettings: () -> Void
    let quitApp: () -> Void
    let openSubtitleModeInfo: () -> Void
    let showTranscript: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            TabView {
                generalTab
                    .tabItem { Label(model.localized(.general), systemImage: "gearshape") }
                overlayTab
                    .tabItem { Label(model.localized(.subtitleOverlay), systemImage: "rectangle.on.rectangle") }
                glossaryTab
                    .tabItem { Label(model.localized(.glossary), systemImage: "text.book.closed") }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .environment(\.locale, model.interfaceLocale)
        .v2sTranslationHost(model: model)
        .onChange(of: model.sessionState) { _, newState in
            if newState == .running {
                closeSettings()
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.localized(.advancedSettings))
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(sessionDotColor)
                        .frame(width: 7, height: 7)
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                model.toggleSession()
            } label: {
                SessionActionButtonLabel(
                    title: model.sessionButtonTitle,
                    symbolName: model.sessionButtonSymbolName,
                    showsActivity: model.showsSessionWaitIndicator
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.isSessionButtonDisabled)
            Button(model.localized(.showSubtitlePreview)) {
                model.showOverlayPreview()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            Button(model.localized(.transcript)) {
                showTranscript()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            Button { quitApp() } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.localized(.quit))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var sessionDotColor: Color {
        switch model.sessionState {
        case .idle: return .secondary
        case .running: return .green
        case .error: return .red
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsCard {
                    sectionHeader(model.localized(.general), icon: "slider.horizontal.3")
                    settingsRow(model.localized(.sessionState)) {
                        Text(model.sessionBadgeText)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    SettingsControlRow(label: model.localized(.interfaceLanguage)) {
                        CommonLanguageMenuPicker(
                            interfaceLanguageID: model.resolvedInterfaceLanguageID,
                            selection: model.interfaceLanguageSelectionBinding
                        )
                    }
                }
                settingsCard {
                    sectionHeader(model.localized(.inputSource), icon: "mic.fill")
                    SettingsControlRow(label: model.localized(.selectedSource)) {
                        SourceMenuPicker(
                            sources: model.allSources,
                            interfaceLanguageID: model.resolvedInterfaceLanguageID,
                            emptyTitle: model.allSources.isEmpty
                                ? model.localized(.noSourcesDetected)
                                : model.localized(.choose),
                            selection: model.selectedSourceOptionalBinding
                        )
                    }
                    SecondaryRefreshButton(
                        title: model.localized(.refreshSources),
                        action: model.refreshSources
                    )
                }
                settingsCard {
                    sectionHeader(model.localized(.languages), icon: "globe")
                    SettingsControlRow(label: model.localized(.inputLanguage)) {
                        CommonLanguageMenuPicker(
                            interfaceLanguageID: model.resolvedInterfaceLanguageID,
                            selection: model.inputLanguageSelectionBinding
                        )
                        .disabled(model.isLanguagePairLocked)
                    }
                    Divider()
                    SettingsControlRow(label: model.localized(.subtitleLanguage)) {
                        CommonLanguageMenuPicker(
                            interfaceLanguageID: model.resolvedInterfaceLanguageID,
                            selection: model.outputLanguageSelectionBinding
                        )
                        .disabled(model.isLanguagePairLocked)
                    }
                    Divider()
                    SettingsControlRow(label: model.localized(.subtitleMode)) {
                        HStack(spacing: 4) {
                            SubtitleModeMenuPicker(
                                interfaceLanguageID: model.resolvedInterfaceLanguageID,
                                showsDetail: true,
                                selection: model.subtitleModeSelectionBinding
                            )
                            Button(action: openSubtitleModeInfo) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(model.localized(.subtitleModeHelp))
                        }
                    }
                    Divider()
                    SettingsControlRow(label: model.localized(.subtitleDisplay)) {
                        SubtitleDisplayModeMenuPicker(
                            interfaceLanguageID: model.resolvedInterfaceLanguageID,
                            selection: model.subtitleDisplayModeSelectionBinding
                        )
                    }
                    LanguageResourcesFooter(model: model)
                }
                settingsCard {
                    sectionHeader(model.localized(.updates), icon: "arrow.triangle.2.circlepath")
                    settingsRow(model.localized(.openAtLogin)) {
                        Toggle("", isOn: launchAtLoginBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Divider()
                    settingsRow(model.localized(.checkForUpdatesAutomatically)) {
                        Toggle("", isOn: $updaterService.automaticallyChecksForUpdates)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    if launchAtLoginService.requiresApproval {
                        Text(model.localized(.enableAtLoginInSystemSettings))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button {
                                launchAtLoginService.openLoginItems()
                            } label: {
                                Label(model.localized(.openLoginItems), systemImage: "gearshape")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if let updateErrorMessage = launchAtLoginService.updateErrorMessage {
                        Text(model.localized(.launchAtLoginUpdateFailedFormat, updateErrorMessage))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button {
                            updaterService.checkForUpdates()
                        } label: {
                            Label(model.localized(.checkForUpdates), systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                VersionLink(
                    versionText: model.appVersionDisplayText,
                    repositoryURL: model.appRepositoryURL,
                    font: .caption.monospacedDigit()
                )
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(20)
        }
    }

    // MARK: - Overlay Tab

    private var overlayTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsCard {
                    sectionHeader(model.localized(.subtitleOverlay), icon: "rectangle.on.rectangle")
                    Text(model.localized(.onlyThreeControlsAcceptClicks))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    settingsRow(model.localized(.textOutline)) {
                        Toggle("", isOn: textOutlineEnabledBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    if model.overlayStyle.showsTextOutline {
                        Divider()
                        settingsRow(model.localized(.outlineColor)) {
                            ColorPicker("", selection: textOutlineColorBinding, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                    Divider()
                    settingsRow(model.localized(.attachToSource)) {
                        Toggle("", isOn: attachToSourceBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                settingsCard {
                    sectionHeader(model.localized(.subtitleColor), icon: "paintpalette")
                    settingsRow(model.localized(.subtitleColor)) {
                        ColorPicker("", selection: subtitleColorBinding, supportsOpacity: false)
                            .labelsHidden()
                    }
                    Divider()
                    settingsRow(model.localized(.backgroundColor)) {
                        ColorPicker("", selection: backgroundColorBinding, supportsOpacity: false)
                            .labelsHidden()
                    }
                    if !colorsUseDefaultValues {
                        HStack {
                            Spacer()
                            Button {
                                model.updateOverlayStyle { style in
                                    style.subtitleColor = .defaultSubtitle
                                    style.backgroundColor = .defaultBackground
                                }
                            } label: {
                                Label(model.localized(.resetColors), systemImage: "arrow.counterclockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                settingsCard {
                    sectionHeader(model.localized(.translatedFont), icon: "textformat.size")
                    LabeledSlider(
                        title: model.localized(.topInset),
                        value: topInsetBinding,
                        range: 0 ... 48,
                        precision: 0
                    )
                    LabeledSlider(
                        title: model.localized(.widthRatio),
                        value: widthRatioBinding,
                        range: 0.10 ... 1.00,
                        precision: 2
                    )
                    LabeledSlider(
                        title: model.localized(.backgroundOpacity),
                        value: backgroundOpacityBinding,
                        range: 0.16 ... 0.72,
                        precision: 2
                    )
                    LabeledSlider(
                        title: model.localized(.translatedFont),
                        value: translatedFontBinding,
                        range: 8 ... 34,
                        precision: 0
                    )
                    LabeledSlider(
                        title: model.localized(.sourceFont),
                        value: sourceFontBinding,
                        range: 5 ... 28,
                        precision: 0
                    )
                }
            }
            .padding(20)
        }
    }

    // MARK: - Glossary Tab

    private var glossaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsCard {
                    sectionHeader(model.localized(.glossary), icon: "text.book.closed")
                    if model.glossary.isEmpty {
                        Text(model.localized(.glossaryEmpty))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(model.glossary.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.callout)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption2)
                                Text(model.glossary[key] ?? "")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    model.glossary.removeValue(forKey: key)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                            }
                            Divider()
                        }
                    }
                    GlossaryAddRow(
                        sourcePlaceholder: model.localized(.sourceTerm),
                        targetPlaceholder: model.localized(.targetTerm)
                    ) { source, target in
                        guard !source.isEmpty, !target.isEmpty else { return }
                        model.glossary[source] = target
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Layout helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func settingsRow<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            control()
        }
    }

    @ViewBuilder
    private func settingsCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginService.launchesAtLogin },
            set: { launchAtLoginService.setLaunchesAtLogin($0) }
        )
    }

    private var topInsetBinding: Binding<Double> {
        overlayBinding(\.topInset)
    }

    private var widthRatioBinding: Binding<Double> {
        overlayBinding(\.widthRatio)
    }

    private var backgroundOpacityBinding: Binding<Double> {
        overlayBinding(\.backgroundOpacity)
    }

    private var subtitleColorBinding: Binding<Color> {
        Binding(
            get: { model.overlayStyle.subtitleColor.color },
            set: { newColor in
                model.updateOverlayStyle { style in
                    style.subtitleColor = OverlayColor(color: newColor)
                }
            }
        )
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: { model.overlayStyle.backgroundColor.color },
            set: { newColor in
                model.updateOverlayStyle { style in
                    style.backgroundColor = OverlayColor(color: newColor)
                }
            }
        )
    }

    private var textOutlineEnabledBinding: Binding<Bool> {
        overlayBinding(\.showsTextOutline)
    }

    private var textOutlineColorBinding: Binding<Color> {
        Binding(
            get: { model.overlayStyle.textOutlineColor.color },
            set: { newColor in
                model.updateOverlayStyle { style in
                    style.textOutlineColor = OverlayColor(color: newColor)
                }
            }
        )
    }

    private var attachToSourceBinding: Binding<Bool> {
        overlayBinding(\.attachToSource)
    }

    private var translatedFontBinding: Binding<Double> {
        overlayBinding(\.translatedFontSize)
    }

    private var sourceFontBinding: Binding<Double> {
        overlayBinding(\.sourceFontSize)
    }

    private var colorsUseDefaultValues: Bool {
        model.overlayStyle.subtitleColor == .defaultSubtitle
            && model.overlayStyle.backgroundColor == .defaultBackground
    }

    private func overlayBinding<Value>(_ keyPath: WritableKeyPath<OverlayStyle, Value>) -> Binding<Value> {
        Binding(
            get: { model.overlayStyle[keyPath: keyPath] },
            set: { newValue in
                model.updateOverlayStyle { style in
                    style[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

struct LanguageResourceStatusListView: View {
    let statuses: [LanguageResourceStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(statuses) { status in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status.title)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if let progress = status.progress, status.isError == false {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if status.isError {
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let progress = status.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct GlossaryAddRow: View {
    let sourcePlaceholder: String
    let targetPlaceholder: String
    let onAdd: (String, String) -> Void
    @State private var source = ""
    @State private var target = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(sourcePlaceholder, text: $source)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .font(.caption2)

            TextField(targetPlaceholder, text: $target)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Button {
                onAdd(source.trimmingCharacters(in: .whitespaces),
                      target.trimmingCharacters(in: .whitespaces))
                source = ""
                target = ""
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty
                      || target.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let precision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedValue)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private var formattedValue: String {
        String(format: "%.\(precision)f", value.wrappedValue)
    }
}
