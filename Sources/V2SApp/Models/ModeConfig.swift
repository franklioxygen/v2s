import Foundation

// MARK: - SubtitleMode

enum SubtitleMode: String, Codable, CaseIterable, Sendable {
    case balanced
    case follow
    case reading

    private var localizationKeys: SubtitleModeLocalizationKeys {
        switch self {
        case .balanced:
            return SubtitleModeLocalizationKeys(
                name: .modeBalancedName,
                detail: .modeBalancedDetail,
                longDescription: .modeBalancedLong,
                bestFor: .modeBalancedBestFor,
                tradeoff: .modeBalancedTradeoff
            )
        case .follow:
            return SubtitleModeLocalizationKeys(
                name: .modeFollowName,
                detail: .modeFollowDetail,
                longDescription: .modeFollowLong,
                bestFor: .modeFollowBestFor,
                tradeoff: .modeFollowTradeoff
            )
        case .reading:
            return SubtitleModeLocalizationKeys(
                name: .modeReadingName,
                detail: .modeReadingDetail,
                longDescription: .modeReadingLong,
                bestFor: .modeReadingBestFor,
                tradeoff: .modeReadingTradeoff
            )
        }
    }

    func displayName(in languageID: String) -> String {
        AppLocalization.string(localizationKeys.name, languageID: languageID)
    }

    func detail(in languageID: String) -> String {
        AppLocalization.string(localizationKeys.detail, languageID: languageID)
    }

    func longDescription(in languageID: String) -> String {
        AppLocalization.string(localizationKeys.longDescription, languageID: languageID)
    }

    func bestFor(in languageID: String) -> String {
        AppLocalization.string(localizationKeys.bestFor, languageID: languageID)
    }

    func tradeoff(in languageID: String) -> String {
        AppLocalization.string(localizationKeys.tradeoff, languageID: languageID)
    }

    var config: ModeConfig {
        switch self {
        case .balanced: return .balanced
        case .follow: return .follow
        case .reading: return .reading
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
        maxChunkAudioSec: 3.0,
        minSilenceCommitMs: 280
    )

    static let follow = ModeConfig(
        firstTokenTargetMs: 200,
        commitSourceTargetMs: 450,
        commitTranslationTargetMs: 700,
        maxChunkAudioSec: 2.2,
        minSilenceCommitMs: 220
    )

    static let reading = ModeConfig(
        firstTokenTargetMs: 400,
        commitSourceTargetMs: 800,
        commitTranslationTargetMs: 1200,
        maxChunkAudioSec: 3.5,
        minSilenceCommitMs: 340
    )

    static func config(for mode: SubtitleMode) -> ModeConfig {
        mode.config
    }
}

// MARK: - ChunkScorer

/// Computes the weighted commit-readiness score for a draft segment.
/// Strategy §8.3 weights:
///   SilenceScore 0.30 · StabilityScore 0.20 · BoundaryScore 0.20
///   LengthFitScore 0.15 · ConfidenceScore 0.15
enum ChunkScorer {
    static func score(
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
}

private struct SubtitleModeLocalizationKeys {
    let name: AppTextKey
    let detail: AppTextKey
    let longDescription: AppTextKey
    let bestFor: AppTextKey
    let tradeoff: AppTextKey
}
