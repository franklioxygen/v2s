import AVFoundation
import Foundation
import OnnxRuntimeBindings

// MARK: - VADResult

struct VADResult: Sendable {
    let speechProbability: Float
    let isSpeech: Bool
    let containsSpeechOnset: Bool
    let containsSpeechOffset: Bool
}

// MARK: - SileroVADEngine

/// Runs Silero VAD v5 inference on 16 kHz mono Float32 audio buffers.
///
/// The engine accumulates incoming samples into 512-sample chunks (32 ms at 16 kHz),
/// runs ONNX inference per chunk, and applies onset/offset hysteresis to produce a
/// stable speech/silence signal.
///
/// **Threading**: All methods must be called from the same serial queue (captureQueue).
final class SileroVADEngine {

    // MARK: - Constants

    /// Silero VAD v5 expects 512-sample chunks at 16 kHz.
    private static let chunkSize = 512
    /// LSTM state size: shape [2, 1, 64] = 128 floats.
    private static let stateSize = 2 * 1 * 64

    // MARK: - ONNX Runtime objects

    private let env: ORTEnv
    private let session: ORTSession

    // MARK: - Model state

    /// LSTM hidden state, carried across chunks.
    private var hState: [Float]
    /// LSTM cell state, carried across chunks.
    private var cState: [Float]
    /// Sample-rate tensor (constant, reusable).
    private let srTensor: ORTValue
    /// Backing data for srTensor (must stay alive).
    private let srData: NSMutableData

    // MARK: - Accumulation buffer

    private var accumulationBuffer: [Float] = []

    // MARK: - Hysteresis state

    private var hysteresis = SileroVADHysteresis(
        speechOnsetThreshold: 0.5,
        speechOffsetThreshold: 0.35,
        minSpeechFrames: 3,
        minSilenceFrames: 8
    )
    private var hasLoggedInferenceFailure = false

    var isSpeaking: Bool { hysteresis.isSpeaking }

    // MARK: - Init

    init() throws {
        env = try ORTEnv(loggingLevel: .warning)

        let sessionOptions = try ORTSessionOptions()

        guard let modelURL = Self.resourceBundle.url(forResource: "silero_vad", withExtension: "onnx") else {
            throw SileroVADError.modelNotFound
        }

        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: sessionOptions)

        hState = [Float](repeating: 0, count: Self.stateSize)
        cState = [Float](repeating: 0, count: Self.stateSize)

        // Pre-build the sample-rate tensor (constant Int64 = 16000).
        var sr: Int64 = 16000
        srData = NSMutableData(bytes: &sr, length: MemoryLayout<Int64>.size)
        srTensor = try ORTValue(tensorData: srData, elementType: .int64, shape: [1])
    }

    // MARK: - Public API

    /// Process an audio buffer and return the VAD result.
    ///
    /// Accumulates samples, runs inference on complete 512-sample chunks, and applies
    /// hysteresis. Returns the result from the *last* chunk processed (or a no-speech
    /// result if no full chunk was available).
    func process(buffer: AVAudioPCMBuffer) -> VADResult {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return VADResult(speechProbability: 0, isSpeech: isSpeaking,
                             containsSpeechOnset: false, containsSpeechOffset: false)
        }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        accumulationBuffer.append(contentsOf: samples)

        var maxProbability: Float = 0
        var didOnset = false
        var didOffset = false

        while accumulationBuffer.count >= Self.chunkSize {
            let chunk = Array(accumulationBuffer.prefix(Self.chunkSize))
            accumulationBuffer.removeFirst(Self.chunkSize)

            let probability: Float
            do {
                probability = try infer(chunk: chunk)
                hasLoggedInferenceFailure = false
            } catch {
                if !hasLoggedInferenceFailure {
                    fputs("Silero VAD inference failed: \(error)\n", stderr)
                    hasLoggedInferenceFailure = true
                }
                probability = 0
            }
            if probability > maxProbability { maxProbability = probability }

            let transition = hysteresis.apply(probability: probability)
            if transition.didOnset { didOnset = true }
            if transition.didOffset { didOffset = true }
        }

        return VADResult(
            speechProbability: maxProbability,
            isSpeech: isSpeaking,
            containsSpeechOnset: didOnset,
            containsSpeechOffset: didOffset
        )
    }

    /// Reset LSTM state and hysteresis. Call when starting a new recognition session.
    func reset() {
        hState = [Float](repeating: 0, count: Self.stateSize)
        cState = [Float](repeating: 0, count: Self.stateSize)
        accumulationBuffer.removeAll()
        hysteresis.reset()
        hasLoggedInferenceFailure = false
    }

    // MARK: - Private

    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        Bundle.module
#else
        Bundle.main
#endif
    }

    private func infer(chunk: [Float]) throws -> Float {
        // Build input tensor: [1, 512]
        var audioSamples = chunk
        let audioData = NSMutableData(
            bytes: &audioSamples,
            length: audioSamples.count * MemoryLayout<Float>.size
        )
        let audioTensor = try ORTValue(
            tensorData: audioData,
            elementType: .float,
            shape: [1, NSNumber(value: Self.chunkSize)]
        )

        // Build h tensor: [2, 1, 64]
        let hData = NSMutableData(
            bytes: &hState,
            length: hState.count * MemoryLayout<Float>.size
        )
        let hTensor = try ORTValue(
            tensorData: hData,
            elementType: .float,
            shape: [2, 1, 64]
        )

        // Build c tensor: [2, 1, 64]
        let cData = NSMutableData(
            bytes: &cState,
            length: cState.count * MemoryLayout<Float>.size
        )
        let cTensor = try ORTValue(
            tensorData: cData,
            elementType: .float,
            shape: [2, 1, 64]
        )

        let runOptions = try ORTRunOptions()
        let outputs = try session.run(
            withInputs: [
                "input": audioTensor,
                "sr": srTensor,
                "h": hTensor,
                "c": cTensor,
            ],
            outputNames: Set(["output", "hn", "cn"]),
            runOptions: runOptions
        )

        // Read speech probability
        guard let outputValue = outputs["output"] else {
            throw SileroVADError.missingOutput("output")
        }
        let outputData = try outputValue.tensorData() as Data
        let probability = outputData.withUnsafeBytes { $0.load(as: Float.self) }

        // Update LSTM states for next call
        if let hnValue = outputs["hn"] {
            let hnData = try hnValue.tensorData() as Data
            hState = hnData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        if let cnValue = outputs["cn"] {
            let cnData = try cnValue.tensorData() as Data
            cState = cnData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        return probability
    }
}

// MARK: - Errors

enum SileroVADError: LocalizedError {
    case modelNotFound
    case missingOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Silero VAD model (silero_vad.onnx) not found in app bundle."
        case .missingOutput(let name):
            return "Silero VAD inference missing expected output: \(name)"
        }
    }
}
