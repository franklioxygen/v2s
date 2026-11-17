import AVFoundation
import Foundation
import Speech
import Translation
import XCTest
@testable import v2s

// Driven by speech_eval/run.py, which copies this file into a scratch copy of
// the package together with the replay hooks it appends to
// LiveTranscriptionSession.swift. Both tests read a JSON plan from
// V2S_EVAL_PLAN and write JSON Lines files named in the plan.

private struct RecognitionPlan: Decodable {
    struct Case: Decodable {
        let audio: String
        let locale: String
        let out: String
    }
    let mode: String
    let tailSeconds: Double
    let cases: [Case]
    /// Also log every volatile transcriber result (kind "V"), not just finals.
    let trace: Bool?
}

private struct TranslationPlan: Decodable {
    struct Item: Decodable {
        let text: String
        let context: [String]?
        let contextIndex: Int?
    }
    struct Job: Decodable {
        let source: String
        let target: String
        let items: [Item]
        let out: String
        /// "lowLatency" or "highFidelity" (macOS 26.4+); nil leaves the system default, as the app does.
        let strategy: String?
        /// "preview" translates as the app translates drafts (TranslationCoordinator.Quality.preview).
        let quality: String?
    }
    let jobs: [Job]
}

@MainActor
private final class JSONLines {
    private var lines: [String] = []
    func add(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            lines.append(String(decoding: data, as: UTF8.self))
        }
    }
    func write(to path: String) throws {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

final class SpeechEvalHarness: XCTestCase {
    private func plan<T: Decodable>(_ type: T.Type) throws -> T {
        guard let path = ProcessInfo.processInfo.environment["V2S_EVAL_PLAN"] else {
            throw XCTSkip("Run through speech_eval/run.py (V2S_EVAL_PLAN is not set)")
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    @MainActor
    func testRecognition() async throws {
        let plan = try plan(RecognitionPlan.self)
        let mode = SubtitleMode(rawValue: plan.mode) ?? .balanced
        for item in plan.cases {
            try await replay(item, mode: mode, tailSeconds: plan.tailSeconds, trace: plan.trace ?? false)
        }
    }

    /// Plays one clip through LiveTranscriptionSession in real time, like an
    /// application audio tap, and records every committed caption and draft.
    @MainActor
    private func replay(_ item: RecognitionPlan.Case, mode: SubtitleMode, tailSeconds: Double, trace: Bool) async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: item.audio))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let capacity = AVAudioFrameCount(Double(file.length) * 48_000 / file.processingFormat.sampleRate) + 4_800
        let all = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var fed = false
        var conversionError: NSError?
        converter.convert(to: all, error: &conversionError) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }

        let log = JSONLines()
        let clock = ProcessInfo.processInfo
        var feedStart = clock.systemUptime
        func elapsed() -> Double { (clock.systemUptime - feedStart).rounded(toPlaces: 3) }

        let session = LiveTranscriptionSession()
        v2sEvalDroppedAudioBuffers = 0
        v2sEvalResultObserver = { isFinal, start, end, text, runs in
            guard isFinal || trace else { return }
            Task { @MainActor in
                // [text, audio start s, audio end s] per run; untimed runs have null times.
                let words: [[Any]] = runs.map { run in
                    [run.0, run.1.map { $0.rounded(toPlaces: 3) as Any } ?? NSNull(),
                     run.2.map { $0.rounded(toPlaces: 3) as Any } ?? NSNull()]
                }
                log.add(["kind": isFinal ? "F" : "V", "t": elapsed(), "start": start.rounded(toPlaces: 3),
                         "end": end.rounded(toPlaces: 3), "text": text, "words": words])
            }
        }
        defer { v2sEvalResultObserver = nil }
        let backend: String
        do {
            backend = try await session.startEvalReplay(
                localeIdentifier: item.locale,
                modeConfig: .config(for: mode),
                transcriptHandler: { sentence in
                    var event: [String: Any] = ["kind": "C", "t": elapsed(), "text": sentence.text]
                    if let context = sentence.translationContext {
                        event["context"] = context.sentences
                        event["context_index"] = context.sentenceIndex
                    }
                    log.add(event)
                },
                partialHandler: { draft in log.add(["kind": "D", "t": elapsed(), "text": draft?.sourceText ?? ""]) },
                errorHandler: { message in log.add(["kind": "X", "t": elapsed(), "text": message]) }
            )
        } catch {
            log.add(["kind": "meta", "backend": "unavailable", "error": "\(error)"])
            try log.write(to: item.out)
            return
        }

        let chunk = 480
        feedStart = clock.systemUptime
        log.add(["kind": "S", "t": 0.0, "text": "feed start"])
        var offset = 0
        let samples = all.floatChannelData![0]
        while offset < Int(all.frameLength) {
            let count = min(chunk, Int(all.frameLength) - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            buffer.floatChannelData![0].update(from: samples + offset, count: count)
            session.evalReplay(buffer)
            offset += count
            let wait = feedStart + Double(offset) / 48_000 - clock.systemUptime
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        log.add(["kind": "E", "t": elapsed(), "text": "feed end"])
        // Trailing silence so the last sentence finalizes the way a pause does live.
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
        silence.frameLength = AVAudioFrameCount(chunk)
        for _ in 0..<Int(tailSeconds * 100) {
            memset(silence.floatChannelData![0], 0, chunk * MemoryLayout<Float>.size)
            session.evalReplay(silence)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await session.stopAndWait()
        try await Task.sleep(nanoseconds: 500_000_000)
        log.add(["kind": "meta", "backend": backend, "dropped_audio_buffers": v2sEvalDroppedAudioBuffers])
        try log.write(to: item.out)
    }

    /// Translates captions through TranslationCoordinator — the app's own
    /// queue, memo and sentence-context handling — one item at a time.
    @MainActor
    func testTranslation() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let plan = try plan(TranslationPlan.self)
        for job in plan.jobs {
            let log = JSONLines()
            let source = Locale.Language(identifier: LanguageCatalog.translationLocaleIdentifier(for: job.source))
            let target = Locale.Language(identifier: LanguageCatalog.translationLocaleIdentifier(for: job.target))
            let status = await LanguageAvailability().status(from: source, to: target)
            guard status == .installed else {
                log.add(["kind": "meta", "error": "translation model not installed (\(status))"])
                try log.write(to: job.out)
                continue
            }
            let session = try makeSession(from: source, to: target, strategy: job.strategy)
            let effectiveStrategy = strategyName(of: session)
            let coordinator = TranslationCoordinator()
            var runner: Task<Void, Never>?
            coordinator.onConfigurationChange = { configuration in
                guard configuration != nil, runner == nil else { return }
                runner = Task { await coordinator.run(using: session) }
            }
            let segmentID = UUID()
            for item in job.items {
                var context: SentenceTranslationContext?
                if let sentences = item.context, let index = item.contextIndex {
                    context = SentenceTranslationContext(sentences: sentences, sentenceIndex: index, draftSegmentID: segmentID)
                }
                let started = ProcessInfo.processInfo.systemUptime
                var event: [String: Any] = ["text": item.text, "context_used": context != nil,
                                            "strategy": effectiveStrategy]
                do {
                    event["translation"] = try await coordinator.translate(
                        item.text, from: job.source, to: job.target, context: context,
                        quality: job.quality == "preview" ? .preview : .final
                    )
                } catch {
                    event["translation"] = ""
                    event["error"] = "\(error)"
                }
                event["ms"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                if job.quality == "preview", coordinator.hasServedPreviews(from: job.source, to: job.target) {
                    event["strategy"] = "lowLatency"
                }
                log.add(event)
            }
            runner?.cancel()
            coordinator.reset()
            try log.write(to: job.out)
        }
    }
}

@available(macOS 26.0, *)
private func makeSession(from source: Locale.Language, to target: Locale.Language, strategy: String?) throws -> TranslationSession {
    guard let strategy else {
        return TranslationSession(installedSource: source, target: target)
    }
    guard #available(macOS 26.4, *) else {
        throw XCTSkip("Translation strategies need macOS 26.4")
    }
    switch strategy {
    case "lowLatency":
        return TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
    case "highFidelity":
        return TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity)
    default:
        throw NSError(domain: "speech_eval", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown strategy \(strategy)"])
    }
}

/// The strategy a session translates with, as a plan names it.
@available(macOS 26.0, *)
private func strategyName(of session: TranslationSession) -> String {
    guard #available(macOS 26.4, *) else { return "unsupported" }
    switch session.preferredStrategy {
    case .lowLatency: return "lowLatency"
    case .highFidelity: return "highFidelity"
    default: return "other"
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
