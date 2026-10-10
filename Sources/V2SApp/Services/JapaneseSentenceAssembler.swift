import Foundation
import NaturalLanguage

/// Builds translation units from finalized Japanese speech. A volatile result may end
/// mid-word or revise its punctuation, so it is only suitable for the live draft.
struct JapaneseSentenceAssembler {
    private(set) var pendingText = ""
    private var pendingAudioEnd: TimeInterval?
    private(set) var finalizedThrough: TimeInterval = -.infinity

    /// Recognition ranges, rather than text similarity, distinguish revisions from a
    /// speaker intentionally repeating the same words.
    mutating func appendFinal(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval,
        finalizedEnd: TimeInterval
    ) -> [String] {
        guard finalizedEnd.isFinite, finalizedEnd > finalizedThrough else { return [] }
        finalizedThrough = finalizedEnd
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var sentences: [String] = []
        // A new utterance after a substantial pause must not be attached to a dangling
        // particle from the preceding utterance. Use word times, not callback latency.
        if let pendingAudioEnd, start - pendingAudioEnd > 1.5 {
            sentences += flush()
        }
        let combined = preview(appending: text)
        pendingText = ""
        pendingAudioEnd = nil
        let source = combined as NSString
        let ranges = SentenceBoundaryHeuristics.sentenceRanges(in: source)
        let units = ranges.isEmpty ? [combined] : ranges.map { source.substring(with: $0) }
        for (index, unit) in units.enumerated() {
            let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
            // A late punctuation-only final is not a spoken caption. In the video
            // the recognizer occasionally finalizes a lone full stop after a passage.
            let punctuation = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            guard unit.unicodeScalars.contains(where: { !punctuation.contains($0) }) else { continue }
            if index == units.count - 1, Self.isIncomplete(unit) {
                pendingText = unit
                pendingAudioEnd = end
            } else {
                sentences.append(unit)
            }
        }
        return sentences
    }

    func preview(appending text: String) -> String {
        pendingText + text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func flush() -> [String] {
        defer {
            pendingText = ""
            pendingAudioEnd = nil
        }
        return pendingText.isEmpty ? [] : [pendingText]
    }

    static func isIncomplete(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return false }
        // Colloquial Japanese legitimately ends in て, で, から, etc. Never erase a
        // recognized sentence boundary just because its last word resembles a particle.
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’」』）)]}"))
        if SentenceBoundaryHeuristics.endsWithLikelySentenceTerminator(in: body) { return false }
        if "、,，".contains(last) { return true }
        if connectives.contains(text) { return true }

        // Test whole Japanese tokens. Suffix matching mistakes 私 / 少し / 仕事 /
        // ありがと for clauses ending in し or と and joins them to unrelated speech.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.japanese)
        var lastWord = ""
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            lastWord = String(text[range])
            return true
        }
        return incompleteEndings.contains(lastWord)
    }

    private static let connectives: Set<String> = [
        "ただ", "でも", "そこで", "それで", "それから", "そして", "だから", "しかし",
        "ところが", "なので", "つまり", "例えば", "たとえば", "もし", "まず"
    ]
    private static let incompleteEndings: Set<String> = [
        "けど", "けれど", "けれども", "から", "ので", "のに", "とか", "って",
        "で", "て", "が", "を", "に", "へ", "と", "し", "ば", "たら", "なら", "は"
    ]
}
