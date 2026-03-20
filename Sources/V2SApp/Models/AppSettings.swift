import Foundation

struct AppSettings: Codable {
    var selectedSourceID: String?
    var inputLanguageID: String
    var outputLanguageID: String
    var interfaceLanguageID: String?
    var overlayStyle: OverlayStyle
    var subtitleMode: SubtitleMode
    var glossary: [String: String]

    static let `default` = AppSettings(
        selectedSourceID: nil,
        inputLanguageID: "en",
        outputLanguageID: "zh-Hans",
        interfaceLanguageID: nil,
        overlayStyle: .default,
        subtitleMode: .balanced,
        glossary: [:]
    )

    // Custom decoder so existing settings files (without subtitleMode/glossary) load cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSourceID = try c.decodeIfPresent(String.self, forKey: .selectedSourceID)
        inputLanguageID  = try c.decode(String.self, forKey: .inputLanguageID)
        outputLanguageID = try c.decode(String.self, forKey: .outputLanguageID)
        interfaceLanguageID = try c.decodeIfPresent(String.self, forKey: .interfaceLanguageID)
        overlayStyle     = try c.decode(OverlayStyle.self, forKey: .overlayStyle)
        subtitleMode     = try c.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode) ?? .balanced
        glossary         = try c.decodeIfPresent([String: String].self, forKey: .glossary) ?? [:]
    }

    init(
        selectedSourceID: String?,
        inputLanguageID: String,
        outputLanguageID: String,
        interfaceLanguageID: String?,
        overlayStyle: OverlayStyle,
        subtitleMode: SubtitleMode,
        glossary: [String: String]
    ) {
        self.selectedSourceID = selectedSourceID
        self.inputLanguageID  = inputLanguageID
        self.outputLanguageID = outputLanguageID
        self.interfaceLanguageID = interfaceLanguageID
        self.overlayStyle     = overlayStyle
        self.subtitleMode     = subtitleMode
        self.glossary         = glossary
    }
}
