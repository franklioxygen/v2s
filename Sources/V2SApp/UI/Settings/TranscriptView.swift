import AppKit
import Combine
import SwiftUI

// MARK: - TranscriptWindowController

@MainActor
final class TranscriptWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        let window = NSWindow()
        let hostingController = NSHostingController(rootView: TranscriptView(model: model))
        window.contentViewController = hostingController
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        applyLocalizedTitle()
        model.$interfaceLanguageID
            .sink { [weak self] _ in self?.applyLocalizedTitle() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showTranscript() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyLocalizedTitle() {
        window?.title = model.localized(.transcriptWindowTitle)
    }
}

// MARK: - TranscriptView

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab: TranscriptTab = .origin
    @State private var isSummarizeEnabled = false
    @State private var summarizedText: [TranscriptTab: String] = [:]
    @State private var isSummarizing = false
    @State private var summarizeError: String? = nil
    @State private var summarizeTask: Task<Void, Never>?
    @State private var summarizeGeneration = 0

    enum TranscriptTab: String, CaseIterable {
        case origin, translation
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            TabView(selection: $selectedTab) {
                transcriptTab(tab: .origin)
                    .tabItem { Text(model.localized(.origin)) }
                    .tag(TranscriptTab.origin)
                transcriptTab(tab: .translation)
                    .tabItem { Text(model.localized(.translation)) }
                    .tag(TranscriptTab.translation)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 520, minHeight: 480)
        .environment(\.locale, model.interfaceLocale)
        .onChange(of: selectedTab) { _, _ in
            // Reset summary when switching tabs so user can summarize per-tab
            summarizeError = nil
        }
        .onChange(of: model.transcriptGeneration) { _, _ in
            cancelSummarization()
            isSummarizeEnabled = false
            summarizedText = [:]
            summarizeError = nil
        }
        .onDisappear {
            cancelSummarization()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            Text(model.localized(.transcript))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func transcriptTab(tab: TranscriptTab) -> some View {
        let rawText = fullText(for: tab)
        let displayText: String = {
            if isSummarizeEnabled, let summary = summarizedText[tab] {
                return summary
            }
            return rawText
        }()

        ScrollView {
            if displayText.isEmpty {
                Text("–")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(20)
            } else {
                Text(displayText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if isSummarizing {
                ProgressView()
                    .controlSize(.small)
                Text("…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                summarizeToggle
            }

            if let error = summarizeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(model.localized(.clear)) {
                model.clearTranscript()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.hasTranscript == false)

            Button(model.localized(.copy)) {
                copyCurrentText()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var summarizeToggle: some View {
        Toggle(model.localized(.summarize), isOn: $isSummarizeEnabled)
            .toggleStyle(.switch)
            .onChange(of: isSummarizeEnabled) { _, enabled in
                summarizeError = nil
                if enabled {
                    startSummarization(for: selectedTab)
                } else {
                    cancelSummarization()
                }
            }
    }

    // MARK: - Data Helpers

    private func fullText(for tab: TranscriptTab) -> String {
        model.transcriptText(isTranslation: tab == .translation)
    }

    private func summaryLanguageID(for tab: TranscriptTab) -> String {
        switch tab {
        case .origin:
            return model.transcriptSourceLanguageID
        case .translation:
            return model.transcriptTargetLanguageID
        }
    }

    private func copyCurrentText() {
        let text: String
        if isSummarizeEnabled, let summary = summarizedText[selectedTab] {
            text = summary
        } else {
            text = fullText(for: selectedTab)
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Summarization

    @MainActor
    private func cancelSummarization() {
        summarizeTask?.cancel()
        summarizeTask = nil
        isSummarizing = false
    }

    @MainActor
    private func startSummarization(for tab: TranscriptTab) {
        cancelSummarization()
        let text = fullText(for: tab)
        let languageID = summaryLanguageID(for: tab)
        guard !text.isEmpty else {
            isSummarizeEnabled = false
            return
        }
        summarizeGeneration &+= 1
        let generation = summarizeGeneration
        isSummarizing = true
        summarizeTask = Task {
            do {
                let result = try await TranscriptSummarizer.summarize(
                    text: text,
                    languageID: languageID
                )
                await MainActor.run {
                    guard Task.isCancelled == false,
                          summarizeGeneration == generation else { return }
                    summarizedText[tab] = result
                    isSummarizing = false
                    summarizeTask = nil
                }
            } catch {
                await MainActor.run {
                    guard Task.isCancelled == false,
                          summarizeGeneration == generation else { return }
                    isSummarizeEnabled = false
                    summarizeError = error.localizedDescription
                    isSummarizing = false
                    summarizeTask = nil
                }
            }
        }
    }
}
