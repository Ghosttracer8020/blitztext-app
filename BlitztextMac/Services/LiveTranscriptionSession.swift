import Foundation
import OSLog

private let liveLogger = Logger(subsystem: "app.blitztext.mac", category: "LiveTranscription")

/// One live transcription session = one WebSocket to the OpenAI Realtime API
/// in transcription mode, opened when recording starts.
///
/// Audio (PCM16 / 24 kHz / mono, from the recorder's tap) goes in through
/// `append`; audio captured before the socket is configured is buffered and
/// flushed in order. `endOfAudio` commits the buffer, `result()` waits for the
/// final transcript. Any failure surfaces as `.failure` so the caller can fall
/// back to the recorded file. Logs carry timings and failure labels only,
/// never audio, text or the key.
final class LiveTranscriptionSession: @unchecked Sendable {
    /// Give up when the socket is not configured this long after `start()`.
    static let connectTimeout: TimeInterval = 6
    /// After key release with the socket still not ready: wait at most this much longer.
    static let connectGraceAfterRelease: TimeInterval = 2
    /// After the commit: give up when no server event arrives for this long
    /// (grows with the recording length, see `LiveTimeouts`).
    static let bytesPerSecond = LiveTimeouts.bytesPerSecond


    private let request: LiveTranscriptionRequest
    private let queue = DispatchQueue(label: "blitztext.live-transcription", qos: .userInitiated)
    private let urlSession: URLSession

    // All state below is confined to `queue`.
    private var task: URLSessionWebSocketTask?
    private var chunker = PCMChunker()
    private var buffered: [Data] = []
    private var sentBytes = 0
    private var ready = false
    private var sentOptionalFields = true
    private var wantsCommit = false
    private var commitSentAt: Date?
    private var startedAt = Date()
    private var committedItems: [String] = []
    private var completedItems: [String: String] = [:]
    private var completionOrder: [String] = []
    private var finished: Result<String, LiveFailure>?
    private var waiter: CheckedContinuation<Result<String, LiveFailure>, Never>?
    private var connectTimer: DispatchWorkItem?
    private var connectDeadline: Date?
    private var idleTimer: DispatchWorkItem?

    init(request: LiveTranscriptionRequest) {
        self.request = request
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Public API (thread-safe)

    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Feeds converted PCM16 bytes. Safe from any thread; cheap.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async { self.appendOnQueue(pcm) }
    }

    /// No more audio: flush the remainder and commit (as soon as the socket is ready).
    func endOfAudio() {
        queue.async { self.endOfAudioOnQueue() }
    }

    /// Closes without commit (Esc / discarded recording).
    func cancel() {
        queue.async { self.finish(.failure(.cancelled)) }
    }

    /// Waits for the final transcript (or a failure). Cancelling the awaiting
    /// task cancels the session.
    /// Seconds of audio handed to the socket so far. Read after `result()`
    /// to compare against the recording length.
    var sentAudioSeconds: TimeInterval {
        queue.sync { Double(sentBytes) / Double(Self.bytesPerSecond) }
    }

    func result() async -> Result<String, LiveFailure> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    if let finished = self.finished {
                        continuation.resume(returning: finished)
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    // MARK: - Lifecycle

    private func startOnQueue() {
        guard finished == nil, task == nil else { return }
        startedAt = Date()
        guard let apiKey = KeychainService.load(key: .openAIAPIKey) else {
            finish(.failure(.notConfigured))
            return
        }

        var urlRequest = URLRequest(url: LiveEvents.url)
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: urlRequest)
        self.task = task
        task.resume()
        receiveNext(on: task)
        // Queued by the task until the handshake completes.
        send(LiveEvents.sessionUpdate(request, includeOptionalFields: true))

        armConnectTimer(after: Self.connectTimeout)
    }

    private func armConnectTimer(after delay: TimeInterval) {
        connectTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.ready else { return }
            self.finish(.failure(.connect))
        }
        connectTimer = timer
        connectDeadline = Date().addingTimeInterval(delay)
        queue.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    private func appendOnQueue(_ pcm: Data) {
        guard finished == nil, !wantsCommit else { return }
        for chunk in chunker.push(pcm) { enqueue(chunk) }
    }

    private func endOfAudioOnQueue() {
        guard finished == nil, !wantsCommit else { return }
        if let rest = chunker.flush() { enqueue(rest) }
        wantsCommit = true
        guard sentBytes + buffered.reduce(0, { $0 + $1.count }) > 0 else {
            finish(.failure(.noAudio))
            return
        }
        if ready {
            sendCommit()
        } else if let deadline = connectDeadline {
            // Key already released: do not keep the user waiting for the full connect timeout.
            let remaining = deadline.timeIntervalSinceNow
            armConnectTimer(after: max(0.1, min(remaining, Self.connectGraceAfterRelease)))
        }
        // Otherwise the commit follows right after the buffered audio flush.
    }

    private func enqueue(_ chunk: Data) {
        if ready {
            sentBytes += chunk.count
            send(LiveEvents.append(chunk))
        } else {
            buffered.append(chunk)
        }
    }

    private func becomeReady() {
        guard !ready else { return }
        ready = true
        connectTimer?.cancel()
        connectTimer = nil
        let backlog = buffered
        buffered = []
        for chunk in backlog {
            sentBytes += chunk.count
            send(LiveEvents.append(chunk))
        }
        liveLogger.info("Live session ready after \(self.millisecondsSinceStart()) ms, \(backlog.count) buffered chunks flushed")
        if wantsCommit { sendCommit() }
    }

    private func sendCommit() {
        guard commitSentAt == nil, finished == nil else { return }
        commitSentAt = Date()
        send(LiveEvents.commit)
        armIdleTimer()
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timeout))
        }
        idleTimer = timer
        let seconds = Double(sentBytes) / Double(Self.bytesPerSecond)
        queue.asyncAfter(deadline: .now() + LiveTimeouts.resultIdle(forAudioSeconds: seconds), execute: timer)
    }

    // MARK: - Socket

    private func send(_ text: String) {
        guard let task, finished == nil else { return }
        task.send(.string(text)) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async { self.finish(.failure(self.failureForSocketError())) }
        }
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.finished == nil, self.task === task else { return }
                switch result {
                case .failure:
                    self.finish(.failure(self.failureForSocketError()))
                case .success(let message):
                    if case .string(let text) = message { self.handle(LiveEvents.parse(text)) }
                    self.receiveNext(on: task)
                }
            }
        }
    }

    private func failureForSocketError() -> LiveFailure {
        let status = (task?.response as? HTTPURLResponse)?.statusCode
        return (status == 401 || status == 403) ? .unauthorized : .connect
    }

    // MARK: - Events

    private func handle(_ event: LiveServerEvent) {
        switch event {
        case .sessionUpdated:
            becomeReady()
        case .committed(let itemID):
            if !itemID.isEmpty, !committedItems.contains(itemID) { committedItems.append(itemID) }
            if commitSentAt != nil { armIdleTimer() }
        case .delta:
            if commitSentAt != nil { armIdleTimer() }
        case .completed(let itemID, let transcript):
            if completedItems[itemID] == nil { completionOrder.append(itemID) }
            completedItems[itemID] = transcript
            completeIfDone()
        case .transcriptionFailed:
            finish(.failure(.transcriptionFailed))
        case .error(let message, let code):
            if !ready, sentOptionalFields, LiveEvents.isUnsupportedOptionalFieldError(message, code: code) {
                // The server rejected delay / noise_reduction: configure once more without them.
                sentOptionalFields = false
                liveLogger.info("session.update rejected optional fields, retrying without them")
                send(LiveEvents.sessionUpdate(request, includeOptionalFields: false))
            } else if code == "invalid_api_key" {
                finish(.failure(.unauthorized))
            } else {
                finish(.failure(.server(code: code)))
            }
        case .sessionCreated, .other, .unparsable:
            break
        }
    }

    private func completeIfDone() {
        guard commitSentAt != nil, !completedItems.isEmpty else { return }
        guard committedItems.allSatisfy({ completedItems[$0] != nil }) else { return }
        // Commit order wins; items we never saw a `committed` event for follow in arrival order.
        let ordered = committedItems + completionOrder.filter { !committedItems.contains($0) }
        let text = ordered
            .compactMap { completedItems[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if let sent = commitSentAt {
            liveLogger.info("Live transcript completed \(Int(Date().timeIntervalSince(sent) * 1000)) ms after commit")
        }
        finish(.success(text))
    }

    private func finish(_ outcome: Result<String, LiveFailure>) {
        guard finished == nil else { return }
        finished = outcome
        connectTimer?.cancel()
        idleTimer?.cancel()
        buffered = []
        // Close after commit as well as on failure/cancel: one socket per press.
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()
        if case .failure(let failure) = outcome {
            liveLogger.info("Live session ended without transcript: \(failure.logLabel, privacy: .public)")
        }
        waiter?.resume(returning: outcome)
        waiter = nil
    }

    private func millisecondsSinceStart() -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1000)
    }
}
