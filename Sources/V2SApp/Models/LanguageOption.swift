import Foundation

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

enum LanguageCatalog {
    static let common: [LanguageOption] = [
        LanguageOption(id: "en", displayName: "English"),
        LanguageOption(id: "zh-Hans", displayName: "Chinese (Simplified)"),
        LanguageOption(id: "ja", displayName: "Japanese"),
        LanguageOption(id: "ko", displayName: "Korean"),
        LanguageOption(id: "fr", displayName: "French"),
        LanguageOption(id: "de", displayName: "German"),
    ]

    static func displayName(for identifier: String) -> String {
        common.first(where: { $0.id == identifier })?.displayName ?? identifier
    }

    static func speechLocaleIdentifier(for identifier: String) -> String {
        switch identifier {
        case "en": return "en-US"
        case "zh-Hans": return "zh-CN"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        default: return identifier
        }
    }
}
