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

/// One review hint next to a generated reply. Never part of the mail text.
struct MailReplyHint: Equatable {
    enum Kind: String, CaseIterable {
        case widerspruch
        case schonBeantwortet = "schon_beantwortet"
        case offen
    }

    let kind: Kind
    let text: String
}

/// Reply text plus the review hints returned alongside it.
struct MailReplyResult: Equatable {
    let reply: String
    let hints: [MailReplyHint]
}

/// Text of a new mail plus the subject Claude suggests for it. The subject is
/// empty when the model returned none.
struct MailComposeResult: Equatable {
    let subject: String
    let reply: String
}

/// Minimal JSON tree so the structured-output schema can be generated
/// (e.g. the hint kind enum from `MailReplyHint.Kind.allCases`).
indirect enum JSONSchemaNode: Encodable {
    case string
    case stringEnum([String])
    case array(JSONSchemaNode)
    /// Every property is required and `additionalProperties` is false, as the
    /// Structured Outputs API demands for all objects.
    case object([(String, JSONSchemaNode)])

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .string:
            try c.encode("string", forKey: Key("type"))
        case .stringEnum(let values):
            try c.encode("string", forKey: Key("type"))
            try c.encode(values, forKey: Key("enum"))
        case .array(let items):
            try c.encode("array", forKey: Key("type"))
            try c.encode(items, forKey: Key("items"))
        case .object(let properties):
            try c.encode("object", forKey: Key("type"))
            var props = c.nestedContainer(keyedBy: Key.self, forKey: Key("properties"))
            for (name, node) in properties { try props.encode(node, forKey: Key(name)) }
            try c.encode(properties.map(\.0), forKey: Key("required"))
            try c.encode(false, forKey: Key("additionalProperties"))
        }
    }
}

struct AnthropicMessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct OutputConfig: Encodable {
        struct Format: Encodable {
            let type = "json_schema"
            let schema: JSONSchemaNode
        }
        let format: Format
    }

    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Message]
    var output_config: OutputConfig? = nil
}

struct AnthropicMessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }

    /// Tolerant decoding of the structured JSON reply: a malformed hint must not
    /// cost the reply.
    struct ReplyInput: Decodable {
        let reply: String?
        let hints: [RawHint]?

        struct RawHint: Decodable {
            let kind: String?
            let text: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                kind = try? c.decode(String.self, forKey: .kind)
                text = try? c.decode(String.self, forKey: .text)
            }

            private enum Keys: String, CodingKey { case kind, text }
        }

        /// Decodes one array element; a malformed element becomes nil
        /// instead of failing the whole array.
        private struct Lossy: Decodable {
            let value: RawHint?
            init(from decoder: Decoder) throws {
                value = try? RawHint(from: decoder)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            reply = try? c.decode(String.self, forKey: .reply)
            hints = (try? c.decode([Lossy].self, forKey: .hints))?.compactMap(\.value)
        }

        private enum Keys: String, CodingKey { case reply, hints }
    }

    /// Tolerant decoding of the compose JSON: a missing subject is no error.
    struct ComposeInput: Decodable {
        let subject: String?
        let reply: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            subject = try? c.decode(String.self, forKey: .subject)
            reply = try? c.decode(String.self, forKey: .reply)
        }

        private enum Keys: String, CodingKey { case subject, reply }
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
    static let maxTokens = 3000
    static let maxHints = 5
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

    static func completeReply(systemPrompt: String, userMessage: String) async throws -> MailReplyResult {
        let data = try await send(systemPrompt: systemPrompt, userMessage: userMessage, schema: replySchema)
        return try parseReply(from: data)
    }

    /// New-mail variant: `subject` + `reply`, no review hints.
    static func completeCompose(systemPrompt: String, userMessage: String) async throws -> MailComposeResult {
        let data = try await send(systemPrompt: systemPrompt, userMessage: userMessage, schema: composeSchema)
        return try parseCompose(from: data)
    }

    private static func send(systemPrompt: String, userMessage: String, schema: JSONSchemaNode) async throws -> Data {
        guard let apiKey = KeychainService.load(key: .anthropicAPIKey) else {
            throw AnthropicError.notConfigured
        }

        let payload = AnthropicMessagesRequest(
            model: model,
            max_tokens: maxTokens,
            system: systemPrompt,
            messages: [.init(role: "user", content: userMessage)],
            output_config: .init(format: .init(schema: schema))
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

        return data
    }

    /// JSON schema of the structured reply. The hint kind enum is generated
    /// from `MailReplyHint.Kind`.
    static var replySchema: JSONSchemaNode {
        .object([
            ("reply", .string),
            ("hints", .array(.object([
                ("kind", .stringEnum(MailReplyHint.Kind.allCases.map(\.rawValue))),
                ("text", .string),
            ]))),
        ])
    }

    /// JSON schema of the compose output.
    static var composeSchema: JSONSchemaNode {
        .object([
            ("subject", .string),
            ("reply", .string),
        ])
    }

    /// Reads `subject` + `reply`. Text that is not such a JSON object is taken
    /// as the mail text without subject; a missing subject becomes "".
    static func parseCompose(from data: Data) throws -> MailComposeResult {
        let text = try extractText(from: data)
        guard let input = try? JSONDecoder().decode(AnthropicMessagesResponse.ComposeInput.self, from: Data(text.utf8)) else {
            return MailComposeResult(subject: "", reply: text)
        }
        let reply = (input.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw AnthropicError.noContent }
        // A subject is one line.
        let subject = (input.subject ?? "")
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MailComposeResult(subject: subject, reply: reply)
    }

    /// Reads the structured JSON object from the joined text blocks. If the
    /// text is not such a JSON object, the whole text is the reply (no hints).
    /// Unknown hint kinds and empty hint texts are dropped; at most `maxHints`
    /// are kept.
    static func parseReply(from data: Data) throws -> MailReplyResult {
        let text = try extractText(from: data)
        guard let input = try? JSONDecoder().decode(AnthropicMessagesResponse.ReplyInput.self, from: Data(text.utf8)) else {
            return MailReplyResult(reply: text, hints: [])
        }
        let reply = (input.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw AnthropicError.noContent }
        let hints = (input.hints ?? []).compactMap { raw -> MailReplyHint? in
            guard let kindRaw = raw.kind, let kind = MailReplyHint.Kind(rawValue: kindRaw.trimmingCharacters(in: .whitespaces).lowercased()),
                  let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return MailReplyHint(kind: kind, text: text)
        }
        return MailReplyResult(reply: reply, hints: Array(hints.prefix(maxHints)))
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
