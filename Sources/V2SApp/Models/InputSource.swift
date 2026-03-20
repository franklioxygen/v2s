import Foundation

enum InputSourceCategory: String, CaseIterable, Codable {
    case application
    case microphone

    func displayName(in languageID: String) -> String {
        switch self {
        case .application:
            return AppLocalization.string(.application, languageID: languageID)
        case .microphone:
            return AppLocalization.string(.microphone, languageID: languageID)
        }
    }
}

struct InputSource: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let detail: String
    let category: InputSourceCategory

    static let preview = InputSource(
        id: "preview",
        name: AppLocalization.string(.previewSource, languageID: "en"),
        detail: "preview",
        category: .microphone
    )
}
