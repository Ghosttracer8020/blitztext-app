import Foundation

// Pure building blocks of the live transcription path (OpenAI Realtime API in
// transcription mode) and of the batch request that shares its vocabulary
// handling. No networking and no audio hardware here, so everything is unit
// tested.

// MARK: - Vocabulary

/// Custom terms as the API wants them: `keywords` entries must be single-line
/// and free of `<`, `>`; a violating entry makes the whole request fail.
enum TranscriptionKeywords {
    static let maxCount = 50
    static let maxLength = 64
    /// The prompt only carries the first terms; the full list goes in `keywords`.
    static let maxPromptTerms = 20
    static let maxPromptLength = 300

    static func sanitize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            var cleaned = term
                .replacingOccurrences(of: "<", with: " ")
                .replacingOccurrences(of: ">", with: " ")
                .components(separatedBy: .newlines).joined(separator: " ")
                .replacingOccurrences(of: "\r", with: " ")
            cleaned = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if cleaned.count > maxLength {
                cleaned = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
            }
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
            if result.count == maxCount { break }
        }
        return result
    }

    /// Short context prompt built from already sanitized keywords; nil without terms.
    static func prompt(forKeywords keywords: [String]) -> String? {
        guard !keywords.isEmpty else { return nil }
        var prompt = "Eigennamen und Begriffe: " + keywords.prefix(maxPromptTerms).joined(separator: ", ")
        if prompt.count > maxPromptLength {
            prompt = String(prompt.prefix(maxPromptLength))
        }
        return prompt
    }

    /// App language setting -> API `languages` array. Empty / "auto" means
    /// "let the model detect" and yields no entry.
    static func languages(from setting: String?) -> [String] {
        guard let setting else { return [] }
        let code = setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty, code != "auto" else { return [] }
        return [code]
    }
}

// MARK: - Session request

/// Everything the live session needs from the app besides audio and the key.
struct LiveTranscriptionRequest: Equatable, Sendable {
    var languages: [String]
    var keywords: [String]
    var prompt: String?

    static func make(customTerms: [String], language: String?) -> LiveTranscriptionRequest {
        let keywords = TranscriptionKeywords.sanitize(customTerms)
        return LiveTranscriptionRequest(
            languages: TranscriptionKeywords.languages(from: language),
            keywords: keywords,
            prompt: TranscriptionKeywords.prompt(forKeywords: keywords)
        )
    }
}

// MARK: - Events

enum LiveServerEvent: Equatable {
    case sessionCreated
    case sessionUpdated
    case committed(itemID: String)
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case transcriptionFailed(message: String?)
    case error(message: String, code: String?)
    case other(type: String)
    case unparsable
}

enum LiveEvents {
    static let model = "gpt-live-transcribe"
    static let sampleRate = 24_000
    static let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    /// `includeOptionalFields` adds `noise_reduction` and `delay`; the docs
    /// contradict each other on whether the live model accepts them, so the
    /// session retries without them when the server complains.
    static func sessionUpdate(_ request: LiveTranscriptionRequest, includeOptionalFields: Bool) -> String {
        var transcription: [String: Any] = ["model": model]
        if !request.languages.isEmpty { transcription["languages"] = request.languages }
        if !request.keywords.isEmpty { transcription["keywords"] = request.keywords }
        if let prompt = request.prompt, !prompt.isEmpty { transcription["prompt"] = prompt }
        if includeOptionalFields { transcription["delay"] = "low" }

        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": sampleRate],
            "transcription": transcription,
            "turn_detection": NSNull(),
        ]
        if includeOptionalFields { input["noise_reduction"] = ["type": "near_field"] }

        return json(["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]]])
    }

    static func append(_ pcm: Data) -> String {
        json(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    static let commit = json(["type": "input_audio_buffer.commit"])

    /// True when a pre-ready error may be caused by the optional session
    /// fields. Deliberately broad: a wrong guess costs one extra session.update,
    /// a miss would send every dictation to the batch fallback.
    static func isUnsupportedOptionalFieldError(_ message: String, code: String? = nil) -> Bool {
        if code == "invalid_api_key" { return false }
        let lower = message.lowercased()
        let markers = [
            "delay", "noise_reduction", "noise reduction", "near_field", "session.audio.input",
            "unknown_parameter", "invalid_value",
        ]
        if markers.contains(where: lower.contains) { return true }
        return code == "unknown_parameter" || code == "invalid_value" || code == "invalid_request_error"
    }

    static func parse(_ text: String) -> LiveServerEvent {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return .unparsable }
        switch type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.committed":
            return .committed(itemID: object["item_id"] as? String ?? "")
        case "conversation.item.input_audio_transcription.delta":
            return .delta(itemID: object["item_id"] as? String ?? "", text: object["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .completed(
                itemID: object["item_id"] as? String ?? "",
                transcript: object["transcript"] as? String ?? ""
            )
        case "conversation.item.input_audio_transcription.failed":
            let error = object["error"] as? [String: Any]
            return .transcriptionFailed(message: error?["message"] as? String)
        case "error":
            let error = object["error"] as? [String: Any]
            // `type` (e.g. invalid_request_error) stands in when the server sends no code.
            let code = (error?["code"] as? String) ?? (error?["type"] as? String)
            return .error(message: error?["message"] as? String ?? "", code: code)
        default:
            return .other(type: type)
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

// MARK: - Chunking

/// Collects PCM16 bytes and hands out fixed-size chunks (default 100 ms at
/// 24 kHz mono = 4800 bytes). `flush()` returns the remainder.
struct PCMChunker {
    static let defaultChunkBytes = LiveEvents.sampleRate / 10 * 2

    let chunkBytes: Int
    private var pending = Data()

    init(chunkBytes: Int = PCMChunker.defaultChunkBytes) {
        precondition(chunkBytes > 0 && chunkBytes % 2 == 0, "chunk size must hold whole 16-bit samples")
        self.chunkBytes = chunkBytes
    }

    mutating func push(_ data: Data) -> [Data] {
        pending.append(data)
        var chunks: [Data] = []
        while pending.count >= chunkBytes {
            chunks.append(Data(pending.prefix(chunkBytes)))
            pending = Data(pending.dropFirst(chunkBytes))
        }
        return chunks
    }

    mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

// MARK: - Failure and fallback

enum LiveFailure: Error, Equatable, Sendable {
    case notConfigured
    case unauthorized
    case connect
    case server(code: String?)
    case transcriptionFailed
    case timeout
    case noAudio
    case cancelled

    /// Short label for logs; never contains server text.
    var logLabel: String {
        switch self {
        case .notConfigured: return "not-configured"
        case .unauthorized: return "unauthorized"
        case .connect: return "connect"
        case .server(let code): return "server-error(\(code ?? "none"))"
        case .transcriptionFailed: return "transcription-failed"
        case .timeout: return "timeout"
        case .noAudio: return "no-audio"
        case .cancelled: return "cancelled"
        }
    }
}

enum LiveFallbackDecision: Equatable {
    case useLive(String)
    /// Transcribe the recorded file with the batch endpoint; `reason` is for logs.
    case fallbackToBatch(reason: String)
    case cancelled

    /// Live audio below this share of the recorded duration means the stream
    /// lost audio (late engine start, device switch) although the file is complete.
    static let minimumAudioCoverage = 0.85

    /// `liveAudioSeconds` is the audio the session actually sent; nil skips the coverage check.
    static func decide(
        _ result: Result<String, LiveFailure>,
        recordingDuration: TimeInterval,
        liveAudioSeconds: TimeInterval? = nil
    ) -> LiveFallbackDecision {
        switch result {
        case .success(let text):
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                // Empty live result for a recording that is long enough to hold
                // speech: ask the batch model before giving up.
                if recordingDuration >= TranscriptionQualityService.minimumRecordingDuration {
                    return .fallbackToBatch(reason: "empty-transcript")
                }
                return .useLive("")
            }
            if let live = liveAudioSeconds,
               recordingDuration >= TranscriptionQualityService.minimumRecordingDuration,
               live < recordingDuration * minimumAudioCoverage {
                return .fallbackToBatch(reason: "audio-gap")
            }
            return .useLive(cleaned)
        case .failure(.cancelled):
            return .cancelled
        case .failure(let failure):
            return .fallbackToBatch(reason: failure.logLabel)
        }
    }
}

// MARK: - Timing

enum LiveTimeouts {
    /// PCM16 / 24 kHz / mono.
    static let bytesPerSecond = LiveEvents.sampleRate * 2
    static let resultIdleBase: TimeInterval = 4
    static let resultIdleMax: TimeInterval = 20

    /// With turn detection off the model may only start at the commit, so a
    /// long recording needs a longer silence allowance: 4 s + 0.1 s per second, capped.
    static func resultIdle(forAudioSeconds seconds: TimeInterval) -> TimeInterval {
        min(resultIdleMax, resultIdleBase + 0.1 * max(0, seconds))
    }
}

/// Thread-safe one-way flag: set once on `bandQueue` when a recording ends.
final class EngineStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}
