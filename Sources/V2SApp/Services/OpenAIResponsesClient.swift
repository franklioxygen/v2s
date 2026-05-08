import Foundation

struct OpenAIResponsesClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidRequest
        case invalidResponse
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "API key is missing."
            case .invalidRequest:
                return "Could not build the API request."
            case .invalidResponse:
                return "API returned an unreadable response."
            case .apiError(let message):
                return message
            }
        }
    }

    enum ImageInputStatus: Equatable {
        case notProvided
        case sent
        case rejectedByProvider
    }

    let apiKey: String
    let baseURLString: String
    let model: String

    func fetchAvailableModels() async throws -> [String] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ClientError.missingAPIKey }
        if Self.isGeminiAPI(baseURLString) {
            return try await fetchGeminiModels(apiKey: trimmedKey)
        } else {
            return try await fetchOpenAIModels(apiKey: trimmedKey)
        }
    }

    func testConnection() async throws -> String {
        let (text, _) = try await respond(
            instructions: "You are a connectivity test assistant. Reply with exactly one short sentence.",
            prompt: "Reply with: OK",
            screenshotPNGData: nil
        )
        return text
    }

    /// Returns the response text and whether the screenshot was actually included in the request.
    /// The image status distinguishes text-only requests from providers that rejected image input
    /// and were automatically retried without the screenshot.
    func respond(
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> (text: String, imageStatus: ImageInputStatus) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty == false else {
            throw ClientError.missingAPIKey
        }

        if Self.isGeminiAPI(baseURLString) {
            return try await respondGemini(
                apiKey: trimmedKey,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: screenshotPNGData
            )
        } else {
            return try await respondOpenAI(
                apiKey: trimmedKey,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: screenshotPNGData
            )
        }
    }

    // MARK: - OpenAI Chat Completions API (universal: works with OpenAI + all compatible providers)

    private func respondOpenAI(
        apiKey: String,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> (text: String, imageStatus: ImageInputStatus) {
        do {
            let text = try await respondOpenAIRequest(
                apiKey: apiKey,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: screenshotPNGData
            )
            return (text, screenshotPNGData == nil ? .notProvided : .sent)
        } catch ClientError.apiError(let message)
            where screenshotPNGData != nil && Self.isImageUnsupportedError(message) {
            // Provider doesn't support vision — retry without the screenshot.
            let text = try await respondOpenAIRequest(
                apiKey: apiKey,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: nil
            )
            return (text, .rejectedByProvider)
        }
    }

    private func respondOpenAIRequest(
        apiKey: String,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> String {
        guard let url = Self.openAIChatURL(from: baseURLString) else {
            throw ClientError.invalidRequest
        }

        // Build user message content: text-only or multipart (text + image)
        let userContent: Any
        if let data = screenshotPNGData {
            userContent = [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(data.base64EncodedString())", "detail": "low"]]
            ] as [[String: Any]]
        } else {
            userContent = prompt
        }

        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "model": resolvedModel.isEmpty ? "gpt-4o" : resolvedModel,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": 900
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.apiError(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }

        guard let text = Self.chatOutputText(from: data), text.isEmpty == false else {
            throw ClientError.invalidResponse
        }
        return text
    }

    private static func openAIChatURL(from baseURLString: String) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "https://api.openai.com/v1" : trimmed
        var sanitized = resolved
        while sanitized.last == "\\" || sanitized.last == "/" { sanitized = String(sanitized.dropLast()) }
        guard var components = URLComponents(string: sanitized) else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("chat/completions") {
            components.path = "/" + ([path, "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/"))
        }
        return components.url
    }

    private static func chatOutputText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Model list fetching

    private func fetchGeminiModels(apiKey: String) async throws -> [String] {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "https://generativelanguage.googleapis.com/v1beta" : trimmed
        var stripped = base
        while stripped.last == "/" || stripped.last == "\\" { stripped = String(stripped.dropLast()) }
        guard var components = URLComponents(string: "\(stripped)/models") else { throw ClientError.invalidRequest }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw ClientError.invalidRequest }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.apiError(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { throw ClientError.invalidResponse }

        return models.compactMap { item -> String? in
            guard let name = item["name"] as? String else { return nil }
            if let methods = item["supportedGenerationMethods"] as? [String],
               !methods.contains("generateContent") { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }.sorted()
    }

    private func fetchOpenAIModels(apiKey: String) async throws -> [String] {
        guard let url = Self.openAIModelsURL(from: baseURLString) else { throw ClientError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.apiError(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { throw ClientError.invalidResponse }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    private static func openAIModelsURL(from baseURLString: String) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "https://api.openai.com/v1" : trimmed
        var sanitized = resolved
        while sanitized.last == "\\" || sanitized.last == "/" { sanitized = String(sanitized.dropLast()) }
        guard var components = URLComponents(string: sanitized) else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("models") {
            components.path = "/" + ([path, "models"].filter { !$0.isEmpty }.joined(separator: "/"))
        }
        return components.url
    }

    // MARK: - Google Gemini generateContent API

    private func respondGemini(
        apiKey: String,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> (text: String, imageStatus: ImageInputStatus) {
        do {
            let text = try await respondGeminiRequest(
                apiKey: apiKey,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: screenshotPNGData
            )
            return (text, screenshotPNGData == nil ? .notProvided : .sent)
        } catch ClientError.apiError(let message)
            where screenshotPNGData != nil && Self.isImageUnsupportedError(message) {
            let text = try await respondGeminiRequest(
                apiKey: apiKey,
                instructions: instructions,
                prompt: prompt,
                screenshotPNGData: nil
            )
            return (text, .rejectedByProvider)
        }
    }

    private func respondGeminiRequest(
        apiKey: String,
        instructions: String,
        prompt: String,
        screenshotPNGData: Data?
    ) async throws -> String {
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedModel.isEmpty == false,
              let url = Self.geminiURL(from: baseURLString, model: resolvedModel, apiKey: apiKey) else {
            throw ClientError.invalidRequest
        }

        var parts: [[String: Any]] = [["text": prompt]]
        if let data = screenshotPNGData {
            parts.append([
                "inline_data": [
                    "mime_type": "image/png",
                    "data": data.base64EncodedString()
                ]
            ])
        }

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": 900]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.apiError(Self.errorMessage(from: data) ?? "Gemini request failed with HTTP \(http.statusCode).")
        }

        guard let text = Self.geminiOutputText(from: data), text.isEmpty == false else {
            throw ClientError.invalidResponse
        }
        return text
    }

    private static func geminiURL(from baseURLString: String, model: String, apiKey: String) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "https://generativelanguage.googleapis.com/v1beta" : trimmed
        // Strip trailing slashes or backslashes (user may accidentally type a backslash)
        var stripped = base
        while stripped.last == "/" || stripped.last == "\\" {
            stripped = String(stripped.dropLast())
        }
        guard var components = URLComponents(string: "\(stripped)/models/\(model):generateContent") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url
    }

    private static func geminiOutputText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        let chunks = parts.compactMap { $0["text"] as? String }
        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shared helpers

    private static func isGeminiAPI(_ baseURLString: String) -> Bool {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            .contains("generativelanguage.googleapis.com")
    }

    private static func isImageUnsupportedError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("image")
            || normalized.contains("vision")
            || normalized.contains("visual")
            || normalized.contains("multimodal")
            || normalized.contains("multi-modal")
            || normalized.contains("inline_data")
            || normalized.contains("no endpoints")
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // OpenAI format: {"error": {"message": "..."}}
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        // Gemini format: {"error": {"message": "..."}} or {"error": {"status": "..."}}
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let status = error["status"] as? String { return status }
        }
        return nil
    }
}
