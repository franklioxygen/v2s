import Foundation

enum SentenceBoundaryHeuristics {
    private enum TrailingPeriodRole {
        case terminal
        case nonTerminal
        case absent
    }

    private static let joinerTrimCharacterSet = CharacterSet(charactersIn: "\"'“”‘’([{")
    private static let titleAbbreviations: Set<String> = [
        "adm.", "brig.", "capt.", "cmdr.", "col.", "dr.", "gen.", "gov.", "hon.", "jr.", "lt.",
        "maj.", "mr.", "mrs.", "ms.", "pres.", "prof.", "rep.", "rev.", "sec.", "sen.", "sgt.", "sr."
    ]

    static func sentenceRanges(in text: NSString) -> [NSRange] {
        var rawRanges: [NSRange] = []
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.bySentences, .substringNotRequired]
        ) { _, substringRange, _, _ in
            guard substringRange.length > 0 else {
                return
            }
            rawRanges.append(substringRange)
        }

        guard rawRanges.count >= 2 else {
            return rawRanges
        }

        var mergedRanges: [NSRange] = []
        var currentRange = rawRanges[0]

        for nextRange in rawRanges.dropFirst() {
            let currentText = text.substring(with: currentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nextText = text.substring(with: nextRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if endsWithLikelyNonTerminalAbbreviation(in: currentText, followedBy: nextText) {
                let mergedEnd = nextRange.location + nextRange.length
                currentRange = NSRange(location: currentRange.location, length: mergedEnd - currentRange.location)
            } else {
                mergedRanges.append(currentRange)
                currentRange = nextRange
            }
        }

        mergedRanges.append(currentRange)
        return mergedRanges
    }

    static func endsWithLikelySentenceTerminator(in text: String, followedBy nextText: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastCharacter = trimmed.last else {
            return false
        }

        if "!?。！？;；".contains(lastCharacter) {
            return true
        }

        guard lastCharacter == "." else {
            return false
        }

        return trailingPeriodRole(in: trimmed, followedBy: nextText) == .terminal
    }

    static func endsWithLikelyNonTerminalAbbreviation(in text: String, followedBy nextText: String? = nil) -> Bool {
        trailingPeriodRole(in: text, followedBy: nextText) == .nonTerminal
    }

    private static func trailingPeriodRole(in text: String, followedBy nextText: String?) -> TrailingPeriodRole {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".") else {
            return .absent
        }

        let token = trailingToken(in: trimmed)
        if isSingleUppercaseInitial(token) {
            guard let nextText else {
                return .nonTerminal
            }

            return nextTextStartsUppercaseWord(nextText) ? .nonTerminal : .terminal
        }

        if isLikelyNameTitle(token) {
            guard let nextText else {
                return .nonTerminal
            }

            return nextTextStartsUppercaseWord(nextText) ? .nonTerminal : .terminal
        }

        if isMultiInitialAbbreviation(token) {
            guard let nextText else {
                return .terminal
            }

            return nextTextStartsWordLike(nextText) ? .nonTerminal : .terminal
        }

        return .terminal
    }

    private static func trailingToken(in text: String) -> String {
        guard let rawToken = text.split(whereSeparator: \.isWhitespace).last else {
            return text
        }

        return String(rawToken).trimmingCharacters(in: joinerTrimCharacterSet)
    }

    private static func isSingleUppercaseInitial(_ token: String) -> Bool {
        let cleaned = token.trimmingCharacters(in: joinerTrimCharacterSet)
        guard cleaned.count == 2,
              cleaned.hasSuffix("."),
              let firstScalar = cleaned.unicodeScalars.first else {
            return false
        }

        return CharacterSet.uppercaseLetters.contains(firstScalar)
    }

    private static func isLikelyNameTitle(_ token: String) -> Bool {
        titleAbbreviations.contains(token.lowercased())
    }

    private static func isMultiInitialAbbreviation(_ token: String) -> Bool {
        let cleanedScalars = Array(token.trimmingCharacters(in: joinerTrimCharacterSet).unicodeScalars)
        guard cleanedScalars.count >= 4, cleanedScalars.count.isMultiple(of: 2) else {
            return false
        }

        var periodCount = 0

        for (index, scalar) in cleanedScalars.enumerated() {
            if index.isMultiple(of: 2) {
                guard CharacterSet.uppercaseLetters.contains(scalar) else {
                    return false
                }
            } else {
                guard scalar == "." else {
                    return false
                }
                periodCount += 1
            }
        }

        return periodCount >= 2
    }

    private static func nextTextStartsUppercaseWord(_ text: String) -> Bool {
        guard let leadingScalar = firstSignificantScalar(in: text) else {
            return false
        }

        return CharacterSet.uppercaseLetters.contains(leadingScalar)
    }

    private static func nextTextStartsWordLike(_ text: String) -> Bool {
        guard let leadingScalar = firstSignificantScalar(in: text) else {
            return false
        }

        return CharacterSet.alphanumerics.contains(leadingScalar)
    }

    private static func firstSignificantScalar(in text: String) -> Unicode.Scalar? {
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }

            if joinerTrimCharacterSet.contains(scalar) {
                continue
            }

            return scalar
        }

        return nil
    }
}
