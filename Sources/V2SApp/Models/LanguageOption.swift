import Foundation

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let displayName: String

    func localizedDisplayName(in interfaceLanguageID: String) -> String {
        LanguageCatalog.displayName(for: id, in: interfaceLanguageID)
    }
}

enum LanguageCatalog {
    static let common: [LanguageOption] = [
        LanguageOption(id: "en", displayName: "English"),
        LanguageOption(id: "zh-Hans", displayName: "Chinese (Simplified)"),
        LanguageOption(id: "es", displayName: "Spanish"),
        LanguageOption(id: "de", displayName: "German"),
        LanguageOption(id: "ja", displayName: "Japanese"),
        LanguageOption(id: "fr", displayName: "French"),
        LanguageOption(id: "ko", displayName: "Korean"),
        LanguageOption(id: "ar", displayName: "Arabic"),
        LanguageOption(id: "pt", displayName: "Portuguese"),
        LanguageOption(id: "ru", displayName: "Russian"),
    ]

    static func displayName(for identifier: String) -> String {
        common.first(where: { $0.id == identifier })?.displayName ?? identifier
    }

    static func displayName(for identifier: String, in interfaceLanguageID: String) -> String {
        let locale = Locale(identifier: interfaceLanguageID)
        return locale.localizedString(forIdentifier: identifier)
            ?? displayName(for: identifier)
    }

    static func preferredInterfaceLanguageID(storedIdentifier: String?) -> String {
        AppLocalization.resolvedInterfaceLanguageID(storedIdentifier: storedIdentifier)
    }

    static func speechLocaleIdentifier(for identifier: String) -> String {
        switch identifier {
        case "en": return "en-US"
        case "zh-Hans": return "zh-CN"
        case "es": return "es-ES"
        case "de": return "de-DE"
        case "ja": return "ja-JP"
        case "fr": return "fr-FR"
        case "ko": return "ko-KR"
        case "ar": return "ar-SA"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        default: return identifier
        }
    }
}
