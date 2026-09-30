import AVFoundation
import CoreML
import Foundation

// MARK: - VADResult

struct VADResult: Sendable {
    let speechProbability: Float
    let isSpeech: Bool
    let containsSpeechOnset: Bool
    let containsSpeechOffset: Bool
}

// MARK: - SileroVADEngine

/// Runs Silero VAD v5 Core ML inference on 16 kHz mono Float32 audio buffers.
///
/// The engine accumulates incoming samples into 512-sample chunks (32 ms at 16 kHz),
/// runs inference per chunk, and applies onset/offset hysteresis to produce a stable
/// speech/silence signal.
///
/// **Threading**: All methods must be called from the same serial queue (captureQueue).
final class SileroVADEngine {

    // MARK: - Constants

    /// Silero VAD v5 expects 512 new samples at 16 kHz plus 64 samples of context.
    private static let contextSize = 64
    private static let chunkSize = 512
    private static let inputSize = contextSize + chunkSize
    private static let stateLayers = 2
    private static let stateWidth = 128
    private static let stateSize = stateLayers * stateWidth
    private static let audioShape = [1, inputSize]
    private static let stateShape = [stateLayers, 1, stateWidth]
    private static let probabilityShape = [1, 1]

    // MARK: - Core ML

    private let model: MLModel
    private let audioInput: MLMultiArray
    private let recurrentStateInput: MLMultiArray
    private let inputProvider: MLDictionaryFeatureProvider

    // MARK: - Model state

    /// Recurrent state, carried across chunks with shape [2, 1, 128].
    private var recurrentState: [Float]
    /// The final 64 samples from the previous consumed chunk.
    private var context: [Float]

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
        let modelURL = try Self.resolvedModelURL()

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: configuration)

        let audioInput = try MLMultiArray(
            shape: Self.audioShape.map(NSNumber.init(value:)),
            dataType: .float32
        )
        let recurrentStateInput = try MLMultiArray(
            shape: Self.stateShape.map(NSNumber.init(value:)),
            dataType: .float32
        )
        self.audioInput = audioInput
        self.recurrentStateInput = recurrentStateInput
        inputProvider = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audioInput),
            "recurrent_state": MLFeatureValue(multiArray: recurrentStateInput),
        ])

        recurrentState = [Float](repeating: 0, count: Self.stateSize)
        context = [Float](repeating: 0, count: Self.contextSize)

        _ = try infer(chunk: [Float](repeating: 0, count: Self.chunkSize))
        reset()
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
                // State cannot advance without a prediction. Start a coherent new
                // model stream rather than combining stale state with newer audio.
                resetInferenceState()
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

    /// Reset recurrent state, audio context, and hysteresis for a new stream.
    func reset() {
        resetInferenceState()
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

    private static let compiledPackageModelURL: Result<URL, Error> = Result {
        guard let packageURL = resourceBundle.url(
            forResource: "SileroVAD",
            withExtension: "mlpackage"
        ) else {
            throw SileroVADError.modelNotFound
        }
        return try MLModel.compileModel(at: packageURL)
    }

    private static func resolvedModelURL() throws -> URL {
        if let compiledURL = resourceBundle.url(
            forResource: "SileroVAD",
            withExtension: "mlmodelc"
        ) {
            return compiledURL
        }

        return try compiledPackageModelURL.get()
    }

    private func infer(chunk: [Float]) throws -> Float {
        populateInputs(chunk: chunk)

        let outputs = try model.prediction(from: inputProvider)
        let probabilityOutput = try validatedOutput(
            named: "probability",
            from: outputs,
            expectedShape: Self.probabilityShape
        )
        let stateOutput = try validatedOutput(
            named: "state_out",
            from: outputs,
            expectedShape: Self.stateShape
        )

        let probability = probabilityOutput.withUnsafeBufferPointer(ofType: Float.self) {
            $0[0]
        }

        let stateStrides = stateOutput.strides.map { $0.intValue }
        stateOutput.withUnsafeBufferPointer(ofType: Float.self) { values in
            for layer in 0..<Self.stateLayers {
                for unit in 0..<Self.stateWidth {
                    recurrentState[layer * Self.stateWidth + unit] =
                        values[layer * stateStrides[0] + unit * stateStrides[2]]
                }
            }
        }

        updateContext(from: chunk)

        return probability
    }

    private func resetInferenceState() {
        recurrentState = [Float](repeating: 0, count: Self.stateSize)
        context = [Float](repeating: 0, count: Self.contextSize)
    }

    private func updateContext(from chunk: [Float]) {
        let contextStart = Self.chunkSize - Self.contextSize
        for index in 0..<Self.contextSize {
            context[index] = chunk[contextStart + index]
        }
    }

    private func populateInputs(chunk: [Float]) {
        audioInput.withUnsafeMutableBufferPointer(ofType: Float.self) { values, strides in
            let sampleStride = strides[1]
            for index in 0..<Self.contextSize {
                values[index * sampleStride] = context[index]
            }
            for index in 0..<Self.chunkSize {
                values[(Self.contextSize + index) * sampleStride] = chunk[index]
            }
        }

        recurrentStateInput.withUnsafeMutableBufferPointer(ofType: Float.self) { values, strides in
            for layer in 0..<Self.stateLayers {
                for unit in 0..<Self.stateWidth {
                    values[layer * strides[0] + unit * strides[2]] =
                        recurrentState[layer * Self.stateWidth + unit]
                }
            }
        }
    }

    private func validatedOutput(
        named name: String,
        from provider: any MLFeatureProvider,
        expectedShape: [Int]
    ) throws -> MLMultiArray {
        guard let featureValue = provider.featureValue(for: name) else {
            throw SileroVADError.missingOutput(name)
        }
        guard let multiArray = featureValue.multiArrayValue else {
            throw SileroVADError.outputIsNotMultiArray(name)
        }
        guard multiArray.dataType == .float32 else {
            throw SileroVADError.invalidOutputDataType(
                name: name,
                actual: multiArray.dataType
            )
        }

        let expectedCount = expectedShape.reduce(1, *)
        guard multiArray.count == expectedCount else {
            throw SileroVADError.invalidOutputCount(
                name: name,
                expected: expectedCount,
                actual: multiArray.count
            )
        }

        let actualShape = multiArray.shape.map { $0.intValue }
        guard actualShape == expectedShape else {
            throw SileroVADError.invalidOutputShape(
                name: name,
                expected: expectedShape,
                actual: actualShape
            )
        }

        return multiArray
    }
}

// MARK: - Errors

enum SileroVADError: LocalizedError {
    case modelNotFound
    case missingOutput(String)
    case outputIsNotMultiArray(String)
    case invalidOutputDataType(name: String, actual: MLMultiArrayDataType)
    case invalidOutputCount(name: String, expected: Int, actual: Int)
    case invalidOutputShape(name: String, expected: [Int], actual: [Int])

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Silero VAD Core ML model (SileroVAD.mlmodelc or SileroVAD.mlpackage) not found in app bundle."
        case .missingOutput(let name):
            return "Silero VAD Core ML model is missing expected output '\(name)'."
        case .outputIsNotMultiArray(let name):
            return "Silero VAD Core ML output '\(name)' is not a multi-array."
        case .invalidOutputDataType(let name, let actual):
            return "Silero VAD Core ML output '\(name)' has data type \(actual); expected Float32."
        case .invalidOutputCount(let name, let expected, let actual):
            return "Silero VAD Core ML output '\(name)' has \(actual) elements; expected \(expected)."
        case .invalidOutputShape(let name, let expected, let actual):
            return "Silero VAD Core ML output '\(name)' has shape \(actual); expected \(expected)."
        }
    }
}
