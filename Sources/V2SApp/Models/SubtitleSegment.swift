import Foundation

/// The complete passage that a recognizer split into individual captions. Translate
/// it as one paragraph so short replies retain their meaning, then map sentences
/// back only when the translator preserves the same number of sentence boundaries.
struct SentenceTranslationContext: Equatable, Sendable {
    let sentences: [String]
    let sentenceIndex: Int
    let draftSegmentID: UUID

    init?(sentences: [String], sentenceIndex: Int, draftSegmentID: UUID) {
        guard sentences.count > 1, sentences.indices.contains(sentenceIndex),
              sentences.allSatisfy({ Self.splitSentences($0).count == 1 }),
              Self.splitSentences(sentences.joined()).count == sentences.count else { return nil }
        self.sentences = sentences
        self.sentenceIndex = sentenceIndex
        self.draftSegmentID = draftSegmentID
    }

    var sourceText: String { sentences.joined() }

    func matchesCaption(_ text: String) -> Bool {
        Self.equivalentSource(text, sentences[sentenceIndex])
    }

    func matchesPassage(_ text: String) -> Bool {
        let parts = Self.splitSentences(text)
        return parts.count == sentences.count
            && zip(parts, sentences).allSatisfy { Self.equivalentSource($0, $1) }
    }

    func translatedSentence(from translation: String) -> String? {
        let parts = Self.splitSentences(translation)
        guard parts.count == sentences.count else { return nil }
        return parts[sentenceIndex]
    }

    static func equivalentSource(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ text: String) -> String {
            var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // ASR often adds a final full stop without changing the words. Preserve
            // meaningful punctuation: questions, exclamations, ellipses and commas.
            if let last = text.last, ".。".contains(last),
               text.dropLast().last.map({ !".。".contains($0) }) == true {
                text.removeLast()
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !key(lhs).isEmpty && key(lhs) == key(rhs)
    }

    private static func splitSentences(_ text: String) -> [String] {
        let source = text as NSString
        return SentenceBoundaryHeuristics.sentenceRanges(in: source).compactMap {
            let sentence = source.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
    }
}

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
