import SwiftUI

struct SettingsControlRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            content()
        }
    }
}

struct CommonLanguageMenuPicker: View {
    let interfaceLanguageID: String
    @Binding var selection: String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(LanguageCatalog.common) { option in
                Text(option.localizedDisplayName(in: interfaceLanguageID)).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SourceMenuPicker: View {
    let sources: [InputSource]
    let interfaceLanguageID: String
    let emptyTitle: String
    @Binding var selection: String?

    var body: some View {
        Picker("", selection: $selection) {
            Text(emptyTitle).tag(nil as String?)
            ForEach(sources) { source in
                Text("\(source.category.displayName(in: interfaceLanguageID)) · \(source.name)")
                    .tag(Optional(source.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SubtitleModeMenuPicker: View {
    let interfaceLanguageID: String
    let showsDetail: Bool
    @Binding var selection: SubtitleMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(SubtitleMode.allCases, id: \.self) { mode in
                if showsDetail {
                    VStack(alignment: .leading) {
                        Text(mode.displayName(in: interfaceLanguageID))
                        Text(mode.detail(in: interfaceLanguageID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                } else {
                    Text(mode.displayName(in: interfaceLanguageID)).tag(mode)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SubtitleDisplayModeMenuPicker: View {
    let interfaceLanguageID: String
    @Binding var selection: SubtitleDisplayMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(SubtitleDisplayMode.allCases, id: \.self) { mode in
                Text(mode.displayName(in: interfaceLanguageID)).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SecondaryRefreshButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(title, systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

struct LanguageResourcesFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SecondaryRefreshButton(
            title: model.localized(.refreshLanguageResources),
            action: model.refreshLanguageResources
        )

        if !model.languageResourceStatuses.isEmpty {
            LanguageResourceStatusListView(statuses: model.languageResourceStatuses)
        }
    }
}

extension AppModel {
    var selectedSourceOptionalBinding: Binding<String?> {
        Binding(
            get: { self.selectedSourceID },
            set: { self.selectedSourceID = $0 }
        )
    }

    var inputLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.inputLanguageID },
            set: {
                guard self.isLanguagePairLocked == false else { return }
                self.inputLanguageID = $0
            }
        )
    }

    var outputLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.outputLanguageID },
            set: {
                guard self.isLanguagePairLocked == false else { return }
                self.outputLanguageID = $0
            }
        )
    }

    var subtitleModeSelectionBinding: Binding<SubtitleMode> {
        Binding(
            get: { self.subtitleMode },
            set: { self.subtitleMode = $0 }
        )
    }

    var subtitleDisplayModeSelectionBinding: Binding<SubtitleDisplayMode> {
        Binding(
            get: { self.subtitleDisplayMode },
            set: { self.subtitleDisplayMode = $0 }
        )
    }

    var interfaceLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.interfaceLanguageID },
            set: { self.interfaceLanguageID = $0 }
        )
    }
}
