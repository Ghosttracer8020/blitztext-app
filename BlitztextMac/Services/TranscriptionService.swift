import Foundation
import OSLog

private let transcriptionServiceLogger = Logger(subsystem: "app.blitztext.mac", category: "TranscriptionPath")

enum TranscriptionError: LocalizedError {
    case noFile
    case notConfigured
    case networkError(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noFile:
            return "Keine Audio-Datei gefunden"
        case .notConfigured:
            return "OpenAI API Key fehlt. Bitte in den Einstellungen hinterlegen."
        case .networkError(let msg):
            return "Netzwerkfehler: \(msg)"
        case .apiError(let msg):
            return "OpenAI-Fehler: \(msg)"
        }
    }
}

private struct TranscriptionOpenAIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

enum TranscriptionService {
    /// Batch model (successor of gpt-4o-mini-transcribe, which is shut down 2027-02-26).
    static let remoteModel = "gpt-transcribe"
    private static let transcriptionsURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// Live-first transcription for remote runs: if `live` is given, its
    /// streamed transcript wins; on any live failure (or an empty transcript
    /// for a recording that should hold speech) the recorded file goes to the
    /// batch endpoint. Without `live` it is the plain batch request.
    static func transcribe(
        audioURL: URL,
        customTerms: [String] = [],
        language: String? = nil,
        live: LiveTranscriptionSession?,
        recordingDuration: TimeInterval
    ) async throws -> String {
        if let live {
            let started = Date()
            let outcome = await live.result()
            switch LiveFallbackDecision.decide(
                outcome,
                recordingDuration: recordingDuration,
                liveAudioSeconds: live.sentAudioSeconds
            ) {
            case .useLive(let text):
                transcriptionServiceLogger.info(
                    "Transcription path=live, \(Int(Date().timeIntervalSince(started) * 1000)) ms waited after key release"
                )
                return text
            case .cancelled:
                throw CancellationError()
            case .fallbackToBatch(let reason):
                transcriptionServiceLogger.info("Transcription path=batch-fallback reason=\(reason, privacy: .public)")
            }
        } else {
            transcriptionServiceLogger.info("Transcription path=batch")
        }
        try Task.checkCancellation()
        return try await transcribe(audioURL: audioURL, customTerms: customTerms, language: language)
    }

    static func transcribe(
        audioURL: URL,
        customTerms: [String] = [],
        language: String? = nil
    ) async throws -> String {
        guard let apiKey = KeychainService.load(key: .openAIAPIKey) else {
            throw TranscriptionError.notConfigured
        }

        return try await Task.detached(priority: .userInitiated) {
            defer {
                try? FileManager.default.removeItem(at: audioURL)
            }

            let boundary = UUID().uuidString
            var request = URLRequest(url: transcriptionsURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let audioData = try Data(contentsOf: audioURL, options: [.mappedIfSafe])

            var body = Data()
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
            body.append("Content-Type: audio/m4a\r\n\r\n")
            body.append(audioData)
            body.append("\r\n")

            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
            body.append(remoteModel)
            body.append("\r\n")

            // No response_format: gpt-transcribe documents none, the answer is {"text": ...}.
            let keywords = TranscriptionKeywords.sanitize(customTerms)
            if let prompt = TranscriptionKeywords.prompt(forKeywords: keywords) {
                body.append("--\(boundary)\r\n")
                body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
                body.append(prompt)
                body.append("\r\n")
            }
            for keyword in keywords {
                body.append("--\(boundary)\r\n")
                body.append("Content-Disposition: form-data; name=\"\(arrayFieldName("keywords"))\"\r\n\r\n")
                body.append(keyword)
                body.append("\r\n")
            }

            // `languages` replaces `language`; never send both.
            for code in TranscriptionKeywords.languages(from: language) {
                body.append("--\(boundary)\r\n")
                body.append("Content-Disposition: form-data; name=\"\(arrayFieldName("languages"))\"\r\n\r\n")
                body.append(code)
                body.append("\r\n")
            }

            body.append("--\(boundary)--\r\n")
            request.httpBody = body

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptionError.networkError("Ungueltige Antwort")
            }

            guard httpResponse.statusCode == 200 else {
                throw TranscriptionError.apiError(openAIErrorMessage(from: data) ?? "Status \(httpResponse.statusCode)")
            }

            guard let text = parseTranscript(from: data), !text.isEmpty else {
                throw TranscriptionError.apiError("Transkription fehlgeschlagen")
            }

            return text
        }.value
    }

    /// Multipart field name for an array parameter (repeated field).
    static func arrayFieldName(_ name: String) -> String { name + "[]" }

    /// Extracts `text` from the JSON answer; nil if the body is not the expected shape.
    static func parseTranscript(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["text"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openAIErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(TranscriptionOpenAIErrorResponse.self, from: data))?.error?.message
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
