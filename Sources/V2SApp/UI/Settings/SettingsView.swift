import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let closeSettings: () -> Void
    let quitApp: () -> Void
    let openSubtitleModeInfo: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Form {
                generalSection
                sourceSection
                languageSection
                overlaySection
                glossarySection
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(model.localized(.minimize)) {
                    closeSettings()
                }
                .buttonStyle(.bordered)

                Button(model.localized(.quit)) {
                    quitApp()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
        .environment(\.locale, model.interfaceLocale)
        .v2sTranslationHost(model: model)
        .onChange(of: model.sessionState) { _, newState in
            if newState == .running {
                closeSettings()
            }
        }
    }

    private var generalSection: some View {
        Section {
            row(title: model.localized(.sessionState), value: model.sessionBadgeText)
            row(title: model.localized(.status), value: model.statusMessage)

            Picker(model.localized(.interfaceLanguage), selection: interfaceLanguageBinding) {
                ForEach(LanguageCatalog.common) { option in
                    Text(option.localizedDisplayName(in: model.resolvedInterfaceLanguageID)).tag(option.id)
                }
            }

            HStack {
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

                Button(model.localized(.showSubtitlePreview)) {
                    model.showOverlayPreview()
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text(model.localized(.general))
        }
    }

    private var sourceSection: some View {
        Section {
            Picker(model.localized(.selectedSource), selection: selectedSourceBinding) {
                if model.allSources.isEmpty {
                    Text(model.localized(.noSourcesDetected)).tag("")
                } else {
                    ForEach(model.allSources) { source in
                        Text("\(source.category.displayName(in: model.resolvedInterfaceLanguageID)) · \(source.name)")
                            .tag(source.id)
                    }
                }
            }
            .pickerStyle(.menu)

            Button(model.localized(.refreshSources)) {
                model.refreshSources()
            }
            .buttonStyle(.bordered)
        } header: {
            Text(model.localized(.inputSource))
        }
    }

    private var languageSection: some View {
        Section {
            Picker(model.localized(.inputLanguage), selection: inputLanguageBinding) {
                ForEach(LanguageCatalog.common) { option in
                    Text(option.localizedDisplayName(in: model.resolvedInterfaceLanguageID)).tag(option.id)
                }
            }

            Picker(model.localized(.subtitleLanguage), selection: outputLanguageBinding) {
                ForEach(LanguageCatalog.common) { option in
                    Text(option.localizedDisplayName(in: model.resolvedInterfaceLanguageID)).tag(option.id)
                }
            }

            HStack {
                HStack(spacing: 6) {
                    Text(model.localized(.subtitleMode))
                    Button(action: openSubtitleModeInfo) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.localized(.subtitleModeHelp))
                }

                Spacer()

                Picker("", selection: subtitleModeBinding) {
                    ForEach(SubtitleMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName(in: model.resolvedInterfaceLanguageID))
                            Text(mode.detail(in: model.resolvedInterfaceLanguageID))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .labelsHidden()
            }

            Button(model.localized(.refreshLanguageResources)) {
                model.refreshLanguageResources()
            }
            .buttonStyle(.bordered)

            if model.languageResourceStatuses.isEmpty == false {
                LanguageResourceStatusListView(statuses: model.languageResourceStatuses)
                    .padding(.top, 4)
            }
        } header: {
            Text(model.localized(.languages))
        }
    }

    private var glossarySection: some View {
        Section {
            if model.glossary.isEmpty {
                Text(model.localized(.glossaryEmpty))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(Array(model.glossary.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(model.glossary[key] ?? "")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.glossary.removeValue(forKey: key)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            GlossaryAddRow(
                sourcePlaceholder: model.localized(.sourceTerm),
                targetPlaceholder: model.localized(.targetTerm)
            ) { source, target in
                guard !source.isEmpty, !target.isEmpty else { return }
                model.glossary[source] = target
            }
        } header: {
            Text(model.localized(.glossary))
        }
    }

    private var overlaySection: some View {
        Section {
            HStack {
                Text(model.localized(.onlyThreeControlsAcceptClicks))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Toggle(model.localized(.textOutline), isOn: whiteTextOutlineBinding)

            ColorPicker(
                model.localized(.subtitleColor),
                selection: subtitleColorBinding,
                supportsOpacity: false
            )

            ColorPicker(
                model.localized(.backgroundColor),
                selection: backgroundColorBinding,
                supportsOpacity: false
            )

            HStack {
                Button(model.localized(.resetColors)) {
                    model.updateOverlayStyle { style in
                        style.subtitleColor = .defaultSubtitle
                        style.backgroundColor = .defaultBackground
                    }
                }
                .buttonStyle(.bordered)
                .disabled(colorsUseDefaultValues)

                Spacer()
            }

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
        } header: {
            Text(model.localized(.subtitleOverlay))
        }
    }

    private var selectedSourceBinding: Binding<String> {
        Binding(
            get: { model.selectedSourceID ?? "" },
            set: { model.selectedSourceID = $0.isEmpty ? nil : $0 }
        )
    }

    private var inputLanguageBinding: Binding<String> {
        Binding(
            get: { model.inputLanguageID },
            set: { model.inputLanguageID = $0 }
        )
    }

    private var outputLanguageBinding: Binding<String> {
        Binding(
            get: { model.outputLanguageID },
            set: { model.outputLanguageID = $0 }
        )
    }

    private var subtitleModeBinding: Binding<SubtitleMode> {
        Binding(
            get: { model.subtitleMode },
            set: { model.subtitleMode = $0 }
        )
    }

    private var interfaceLanguageBinding: Binding<String> {
        Binding(
            get: { model.interfaceLanguageID },
            set: { model.interfaceLanguageID = $0 }
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

    private var whiteTextOutlineBinding: Binding<Bool> {
        overlayBinding(\.usesWhiteTextOutline)
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

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
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
                .foregroundStyle(.secondary)
                .font(.caption)

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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedValue)
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range)
        }
    }

    private var formattedValue: String {
        String(format: "%.\(precision)f", value.wrappedValue)
    }
}
