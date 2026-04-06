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
            .map { NSRegularExpression.escapedPattern(for: $0.source) }
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
}
