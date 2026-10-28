import Foundation

enum AnthropicError: LocalizedError {
    case notConfigured
    case networkError(String)
    case apiError(String)
    case noContent
    case truncated

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Anthropic API Key fehlt. Bitte in den Einstellungen hinterlegen."
        case .networkError(let msg):
            return "Verbindungsproblem: \(msg)"
        case .apiError(let msg):
            return "Fehler von Anthropic: \(msg)"
        case .noContent:
            return "Keine Antwort erhalten. Bitte nochmal versuchen."
        case .truncated:
            return "Die Antwort wurde abgeschnitten (zu lang). Bitte weniger Stichpunkte auf einmal diktieren."
        }
    }
}

struct AnthropicMessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Message]
}

struct AnthropicMessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }

    let content: [ContentBlock]?
    let stop_reason: String?
}

private struct AnthropicErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

enum AnthropicService {
    static let model = "claude-sonnet-5-5"
    static let maxTokens = 2048
    static let apiVersion = "2023-06-01"
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    static func complete(systemPrompt: String, userMessage: String) async throws -> String {
        guard let apiKey = KeychainService.load(key: .anthropicAPIKey) else {
            throw AnthropicError.notConfigured
        }

        let payload = AnthropicMessagesRequest(
            model: model,
            max_tokens: maxTokens,
            system: systemPrompt,
            messages: [.init(role: "user", content: userMessage)]
        )

        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicError.networkError("Keine g\u{00FC}ltige Antwort")
        }

        guard httpResponse.statusCode == 200 else {
            throw AnthropicError.apiError(errorMessage(from: data) ?? "Status \(httpResponse.statusCode)")
        }

        return try extractText(from: data)
    }

    /// Joins all `text` blocks of a Messages API response.
    static func extractText(from data: Data) throws -> String {
        let result = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
        let text = (result.content ?? [])
            .filter { $0.type == nil || $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AnthropicError.noContent }
        // Never paste a reply that was cut off by the token limit.
        if result.stop_reason == "max_tokens" { throw AnthropicError.truncated }
        return text
    }

    private static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data))?.error?.message
    }
}
