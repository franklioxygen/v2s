import Foundation

struct HotKeyBinding: Codable, Equatable {
    var key: String       // single lowercase character, e.g. "f"
    var useCommand: Bool
    var useOption: Bool
    var useControl: Bool
    var useShift: Bool

    static let defaultFollowUp   = HotKeyBinding(key: "f", useCommand: true, useOption: true, useControl: false, useShift: false)
    static let defaultAsk        = HotKeyBinding(key: "g", useCommand: true, useOption: true, useControl: false, useShift: false)
    static let defaultSwitchMode = HotKeyBinding(key: "t", useCommand: true, useOption: true, useControl: false, useShift: false)

    var displayString: String {
        var parts: [String] = []
        if useControl  { parts.append("⌃") }
        if useOption   { parts.append("⌥") }
        if useShift    { parts.append("⇧") }
        if useCommand  { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }
}

struct AppSettings: Codable {
    var selectedSourceID: String?
    var selectedSourceIDs: [String]
    var sourceLanguageOverrides: [String: String]
    var sourceOutputLanguageOverrides: [String: String]
    var inputLanguageID: String
    var outputLanguageID: String
    var interfaceLanguageID: String?
    var overlayStyle: OverlayStyle
    var subtitleMode: SubtitleMode
    var subtitleDisplayMode: SubtitleDisplayMode
    var glossary: [String: String]
    var privacyModeEnabled: Bool
    var gptAPIKey: String
    var gptAPIBaseURL: String
    var gptModel: String
    var gptSkills: String
    var autoDetectConversationLanguages: Bool
    var hotKeyFollowUp: HotKeyBinding
    var hotKeyAsk: HotKeyBinding
    var hotKeySwitchMode: HotKeyBinding

    static let `default` = AppSettings(
        selectedSourceID: nil,
        selectedSourceIDs: [],
        sourceLanguageOverrides: [:],
        sourceOutputLanguageOverrides: [:],
        inputLanguageID: "en",
        outputLanguageID: "zh-Hans",
        interfaceLanguageID: nil,
        overlayStyle: .default,
        subtitleMode: .balanced,
        subtitleDisplayMode: .both,
        glossary: [:],
        privacyModeEnabled: true,
        gptAPIKey: "",
        gptAPIBaseURL: "https://api.openai.com/v1",
        gptModel: "gpt-4o",
        gptSkills: "",
        autoDetectConversationLanguages: true,
        hotKeyFollowUp: .defaultFollowUp,
        hotKeyAsk: .defaultAsk,
        hotKeySwitchMode: .defaultSwitchMode
    )

    // Custom decoder so existing settings files load cleanly as new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSourceID = try? c.decodeIfPresent(String.self, forKey: .selectedSourceID)
        selectedSourceIDs = (try? c.decodeIfPresent([String].self, forKey: .selectedSourceIDs))
            ?? selectedSourceID.map { [$0] }
            ?? AppSettings.default.selectedSourceIDs
        sourceLanguageOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .sourceLanguageOverrides))
            ?? AppSettings.default.sourceLanguageOverrides
        sourceOutputLanguageOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .sourceOutputLanguageOverrides))
            ?? AppSettings.default.sourceOutputLanguageOverrides
        inputLanguageID = (try? c.decodeIfPresent(String.self, forKey: .inputLanguageID))
            ?? AppSettings.default.inputLanguageID
        outputLanguageID = (try? c.decodeIfPresent(String.self, forKey: .outputLanguageID))
            ?? AppSettings.default.outputLanguageID
        interfaceLanguageID = try? c.decodeIfPresent(String.self, forKey: .interfaceLanguageID)
        overlayStyle = (try? c.decodeIfPresent(OverlayStyle.self, forKey: .overlayStyle))
            ?? AppSettings.default.overlayStyle
        subtitleMode = (try? c.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode))
            ?? AppSettings.default.subtitleMode
        subtitleDisplayMode = (try? c.decodeIfPresent(SubtitleDisplayMode.self, forKey: .subtitleDisplayMode))
            ?? AppSettings.default.subtitleDisplayMode
        glossary = (try? c.decodeIfPresent([String: String].self, forKey: .glossary))
            ?? AppSettings.default.glossary
        privacyModeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .privacyModeEnabled))
            ?? AppSettings.default.privacyModeEnabled
        gptAPIKey = (try? c.decodeIfPresent(String.self, forKey: .gptAPIKey))
            ?? AppSettings.default.gptAPIKey
        gptAPIBaseURL = (try? c.decodeIfPresent(String.self, forKey: .gptAPIBaseURL))
            ?? AppSettings.default.gptAPIBaseURL
        gptModel = (try? c.decodeIfPresent(String.self, forKey: .gptModel))
            ?? AppSettings.default.gptModel
        gptSkills = (try? c.decodeIfPresent(String.self, forKey: .gptSkills))
            ?? AppSettings.default.gptSkills
        autoDetectConversationLanguages = (try? c.decodeIfPresent(Bool.self, forKey: .autoDetectConversationLanguages))
            ?? AppSettings.default.autoDetectConversationLanguages
        hotKeyFollowUp = (try? c.decodeIfPresent(HotKeyBinding.self, forKey: .hotKeyFollowUp))
            ?? AppSettings.default.hotKeyFollowUp
        hotKeyAsk = (try? c.decodeIfPresent(HotKeyBinding.self, forKey: .hotKeyAsk))
            ?? AppSettings.default.hotKeyAsk
        hotKeySwitchMode = (try? c.decodeIfPresent(HotKeyBinding.self, forKey: .hotKeySwitchMode))
            ?? AppSettings.default.hotKeySwitchMode
    }

    init(
        selectedSourceID: String?,
        selectedSourceIDs: [String],
        sourceLanguageOverrides: [String: String],
        sourceOutputLanguageOverrides: [String: String],
        inputLanguageID: String,
        outputLanguageID: String,
        interfaceLanguageID: String?,
        overlayStyle: OverlayStyle,
        subtitleMode: SubtitleMode,
        subtitleDisplayMode: SubtitleDisplayMode,
        glossary: [String: String],
        privacyModeEnabled: Bool,
        gptAPIKey: String,
        gptAPIBaseURL: String,
        gptModel: String,
        gptSkills: String,
        autoDetectConversationLanguages: Bool,
        hotKeyFollowUp: HotKeyBinding,
        hotKeyAsk: HotKeyBinding,
        hotKeySwitchMode: HotKeyBinding
    ) {
        self.selectedSourceID = selectedSourceID
        self.selectedSourceIDs = selectedSourceIDs
        self.sourceLanguageOverrides = sourceLanguageOverrides
        self.sourceOutputLanguageOverrides = sourceOutputLanguageOverrides
        self.inputLanguageID  = inputLanguageID
        self.outputLanguageID = outputLanguageID
        self.interfaceLanguageID = interfaceLanguageID
        self.overlayStyle     = overlayStyle
        self.subtitleMode     = subtitleMode
        self.subtitleDisplayMode = subtitleDisplayMode
        self.glossary         = glossary
        self.privacyModeEnabled = privacyModeEnabled
        self.gptAPIKey = gptAPIKey
        self.gptAPIBaseURL = gptAPIBaseURL
        self.gptModel = gptModel
        self.gptSkills = gptSkills
        self.autoDetectConversationLanguages = autoDetectConversationLanguages
        self.hotKeyFollowUp = hotKeyFollowUp
        self.hotKeyAsk = hotKeyAsk
        self.hotKeySwitchMode = hotKeySwitchMode
    }
}
