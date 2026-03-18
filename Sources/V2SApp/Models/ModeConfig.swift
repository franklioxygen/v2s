import Foundation

// MARK: - SubtitleMode

enum SubtitleMode: String, Codable, CaseIterable, Sendable {
    case balanced
    case follow
    case reading

    var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .follow:   return "Follow"
        case .reading:  return "Reading"
        }
    }

    var detail: String {
        switch self {
        case .balanced: return "Suitable for most use cases"
        case .follow:   return "Live broadcasts and meetings"
        case .reading:  return "Lectures and courses"
        }
    }
}

// MARK: - ModeConfig

struct ModeConfig: Sendable {
    let firstTokenTargetMs: Int
    let commitSourceTargetMs: Int
    let commitTranslationTargetMs: Int
    let maxChunkAudioSec: Double
    let minSilenceCommitMs: Int

    static let balanced = ModeConfig(
        firstTokenTargetMs: 300,
        commitSourceTargetMs: 600,
        commitTranslationTargetMs: 900,
        maxChunkAudioSec: 2.0,
        minSilenceCommitMs: 150
    )

    static let follow = ModeConfig(
        firstTokenTargetMs: 200,
        commitSourceTargetMs: 450,
        commitTranslationTargetMs: 700,
        maxChunkAudioSec: 1.5,
        minSilenceCommitMs: 100
    )

    static let reading = ModeConfig(
        firstTokenTargetMs: 400,
        commitSourceTargetMs: 800,
        commitTranslationTargetMs: 1200,
        maxChunkAudioSec: 2.5,
        minSilenceCommitMs: 200
    )

    static func config(for mode: SubtitleMode) -> ModeConfig {
        switch mode {
        case .balanced: return .balanced
        case .follow:   return .follow
        case .reading:  return .reading
        }
    }
}

// MARK: - ChunkScorer

/// Computes the weighted commit-readiness score for a draft segment.
/// Strategy §8.3 weights:
///   SilenceScore 0.30 · StabilityScore 0.20 · BoundaryScore 0.20
///   LengthFitScore 0.15 · ConfidenceScore 0.15
enum ChunkScorer {
    static func score(
        silenceMs: Int,
        vadProbability: Float,
        stabilityScore: Float,
        boundaryScore: Float,
        lengthFitScore: Float,
        confidenceScore: Float
    ) -> Float {
        let silenceScore = vadSilenceScoreValue(probability: vadProbability)
        return silenceScore     * 0.30
            + stabilityScore  * 0.20
            + boundaryScore   * 0.20
            + lengthFitScore  * 0.15
            + confidenceScore * 0.15
    }

    /// VAD-based silence scoring:
    ///   probability < 0.1  → 1.0  (clear silence, strong commit signal)
    ///   probability 0.1–0.35 → 0.7–0.4  (fading speech)
    ///   probability 0.35–0.5 → 0.4  (ambiguous)
    ///   probability > 0.5  → 0.0  (active speech, do not commit)
    private static func vadSilenceScoreValue(probability: Float) -> Float {
        switch probability {
        case ..<0.1:      return 1.0
        case 0.1..<0.35:  return 0.7 - (probability - 0.1) / 0.25 * 0.3
        case 0.35..<0.5:  return 0.4
        default:          return 0.0
        }
    }

    /// Legacy heuristic silence scoring (kept for reference).
    /// silence < 120 ms → 0.0 · 120–250 ms → 0.4–0.7 · >= 250 ms → 1.0
    private static func silenceScoreValue(silenceMs: Int) -> Float {
        switch silenceMs {
        case ..<120:    return 0.0
        case 120..<250: return 0.4 + Float(silenceMs - 120) / 130.0 * 0.3
        default:        return 1.0
        }
    }
}
