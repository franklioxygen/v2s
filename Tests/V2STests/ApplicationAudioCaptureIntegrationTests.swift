import AVFoundation
import CoreAudio
import XCTest
@testable import v2s

/// Runs a real Core Audio tap against `afplay`. It needs permission to capture other
/// apps' audio, so it only runs when `V2S_AUDIO_TAP_TESTS` is set. The tone it plays
/// sits around -66 dBFS, well below anything audible.
final class ApplicationAudioCaptureIntegrationTests: XCTestCase {
    private let queue = DispatchQueue(label: "com.franklioxygen.v2s.tests.capture")
    private var players: [Process] = []
    private var files: [URL] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["V2S_AUDIO_TAP_TESTS"] != nil,
            "Set V2S_AUDIO_TAP_TESTS=1 to run tests that tap real app audio."
        )
    }

    override func tearDown() {
        players.forEach { $0.terminate() }
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func testCaptureDeliversAppAudioAndNoticesNewAudioProcesses() throws {
        let tone = try play(try writeTone(amplitude: 0.01, seconds: 8), volume: 0.05)
        let receivedAudio = expectation(description: "receives audio")
        let processListChanged = expectation(description: "notices the process list change")
        processListChanged.assertForOverFulfill = false
        // A freshly built aggregate device settles without looking like a route change.
        let invalidated = expectation(description: "stays valid")
        invalidated.isInverted = true
        let formats = LockedValue<[AVAudioFormat]>([])

        let capture = ApplicationAudioCapture(
            appName: "afplay",
            processObjectIDs: [try processObjectID(for: tone)],
            silenceWindow: 60,
            queue: queue,
            audioHandler: { buffer in formats.mutate { $0.append(buffer.format) } },
            eventHandler: { event in
                switch event {
                case .receivingAudio:
                    receivedAudio.fulfill()
                case .processListChanged:
                    processListChanged.fulfill()
                case .invalidated:
                    invalidated.fulfill()
                }
            }
        )

        try queue.sync { try capture.start() }
        defer { queue.sync { capture.stop() } }

        wait(for: [receivedAudio], timeout: 5)

        // A second player registers a new Core Audio process.
        _ = try play(try writeTone(amplitude: 0, seconds: 3), volume: 1)
        wait(for: [processListChanged], timeout: 5)
        wait(for: [invalidated], timeout: 2)

        XCTAssertFalse(formats.value.isEmpty)
        XCTAssertTrue(formats.value.allSatisfy { $0.channelCount == 1 })
    }

    func testSilentTapIsReportedWhileTheAppPlays() throws {
        let silence = try play(try writeTone(amplitude: 0, seconds: 10), volume: 1)
        let invalidated = expectation(description: "reports the silent tap")

        let capture = ApplicationAudioCapture(
            appName: "afplay",
            processObjectIDs: [try processObjectID(for: silence)],
            silenceWindow: 2,
            queue: queue,
            audioHandler: { _ in },
            eventHandler: { event in
                switch event {
                case .invalidated(.silentWhileAppIsPlaying):
                    invalidated.fulfill()
                case .receivingAudio:
                    XCTFail("Digital silence must not count as audio")
                default:
                    break
                }
            }
        )

        try queue.sync { try capture.start() }
        defer { queue.sync { capture.stop() } }

        wait(for: [invalidated], timeout: 8)
    }

    // Rebuilds stop the device from the capture queue while audio is flowing. With the IO
    // block on that same queue, stopping during an IO cycle deadlocked.
    func testCaptureStopsWhileAudioIsFlowing() throws {
        let tone = try play(try writeTone(amplitude: 0.01, seconds: 10), volume: 0.05)
        let processObjectIDs = [try processObjectID(for: tone)]
        let cycled = expectation(description: "start/stop cycles finish")
        let queue = self.queue

        Thread.detachNewThread {
            for _ in 0..<25 {
                let capture = ApplicationAudioCapture(
                    appName: "afplay",
                    processObjectIDs: processObjectIDs,
                    silenceWindow: 60,
                    queue: queue,
                    audioHandler: { _ in },
                    eventHandler: { _ in }
                )

                do {
                    try queue.sync { try capture.start() }
                } catch {
                    XCTFail("Capture failed to start: \(error)")
                    return
                }

                Thread.sleep(forTimeInterval: Double.random(in: 0.02...0.12))
                queue.sync { capture.stop() }
            }

            cycled.fulfill()
        }

        wait(for: [cycled], timeout: 30)
    }

    // MARK: Helpers

    private func writeTone(amplitude: Float, seconds: Double) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            samples[frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / Float(format.sampleRate))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2s-tap-test-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        files.append(url)
        return url
    }

    private func play(_ url: URL, volume: Double) throws -> Process {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", String(volume), url.path]
        try player.run()
        players.append(player)
        return player
    }

    private func processObjectID(for player: Process) throws -> AudioObjectID {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let process = try AudioHardwareSystem.shared.process(for: player.processIdentifier),
               (try? process.isRunningOutput) == true {
                return process.id
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw XCTSkip("afplay never started audio output")
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}
