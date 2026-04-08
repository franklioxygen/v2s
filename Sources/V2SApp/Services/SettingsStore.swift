import Foundation

@MainActor
final class SettingsStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = appSupportRoot.appendingPathComponent("v2s", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("settings.json")
        }
    }

    func load() -> AppSettings {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileReadNoSuchFileError {
                fputs("Failed to load settings: \(error)\n", stderr)
            }
            return .default
        }
    }

    func save(_ settings: AppSettings) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let data = try JSONEncoder.pretty.encode(settings)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            fputs("Failed to save settings: \(error)\n", stderr)
        }
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
