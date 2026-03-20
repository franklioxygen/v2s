import Foundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let closeSettings: () -> Void
    let openSubtitleModeInfo: () -> Void

    var body: some View {
        Form {
            generalSection
            sourceSection
            languageSection
            overlaySection
            glossarySection
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
        .v2sTranslationHost(model: model)
    }

    private var generalSection: some View {
        Section("General") {
            row(title: "Session State", value: model.sessionBadgeText)
            row(title: "Status", value: model.statusMessage)

            HStack {
                Button {
                    let shouldCloseSettings = model.sessionState != .running
                    model.toggleSession()
                    if shouldCloseSettings {
                        closeSettings()
                    }
                } label: {
                    SessionActionButtonLabel(
                        title: model.sessionButtonTitle,
                        showsActivity: model.showsSessionWaitIndicator
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSessionButtonDisabled)

                Button("Show Subtitle Preview") {
                    model.showOverlayPreview()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var sourceSection: some View {
        Section("Input Source") {
            Picker("Selected Source", selection: selectedSourceBinding) {
                if model.allSources.isEmpty {
                    Text("No sources detected").tag("")
                } else {
                    ForEach(model.allSources) { source in
                        Text("\(source.category.displayName) · \(source.name)").tag(source.id)
                    }
                }
            }
            .pickerStyle(.menu)

            Button("Refresh Sources") {
                model.refreshSources()
            }
            .buttonStyle(.bordered)
        }
    }

    private var languageSection: some View {
        Section("Languages") {
            Picker("Input Language", selection: inputLanguageBinding) {
                ForEach(LanguageCatalog.common) { option in
                    Text(option.displayName).tag(option.id)
                }
            }

            Picker("Subtitle Language", selection: outputLanguageBinding) {
                ForEach(LanguageCatalog.common) { option in
                    Text(option.displayName).tag(option.id)
                }
            }

            HStack {
                HStack(spacing: 6) {
                    Text("Subtitle Mode")
                    Button(action: openSubtitleModeInfo) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Explain the differences between subtitle modes")
                }

                Spacer()

                Picker("", selection: subtitleModeBinding) {
                    ForEach(SubtitleMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .labelsHidden()
            }

            Button("Refresh Language Resources") {
                model.refreshLanguageResources()
            }
            .buttonStyle(.bordered)

            if model.languageResourceStatuses.isEmpty == false {
                LanguageResourceStatusListView(statuses: model.languageResourceStatuses)
                    .padding(.top, 4)
            }
        }
    }

    private var glossarySection: some View {
        Section("Glossary") {
            if model.glossary.isEmpty {
                Text("No terms added. Use + to add source → target term pairs.")
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

            GlossaryAddRow { source, target in
                guard !source.isEmpty, !target.isEmpty else { return }
                model.glossary[source] = target
            }
        }
    }

    private var overlaySection: some View {
        Section("Subtitle Overlay") {
            HStack {
                Text("Only the 3 controls accept clicks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Toggle("Text Outline", isOn: whiteTextOutlineBinding)

            ColorPicker(
                "Subtitle Color",
                selection: subtitleColorBinding,
                supportsOpacity: false
            )

            ColorPicker(
                "Background Color",
                selection: backgroundColorBinding,
                supportsOpacity: false
            )

            HStack {
                Button("Reset Colors") {
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
                title: "Top Inset",
                value: topInsetBinding,
                range: 0 ... 48,
                precision: 0
            )

            LabeledSlider(
                title: "Width Ratio",
                value: widthRatioBinding,
                range: 0.10 ... 1.00,
                precision: 2
            )

            LabeledSlider(
                title: "Background Opacity",
                value: backgroundOpacityBinding,
                range: 0.16 ... 0.72,
                precision: 2
            )

            LabeledSlider(
                title: "Translated Font",
                value: translatedFontBinding,
                range: 8 ... 34,
                precision: 0
            )

            LabeledSlider(
                title: "Source Font",
                value: sourceFontBinding,
                range: 5 ... 28,
                precision: 0
            )
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
    let onAdd: (String, String) -> Void
    @State private var source = ""
    @State private var target = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Source term", text: $source)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField("Target term", text: $target)
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
