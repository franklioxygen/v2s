import Foundation

enum SessionState: String, Codable {
    case idle
    case running
    case error

    func displayName(in languageID: String) -> String {
        switch self {
        case .idle:
            return AppLocalization.string(.idle, languageID: languageID)
        case .running:
            return AppLocalization.string(.running, languageID: languageID)
        case .error:
            return AppLocalization.string(.error, languageID: languageID)
        }
    }
}
