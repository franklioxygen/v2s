import Foundation

struct WordToken: Equatable, Sendable {
    let text: String
    let startMs: Int
    let endMs: Int
    let confidence: Float
    let stable: Bool
}

struct DraftSegment: Equatable, Sendable {
    let segmentId: UUID
    var sourceText: String
    var stablePrefixLength: Int
    var mutableTailText: String
    var avgConfidence: Float
    let startMs: Int
    var lastUpdateMs: Int
    var silenceMs: Int
    var stabilityScore: Float
    var boundaryScore: Float
    var chunkScore: Float
    var vadProbability: Float
    var words: [WordToken]

    var stablePrefixText: String {
        String(sourceText.prefix(stablePrefixLength))
    }
}

struct CommittedSegment: Equatable, Sendable {
    let segmentId: UUID
    var sourceText: String
    var translationText: String
    let startMs: Int
    var endMs: Int
    let committedAtMs: Int
    var translatedAtMs: Int?
    var sourceRevisionCount: Int
    var translationRevisionCount: Int
    var glossaryHits: [String]
    var displayDurationMs: Int
}
