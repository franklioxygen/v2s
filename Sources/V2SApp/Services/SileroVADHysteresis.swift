import Foundation

struct VADSpeechTransition {
    let didOnset: Bool
    let didOffset: Bool
}

struct SileroVADHysteresis {
    let speechOnsetThreshold: Float
    let speechOffsetThreshold: Float
    let minSpeechFrames: Int
    let minSilenceFrames: Int

    private(set) var isSpeaking = false
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0

    init(
        speechOnsetThreshold: Float,
        speechOffsetThreshold: Float,
        minSpeechFrames: Int,
        minSilenceFrames: Int
    ) {
        self.speechOnsetThreshold = speechOnsetThreshold
        self.speechOffsetThreshold = speechOffsetThreshold
        self.minSpeechFrames = minSpeechFrames
        self.minSilenceFrames = minSilenceFrames
    }

    mutating func apply(probability: Float) -> VADSpeechTransition {
        let wasSpeaking = isSpeaking
        updateCounters(for: probability)

        if !isSpeaking && consecutiveSpeechFrames >= minSpeechFrames {
            isSpeaking = true
        } else if isSpeaking && consecutiveSilenceFrames >= minSilenceFrames {
            isSpeaking = false
        }

        return VADSpeechTransition(
            didOnset: !wasSpeaking && isSpeaking,
            didOffset: wasSpeaking && !isSpeaking
        )
    }

    mutating func reset() {
        isSpeaking = false
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
    }

    private mutating func updateCounters(for probability: Float) {
        if probability >= speechOnsetThreshold {
            consecutiveSpeechFrames += 1
            consecutiveSilenceFrames = 0
        } else if probability < speechOffsetThreshold {
            consecutiveSilenceFrames += 1
            consecutiveSpeechFrames = 0
        } else if isSpeaking {
            consecutiveSilenceFrames = 0
        } else {
            consecutiveSpeechFrames = 0
        }
    }
}
