import Foundation

/// Applies a user-defined glossary table to a translated string.
/// Source terms are matched case-insensitively and replaced with the target term.
struct GlossaryService: Sendable {
    func apply(to text: String, glossary: [String: String]) -> String {
        guard !glossary.isEmpty else { return text }

        let entries = glossary
            .map { (source: $0.key.trimmingCharacters(in: .whitespacesAndNewlines), target: $0.value) }
            .filter { !$0.source.isEmpty }
            .sorted { lhs, rhs in
                if lhs.source.count == rhs.source.count {
                    let caseInsensitiveOrder = lhs.source.localizedCaseInsensitiveCompare(rhs.source)
                    if caseInsensitiveOrder != .orderedSame {
                        return caseInsensitiveOrder == .orderedAscending
                    }
                    return lhs.source < rhs.source
                }
                return lhs.source.count > rhs.source.count
            }

        guard !entries.isEmpty else { return text }

        let pattern = entries
            .map { Self.boundaryAwarePattern(for: $0.source) }
            .joined(separator: "|")

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let locale = Locale.current
        let replacements = entries.reduce(into: [String: String]()) { replacements, entry in
            let key = normalizedKey(entry.source, locale: locale)
            if replacements[key] == nil {
                replacements[key] = entry.target
            }
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var currentLocation = 0

        for match in matches {
            guard match.range.location >= currentLocation else {
                continue
            }

            if match.range.location > currentLocation {
                result += nsText.substring(with: NSRange(location: currentLocation, length: match.range.location - currentLocation))
            }

            let matchedText = nsText.substring(with: match.range)
            let normalizedMatch = normalizedKey(matchedText, locale: locale)
            result += replacements[normalizedMatch] ?? matchedText
            currentLocation = match.range.location + match.range.length
        }

        if currentLocation < nsText.length {
            result += nsText.substring(from: currentLocation)
        }

        return result
    }

    private func normalizedKey(_ text: String, locale: Locale) -> String {
        text.folding(options: [.caseInsensitive], locale: locale)
    }

    /// Wraps a term in word-boundary lookarounds when its edges are letters or
    /// digits from a script with word boundaries, so entries like "AI" and
    /// "тест" cannot match inside larger words. CJK edges stay unwrapped, and
    /// the boundary class excludes CJK characters so Latin terms still match
    /// when directly adjacent to CJK characters (e.g. "使用AI模型").
    private static func boundaryAwarePattern(for source: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: source)
        let leading = source.unicodeScalars.first.map(isBoundaryRelevantScalar) == true
            ? "(?<!\(nonCJKWordCharacterClass))"
            : ""
        let trailing = source.unicodeScalars.last.map(isBoundaryRelevantScalar) == true
            ? "(?!\(nonCJKWordCharacterClass))"
            : ""
        return leading + escaped + trailing
    }

    private static let nonCJKWordCharacterClass =
        "[\\p{L}\\p{N}&&[^\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]]"

    private static func isBoundaryRelevantScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) && !isCJKScalar(scalar)
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, // Hangul Jamo
             0x2E80...0x2FFF, // CJK Radicals and punctuation
             0x3000...0x30FF, // Hiragana, Katakana, and CJK punctuation
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xA960...0xA97F, // Hangul Jamo Extended-A
             0xAC00...0xD7FF, // Hangul syllables and Jamo Extended-B
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFE30...0xFE6F, // CJK Compatibility Forms
             0xFF00...0xFFEF: // Fullwidth forms
            return true
        default:
            return false
        }
    }
}
