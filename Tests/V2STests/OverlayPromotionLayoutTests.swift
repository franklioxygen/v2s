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
            source: "今日は一緒に公園を散歩してから、晩ご飯を食べに行きましょう。",
            translation: "今天我们一起去公园散步，然后再去附近的餐厅吃晚饭吧。"
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

    func testEverySentenceHasItsOwnRowAndPromotesInPlace() async throws {
        guard ProcessInfo.processInfo.environment["V2S_OVERLAY_LAYOUT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set V2S_OVERLAY_LAYOUT_INTEGRATION=1 to render the native overlay")
        }
        let parts = ["別の仕事探した方がいいかな。", "明日友達に相談してみようかな。"]
        let (model, host, window, id) = try makeDraftWindow(
            parts, translation: "要不要找一份别的工作呢。明天找朋友商量一下吧。", size: NSSize(width: 420, height: 240))
        defer { window.close(); model.stopSession() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.draftRows.map(\.sourceText), parts)
        let before = try snapshot(host, name: "rows-draft")
        XCTAssertEqual(before.count, 4, "Each sentence is its own two-line row")

        // The first sentence takes the caption line; the second keeps its row.
        enqueue(parts, indices: [0], id: id, on: model)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.overlayState?.sourceText, parts[0])
        XCTAssertEqual(model.draftRows.map(\.sourceText), [parts[1]])
        assertSameRows(before, try snapshot(host, name: "rows-first-final"))

        // The second follows and the first rolls up into history. Nothing moves.
        enqueue(parts, indices: [1], id: id, on: model)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.overlayState?.sourceText, parts[1])
        XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [parts[0]])
        XCTAssertTrue(model.draftRows.isEmpty)
        let after = try snapshot(host, name: "rows-both-final")
        assertSameRows(before, after)
        print("ROW LAYOUT: draft=\(before), final=\(after)")
    }

    func testBothSplitSentencesRemainVisibleAfterPromotion() async throws {
        guard ProcessInfo.processInfo.environment["V2S_OVERLAY_LAYOUT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set V2S_OVERLAY_LAYOUT_INTEGRATION=1 to render the native overlay")
        }
        // Leave room for both sentences. A short window can conceal a missing
        // history entry and falsely pass a test that only checks the latest line.
        let sentences = ["ただいま。", "おかえり。"]
        let (model, host, window, id) = try makeDraftWindow(
            sentences, translation: "我回来了。欢迎回来。", size: NSSize(width: 540, height: 240))
        defer { window.close(); model.stopSession() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.draftRows.map(\.sourceText), sentences)
        let before = try snapshot(host, name: "split-draft")
        enqueue(sentences, indices: [0, 1], id: id, on: model)
        model.receiveDraftForTesting(nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.overlayState?.sourceText, sentences[1])
        XCTAssertEqual(model.overlayState?.translatedText, "欢迎回来。")
        XCTAssertEqual(model.overlayState?.history.map(\.sourceText), [sentences[0]])
        XCTAssertEqual(model.transcriptEntries.map(\.sourceText), sentences)
        let promoted = try snapshot(host, name: "split-promoted")
        assertSameRows(before, promoted)

        // After its reading time the caption rolls up too; both stay visible.
        let archiveDeadline = Date().addingTimeInterval(4)
        while model.overlayState?.sourceText.isEmpty == false, Date() < archiveDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.overlayState?.history.map(\.sourceText), sentences)
        try await Task.sleep(nanoseconds: 300_000_000)
        let archived = try snapshot(host, name: "split-finished")
        assertSameRows(before, archived)
        print("SPLIT RETENTION: draft=\(before), promoted=\(promoted), archived=\(archived)")

        // A larger window shows both sentences without scrolling back.
        window.setContentSize(NSSize(width: 540, height: 420))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(try snapshot(host, name: "split-full-history").count, 4)
        XCTAssertEqual(model.overlayHistoryScrollOffset, 0)
    }

    private func makeDraftWindow(_ parts: [String], translation: String, size: NSSize) throws
        -> (AppModel, NSHostingView<OverlayView>, NSWindow, UUID) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("row-layout-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(settingsStore: SettingsStore(fileURL: url), sourceCatalogService: SourceCatalogService())
        model.updateOverlayStyle { $0.subtitleColor = OverlayColor(red: 1, green: 0, blue: 0); $0.backgroundOpacity = 0 }
        let id = UUID(), source = parts.joined()
        model.previewOverlayForTesting(OverlayPreviewState(translatedText: "", sourceText: "", sourceName: "Test"))
        model.receiveDraftForTesting(DraftSegment(segmentId: id, sourceText: source, stablePrefixLength: source.count,
            mutableTailText: "", avgConfidence: 1, startMs: 0, lastUpdateMs: 1, silenceMs: 0, stabilityScore: 1,
            boundaryScore: 1, chunkScore: 1, vadProbability: 1, words: []))
        var state = try XCTUnwrap(model.overlayState)
        state.setDraftTranslation(translation, sourceText: source, promotionID: id)
        model.previewOverlayForTesting(state)
        let host = NSHostingView(rootView: OverlayView(model: model, interactionState: OverlayInteractionState()))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        return (model, host, window, id)
    }

    private func enqueue(_ parts: [String], indices: [Int], id: UUID, on model: AppModel) {
        for index in indices {
            model.enqueueRecognizedSentence(.init(text: parts[index], promotionSegmentID: index == 0 ? id : nil,
                translationContext: SentenceTranslationContext(sentences: parts, sentenceIndex: index, draftSegmentID: id),
                recognitionID: UUID()), source: .preview, sourceLanguageID: "ja", targetLanguageID: "zh-Hans")
        }
    }

    private func assertSameRows(_ expected: [ClosedRange<CGFloat>], _ actual: [ClosedRange<CGFloat>],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "Glyph row count changed", file: file, line: line)
        for (a, b) in zip(expected, actual) {
            XCTAssertEqual(a.lowerBound, b.lowerBound, accuracy: 1, file: file, line: line)
            XCTAssertEqual(a.upperBound, b.upperBound, accuracy: 1, file: file, line: line)
        }
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
