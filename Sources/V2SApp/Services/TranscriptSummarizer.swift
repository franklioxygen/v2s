import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

enum TranscriptSummarizer {
    static func summarize(text: String, languageID: String) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return ""
        }

#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let summary = try await foundationModelSummary(
                    text: trimmedText,
                    languageID: languageID
                )
                if summary.isEmpty == false {
                    return summary
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The model can also be unavailable on supported OS versions.
                // Keep the feature useful with the same local fallback as macOS 15.
            }
        }
#endif

        try Task.checkCancellation()
        return extractiveSummary(text: trimmedText, languageID: languageID)
    }

    /// Produces a small, same-language summary without a generative model by
    /// ranking the transcript's sentences and retaining the strongest ones.
    static func extractiveSummary(text: String, languageID: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return ""
        }

        let sentenceRanges = SentenceBoundaryHeuristics.sentenceRanges(in: trimmedText as NSString)
        let sentences = sentenceRanges.compactMap { range -> String? in
            let sentence = (trimmedText as NSString)
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }

        guard sentences.count > 1 else {
            return trimmedText
        }

        let sentenceTerms = sentences.map { terms(in: $0, languageID: languageID) }
        var frequencies: [String: Int] = [:]
        for terms in sentenceTerms {
            for term in Set(terms) {
                frequencies[term, default: 0] += 1
            }
        }

        let targetCount = min(5, max(1, Int(ceil(Double(sentences.count) * 0.3))))
        let rankedIndices = sentences.indices.sorted { lhs, rhs in
            let lhsScore = sentenceScore(
                terms: sentenceTerms[lhs],
                frequencies: frequencies,
                position: lhs
            )
            let rhsScore = sentenceScore(
                terms: sentenceTerms[rhs],
                frequencies: frequencies,
                position: rhs
            )
            if lhsScore == rhsScore {
                return lhs < rhs
            }
            return lhsScore > rhsScore
        }

        return joinedSummary(
            of: rankedIndices
                .prefix(targetCount)
                .sorted()
                .map { sentences[$0] }
        )
    }

    /// Joins the retained sentences with a space only where the script needs one.
    /// CJK sentences already carry their own full-width terminator, so a space
    /// after it would appear in the summary but not in the transcript it came from.
    private static func joinedSummary(of sentences: [String]) -> String {
        sentences.reduce(into: "") { summary, sentence in
            guard summary.isEmpty == false else {
                summary = sentence
                return
            }

            let needsSeparator = summary.unicodeScalars.last.map(isCJKSummaryTerminator) != true
            summary += (needsSeparator ? " " : "") + sentence
        }
    }

    private static func isCJKSummaryTerminator(_ scalar: Unicode.Scalar) -> Bool {
        isCJKScalar(scalar) || scalar == "\u{FF01}" || scalar == "\u{FF1F}"
    }

    private static func terms(in text: String, languageID: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        let languageCode = languageID
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? languageID
        tokenizer.setLanguage(NLLanguage(rawValue: languageCode))

        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let term = String(text[range]).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: languageID)
            )
            if isUseful(term: term) {
                result.append(term)
            }
            return true
        }
        return result
    }

    private static func isUseful(term: String) -> Bool {
        if englishStopWords.contains(term) {
            return false
        }

        if term.count > 1 {
            return true
        }

        // Keep single-character CJK terms, but discard Latin initials and digits.
        return term.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x2E80...0x9FFF).contains(scalar.value)
            || (0xAC00...0xD7AF).contains(scalar.value)
    }

    private static func sentenceScore(
        terms: [String],
        frequencies: [String: Int],
        position: Int
    ) -> Double {
        guard terms.isEmpty == false else {
            return 0
        }

        let relevance = Set(terms).reduce(0.0) { score, term in
            score + Double(frequencies[term] ?? 0)
        } / sqrt(Double(terms.count))
        let openingContextBonus = 0.2 / Double(position + 1)
        return relevance + openingContextBonus
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func foundationModelSummary(
        text: String,
        languageID: String
    ) async throws -> String {
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: languageID)
            ?? LanguageCatalog.displayName(for: languageID)
        let prompt = """
        Provide a concise summary of the following transcript.
        The summary must be written in \(languageName) (\(languageID)).
        Preserve the key points and do not translate the summary into any other language.

        Transcript:
        \(text)
        """
        let response = try await LanguageModelSession().respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
#endif

    private static let englishStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by",
        "for", "from", "had", "has", "have", "he", "her", "hers", "him",
        "his", "i", "in", "is", "it", "its", "me", "my", "of", "on", "or",
        "our", "ours", "she", "that", "the", "their", "theirs", "them", "they",
        "this", "to", "was", "we", "were", "will", "with", "you", "your", "yours",
    ]
}
