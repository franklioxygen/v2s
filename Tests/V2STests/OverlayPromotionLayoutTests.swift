import AppKit
import SwiftUI
import XCTest
@testable import v2s

#if DEBUG
/// Compares actual rendered glyph rows, including wrapping and SwiftUI layout.
/// Opt in on a Mac with a window server: V2S_OVERLAY_LAYOUT_INTEGRATION=1.
@MainActor
final class OverlayPromotionLayoutTests: XCTestCase {
    func testPromotionKeepsTextRowsInPlaceInEveryDisplayMode() async throws {
        for mode in SubtitleDisplayMode.allCases {
            try await checkPromotion(mode: mode)
        }
    }

    func testWrappedCaptionKeepsItsPosition() async throws {
        try await checkPromotion(
            mode: .both, width: 380,
            source: "いつも助けてくれてありがとう。今日は一緒に公園を散歩してから、晩ご飯を食べに行きましょう。",
            translation: "谢谢你一直帮助我。今天我们一起去公园散步，然后再去吃晚饭吧。"
        )
    }

    func testPendingTranslationKeepsOriginalTypographyAndPosition() async throws {
        for mode in [SubtitleDisplayMode.both, .translatedOnly] {
            try await checkPromotion(mode: mode, translation: nil)
        }
    }

    func testPreviousCaptionAndHistoryDoNotMovePromotedCaption() async throws {
        try await checkPromotion(mode: .both, hasPreviousCaption: true)
    }

    func testSamePromotionIsNotDrawnTwiceWhileDraftClears() async throws {
        try await checkPromotion(mode: .both, keepsDraftDuringPromotion: true)
    }

    func testArchivingDoesNotLeaveAnEmptyLiveRow() async throws {
        try await checkPromotion(mode: .both, archivesAfterPromotion: true)
    }

    func testDraftRemainsVisibleWhileCommittedTranslationIsPending() async throws {
        for mode in [SubtitleDisplayMode.both, .translatedOnly] {
            try await checkPromotion(mode: mode, waitsForTranslation: true)
        }
    }

    func testFirstSplitSentenceStaysVisibleWhileTheSecondWaits() async throws {
        guard ProcessInfo.processInfo.environment["V2S_OVERLAY_LAYOUT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set V2S_OVERLAY_LAYOUT_INTEGRATION=1 to render the native overlay")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("split-layout-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.updateOverlayStyle { style in
            style.subtitleColor = OverlayColor(red: 1, green: 0, blue: 0)
            style.backgroundOpacity = 0
        }
        let id = UUID(), sentences = ["ただいま。", "おかえり。"]
        let source = sentences.joined()
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        model.receiveDraftForTesting(DraftSegment(
            segmentId: id, sourceText: source, stablePrefixLength: source.count, mutableTailText: "",
            avgConfidence: 1, startMs: 0, lastUpdateMs: 1, silenceMs: 0, stabilityScore: 1,
            boundaryScore: 1, chunkScore: 1, vadProbability: 1, words: []
        ), target: "ja")
        var draft = try XCTUnwrap(model.overlayState)
        draft.setDraftTranslation("我回来了。欢迎回来。", sourceText: source, promotionID: id)
        model.previewOverlayForTesting(draft)
        let host = NSHostingView(rootView: OverlayView(model: model, interactionState: OverlayInteractionState()))
        let size = NSSize(width: 540, height: 150)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        defer { window.close(); model.stopSession() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = try snapshot(host, name: "split-draft")
        let start = Date()
        for index in sentences.indices {
            let context = try XCTUnwrap(SentenceTranslationContext(sentences: sentences, sentenceIndex: index, draftSegmentID: id))
            model.enqueueRecognizedSentence(
                RecognizedSentence(text: sentences[index], promotionSegmentID: index == 0 ? id : nil,
                                   translationContext: context, recognitionID: UUID()),
                source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans"
            )
        }
        model.receiveDraftForTesting(nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        let during = try snapshot(host, name: "split-first-promoted")
        let remaining = max(0, 1.5 - Date().timeIntervalSince(start))
        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        XCTAssertEqual(model.overlayState?.sourceText, sentences[0])
        XCTAssertEqual(model.overlayState?.translatedText, "我回来了。")
        XCTAssertTrue(model.overlayState?.history.isEmpty == true)
        XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
        let after = try snapshot(host, name: "split-first-reading")
        XCTAssertFalse(before.isEmpty)
        for rows in [during, after] {
            XCTAssertEqual(rows.count, before.count)
            for (a, b) in zip(before, rows) {
                XCTAssertEqual(a.lowerBound, b.lowerBound, accuracy: 1)
                XCTAssertEqual(a.upperBound, b.upperBound, accuracy: 1)
            }
        }
        print("SPLIT LAYOUT: draft=\(before), first=\(during), reading=\(after)")
    }

    private func checkPromotion(
        mode: SubtitleDisplayMode,
        width: CGFloat = 760,
        source: String = "いつもごめんね。",
        translation: String? = "总是给你添麻烦，对不起。",
        hasPreviousCaption: Bool = false,
        keepsDraftDuringPromotion: Bool = false,
        archivesAfterPromotion: Bool = false,
        waitsForTranslation: Bool = false
    ) async throws {
        guard ProcessInfo.processInfo.environment["V2S_OVERLAY_LAYOUT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set V2S_OVERLAY_LAYOUT_INTEGRATION=1 to render the native overlay")
        }
        let settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-layout-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: settingsURL), sourceCatalogService: SourceCatalogService())
        model.subtitleDisplayMode = mode
        model.updateOverlayStyle { style in
            // Isolate text pixels from the neutral window border and background.
            style.subtitleColor = OverlayColor(red: 1, green: 0, blue: 0)
            style.backgroundOpacity = 0
        }
        let id = UUID()
        var draft = OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test")
        if hasPreviousCaption {
            draft.sourceText = "前の字幕です。"
            draft.translatedText = "这是上一条字幕。"
            draft.committedPromotionID = UUID()
            draft.history = (0..<8).map { _ in
                OverlayHistoryEntry(translatedText: "更早的字幕。", sourceText: "履歴の字幕です。")
            }
        }
        draft.draftSourceText = source
        draft.draftStablePrefixLength = source.count
        draft.draftPromotionID = id
        draft.setDraftTranslation(translation, sourceText: source, promotionID: id)
        model.previewOverlayForTesting(draft)

        let host = NSHostingView(rootView: OverlayView(model: model, interactionState: OverlayInteractionState()))
        let size = NSSize(width: width, height: 420)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        defer { window.close(); model.stopSession() }

        let name = "\(mode.rawValue)-\(Int(width))-\(translation == nil ? "pending" : "translated")-\(hasPreviousCaption)-\(keepsDraftDuringPromotion)-\(archivesAfterPromotion)-\(waitsForTranslation)"
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = try snapshot(host, name: name + "-draft")
        var committed = OverlayPreviewState(translatedText: waitsForTranslation ? "" : (translation ?? ""), sourceText: source, sourceName: "Test")
        committed.history = draft.history
        if hasPreviousCaption {
            committed.history.append(OverlayHistoryEntry(translatedText: draft.translatedText, sourceText: draft.sourceText))
        }
        committed.committedPromotionID = id
        committed.captionEpoch = 1
        committed.skipCommittedFadeIn = translation != nil
        if keepsDraftDuringPromotion || waitsForTranslation {
            committed.draftSourceText = source
            committed.draftPromotionID = id
            committed.setDraftTranslation(translation, sourceText: source, promotionID: id)
        }
        model.previewOverlayForTesting(committed)
        try await Task.sleep(nanoseconds: 80_000_000)
        let during = try snapshot(host, name: name + "-promotion")
        committed.translatedText = translation ?? ""
        committed.draftSourceText = nil
        committed.draftPromotionID = nil
        committed.clearDraftTranslation()
        model.previewOverlayForTesting(committed)
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = try snapshot(host, name: name + "-committed")

        // History can gain visible rows when an old live caption is archived.
        // Compare only the latest bilingual pair in that case.
        let expected = hasPreviousCaption ? Array(before.suffix(2)) : before
        let intermediate = hasPreviousCaption ? Array(during.suffix(2)) : during
        let actual = hasPreviousCaption ? Array(after.suffix(2)) : after
        print("LAYOUT \(name): draft=\(expected), promotion=\(intermediate), committed=\(actual)")
        XCTAssertFalse(expected.isEmpty, "The native overlay did not render")
        for rows in [intermediate, actual] {
            XCTAssertEqual(expected.count, rows.count, name)
            for (a, b) in zip(expected, rows) {
                XCTAssertEqual(a.lowerBound, b.lowerBound, accuracy: 1, name)
                XCTAssertEqual(a.upperBound, b.upperBound, accuracy: 1, name)
            }
        }

        if archivesAfterPromotion {
            var archived = OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test")
            archived.history = committed.history + [OverlayHistoryEntry(translatedText: translation ?? "", sourceText: source)]
            model.previewOverlayForTesting(archived)
            try await Task.sleep(nanoseconds: 500_000_000)
            let rows = try snapshot(host, name: name + "-archived")
            XCTAssertEqual(actual.count, rows.count)
            for (a, b) in zip(actual, rows) {
                XCTAssertEqual(a.lowerBound, b.lowerBound, accuracy: 1)
                XCTAssertEqual(a.upperBound, b.upperBound, accuracy: 1)
            }
        }
    }

    private func snapshot(_ host: NSView, name: String) throws -> [ClosedRange<CGFloat>] {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let captured = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: captured)
        let png = try XCTUnwrap(captured.representation(using: .png, properties: [:]))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        if let directory = ProcessInfo.processInfo.environment["V2S_OVERLAY_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent(name + ".png"))
        }
        let scale = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        var rows: [ClosedRange<Int>] = []
        for y in 0..<bitmap.pixelsHigh {
            var count = 0
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.15 && color.redComponent > color.greenComponent * 2
                    && color.redComponent > color.blueComponent * 2 && color.alphaComponent > 0.1 {
                    count += 1
                }
            }
            if count > 2 {
                if let last = rows.last, y - last.upperBound < 4 {
                    rows[rows.count - 1] = last.lowerBound...y
                } else {
                    rows.append(y...y)
                }
            }
        }
        return rows.map { CGFloat($0.lowerBound) / scale...CGFloat($0.upperBound) / scale }
    }
}
#endif
