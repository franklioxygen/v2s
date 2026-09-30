import AVFoundation
import Foundation
import XCTest
@testable import v2s

final class SileroVADEngineTests: XCTestCase {
    private static let chunkSize = 512
    private static let sampleRate = 16_000.0
    // Captured from the pinned Silero v5 reference with each 512-sample chunk
    // preceded by its 64-sample context and one combined [2, 1, 128] recurrent
    // state. These fixed goldens are not produced by a live ONNX comparison.
    // The 1e-4 tolerance accommodates Core ML backend rounding while remaining
    // tight enough to catch context or recurrent-state contract regressions.
    private static let goldenProbabilities: [Float] = [
        0.334451973,
        0.43982628,
        0.219400823,
        0.0712271631,
        0.0301993787,
        0.0113633275,
        0.00926747918,
        0.00593075156,
        0.00619235635,
        0.00379472971,
        0.00467684865,
        0.0031940639,
    ]

    func testPackagedModelMatchesGoldenSequenceAfterReset() throws {
        let engine = try SileroVADEngine()
        // This first run starts immediately after init, so it also verifies that
        // prewarming did not carry context or recurrent state into production.
        let firstRun = try processGoldenSequence(with: engine)
        assertGoldenSequence(firstRun)

        engine.reset()

        let secondRun = try processGoldenSequence(with: engine)
        assertGoldenSequence(secondRun)

        for index in Self.goldenProbabilities.indices {
            XCTAssertEqual(
                secondRun[index].speechProbability,
                firstRun[index].speechProbability,
                accuracy: 1e-6,
                "Reset run differs at chunk \(index)"
            )
        }
    }

    private func processGoldenSequence(with engine: SileroVADEngine) throws -> [VADResult] {
        try Self.goldenProbabilities.indices.map { chunkIndex in
            engine.process(buffer: try makeBuffer(chunkIndex: chunkIndex))
        }
    }

    private func assertGoldenSequence(
        _ results: [VADResult],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(results.count, Self.goldenProbabilities.count, file: file, line: line)

        for (index, result) in results.enumerated() {
            XCTAssertEqual(
                result.speechProbability,
                Self.goldenProbabilities[index],
                accuracy: 1e-4,
                "Unexpected probability at chunk \(index)",
                file: file,
                line: line
            )
            XCTAssertFalse(
                result.containsSpeechOnset,
                "Unexpected speech onset at chunk \(index)",
                file: file,
                line: line
            )
            XCTAssertFalse(
                result.containsSpeechOffset,
                "Unexpected speech offset at chunk \(index)",
                file: file,
                line: line
            )
            XCTAssertFalse(
                result.isSpeech,
                "Hysteresis entered speech at chunk \(index)",
                file: file,
                line: line
            )
        }
    }

    private func makeBuffer(chunkIndex: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Self.chunkSize)
        ))
        buffer.frameLength = AVAudioFrameCount(Self.chunkSize)

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let channel = channelData[0]
        let firstSample = chunkIndex * Self.chunkSize

        for index in 0..<Self.chunkSize {
            let time = Double(firstSample + index) / Self.sampleRate
            let fundamental = sin(2.0 * Double.pi * 140.0 * time)
            let harmonic = 0.4 * sin(2.0 * Double.pi * 280.0 * time)
            channel[index] = Float(0.08 * (fundamental + harmonic))
        }

        return buffer
    }
}
