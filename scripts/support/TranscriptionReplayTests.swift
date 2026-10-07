import AVFoundation
import XCTest
@testable import v2s

@MainActor
private final class EventLog {
    let start: Double
    var lines: [String] = []
    init(start: Double) { self.start = start }
    func add(_ kind: String, _ text: String) {
        let t = ProcessInfo.processInfo.systemUptime - start
        lines.append(String(format: "%.3f", t) + "\t" + kind + "\t" + text.replacingOccurrences(of: "\n", with: " "))
    }
}

final class ReplayTests: XCTestCase {
    @MainActor
    func testReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let audioPath = env["V2S_REPLAY_AUDIO"], let outPath = env["V2S_REPLAY_OUT"] else {
            throw XCTSkip("set V2S_REPLAY_AUDIO and V2S_REPLAY_OUT")
        }
        let locale = env["V2S_REPLAY_LOCALE"] ?? "ja_JP"

        // Whole file as 48 kHz mono float, like an app-audio tap.
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        XCTAssertGreaterThan(source.frameLength, 0)
        let all = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 48_000 / file.processingFormat.sampleRate) + 4_800)!
        var fed = false
        var error: NSError?
        converter.convert(to: all, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }

        let session = LiveTranscriptionSession()
        let log = EventLog(start: ProcessInfo.processInfo.systemUptime)
        let ok = try await session.startReplay(
            localeIdentifier: locale,
            modeConfig: .config(for: SubtitleMode(rawValue: env["V2S_REPLAY_MODE"] ?? "balanced") ?? .balanced),
            transcriptHandler: { sentence in log.add("C", sentence.text) },
            partialHandler: { draft in log.add("D", draft?.sourceText ?? "") }
        )
        XCTAssertTrue(ok, "SpeechAnalyzer backend did not start")
        guard ok else { return }

        if let error { throw error }
        XCTAssertGreaterThan(all.frameLength, 0)

        // Feed 10 ms buffers in real time.
        let chunk = 480
        let feedStart = ProcessInfo.processInfo.systemUptime
        log.add("S", "feed start")
        var offset = 0
        let samples = all.floatChannelData![0]
        while offset < Int(all.frameLength) {
            let count = min(chunk, Int(all.frameLength) - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            buffer.floatChannelData![0].update(from: samples + offset, count: count)
            session.replay(buffer)
            offset += count
            let target = feedStart + Double(offset) / 48_000
            let wait = target - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        log.add("E", "feed end")
        // Trailing silence so pauses finalize like they would live.
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
        silence.frameLength = AVAudioFrameCount(chunk)
        for _ in 0..<400 {
            memset(silence.floatChannelData![0], 0, chunk * MemoryLayout<Float>.size)
            session.replay(silence)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await session.stopAndWait()
        try await Task.sleep(nanoseconds: 500_000_000)
        try log.lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}
