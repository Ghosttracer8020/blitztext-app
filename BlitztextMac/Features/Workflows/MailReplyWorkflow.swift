import Foundation
import AppKit
import Observation
import os

private let mailReplyLogger = Logger(subsystem: "app.blitztext.mac", category: "MailReply")

/// Bullet points -> reply body for the Apple Mail reply window that is
/// frontmost. Reads the original mail at recording start (focus is right
/// then), lets Claude write the reply and hands it to the regular paste path.
/// In a new-mail window (no reply prefix in the title) there is no thread:
/// Claude writes a complete mail from the points and the recipients, fills
/// an empty subject and the text lands in the message body.
/// The points are either dictated (transcribed remotely) or typed into a
/// small input panel (`startTyped`). Never sends anything.
@Observable
@MainActor
final class MailReplyWorkflow: Workflow {
    let type = WorkflowType.mailReply
    var phase: WorkflowPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onOutput: WorkflowOutputHandler?
    var onPhaseChange: WorkflowPhaseChangeHandler?

    private let recorder = AudioRecorder()
    private let settings: MailReplySettings
    private let customTerms: [String]
    private let language: String
    private var mailCapture: MailCapture?
    /// The running mail capture; processing waits for it (the capture reads
    /// Mail on the AppleScript queue and may queue behind a history lookup).
    private var captureTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    /// Compose mode: the lookup of the newest mail from the first recipient,
    /// started at capture and awaited right before the Anthropic request.
    private var historyTask: Task<MailHistory?, Never>?

    /// Mail state remembered for the typed flow while the input panel is open.
    private struct TypedSession {
        let capture: MailCapture
    }
    private var typedSession: TypedSession?

    /// True for a run started with `startTyped` (changes what a retry means).
    private(set) var isTypedRun = false

    /// Asks the UI for the typed points: panel title, the Mail window
    /// (to pick the screen), submit and cancel callbacks.
    var onTypedInputNeeded: ((String, MailReplyWindowRef?, @escaping (String) -> Void, @escaping () -> Void) -> Void)?
    /// Closes the input panel without a callback.
    var onTypedInputDismiss: (() -> Void)?
    /// Review hints for a finished reply (never part of the mail text), with
    /// Mail's reply window to place the hint panel. Called right before
    /// `onOutput`; the host shows them only after a successful paste.
    var onHints: (([MailReplyHint], MailReplyWindowRef?) -> Void)?
    /// The paste target is the empty body of a new mail; called right before
    /// `onOutput` so the host skips its "continues the previous paste" space.
    var onNewMailBody: (() -> Void)?
    /// Puts the reply on the clipboard when it cannot be pasted.
    var onClipboardFallback: ((String) -> Void)?

    init(settings: MailReplySettings, customTerms: [String] = [], language: String = "de") {
        self.settings = settings
        self.customTerms = customTerms
        self.language = language
    }

    // MARK: - Recording State

    var isRecording: Bool { recorder.isRecording }
    var audioLevel: Float { recorder.audioLevel }
    var audioBands: [Float] { recorder.audioBands }

    // MARK: - Workflow Protocol

    /// Cheap checks first (nothing recorded for a doomed run), then the
    /// recorder, then the mail capture: reading the mail can take a moment
    /// and must not clip the start of the dictation. Recorder first, phase
    /// second — see TranscriptionWorkflow.start().
    func start() {
        guard KeychainService.load(key: .openAIAPIKey) != nil else {
            phase = .error(TranscriptionError.notConfigured.localizedDescription)
            return
        }
        guard KeychainService.load(key: .anthropicAPIKey) != nil else {
            phase = .error(AnthropicError.notConfigured.localizedDescription)
            return
        }
        do {
            try MailContextService.ensureMailIsFrontmost()
        } catch {
            phase = .error(error.localizedDescription)
            return
        }

        recorder.startRecording(live: LiveTranscriptionRequest.make(customTerms: customTerms, language: language))

        if let error = recorder.errorMessage {
            phase = .error(error)
            return
        }

        phase = .running("Liest Mail \u{2026}")

        mailCapture = nil
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            do {
                let capture = try await MailContextService.captureWithWindow()
                guard let self, !Task.isCancelled else { return }
                self.mailCapture = capture
                self.startHistoryLookup(for: capture.content)
                if self.recorder.isRecording { self.phase = .running("Aufnahme l\u{00E4}uft ...") }
            } catch {
                guard let self, !Task.isCancelled else { return }
                mailReplyLogger.error("Mail context capture failed: \(error.localizedDescription, privacy: .private)")
                self.recorder.stopRecording()
                self.recorder.discardRecording()
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    /// Typed variant of `start()`: the same checks and mail capture while Mail
    /// is still frontmost, then the input panel instead of the recorder. No
    /// OpenAI key needed - nothing is transcribed.
    func startTyped() {
        isTypedRun = true
        guard KeychainService.load(key: .anthropicAPIKey) != nil else {
            phase = .error(AnthropicError.notConfigured.localizedDescription)
            return
        }
        do {
            try MailContextService.ensureMailIsFrontmost()
        } catch {
            phase = .error(error.localizedDescription)
            return
        }

        mailCapture = nil
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            do {
                let capture = try await MailContextService.captureWithWindow()
                guard let self, !Task.isCancelled else { return }
                self.startHistoryLookup(for: capture.content)
                self.typedSession = TypedSession(capture: capture)
                self.onTypedInputNeeded?(
                    Self.typedPanelTitle(for: capture.content),
                    capture.window,
                    { [weak self] text in self?.submitTyped(text) },
                    { [weak self] in self?.cancelTyped() }
                )
            } catch {
                guard let self, !Task.isCancelled else { return }
                mailReplyLogger.error("Mail context capture failed: \(error.localizedDescription, privacy: .private)")
                self.phase = .error(error.localizedDescription)
            }
        }
    }

    /// Typed points submitted: the panel is closed, Claude writes the reply.
    private func submitTyped(_ text: String) {
        guard let session = typedSession else { return }
        phase = .running("Formuliert \u{2026}")
        processingTask = Task {
            do {
                try await generateAndDeliver(
                    capture: session.capture,
                    points: text,
                    restoringWindow: true
                )
            } catch {
                reportProcessingError(error)
            }
        }
    }

    private func cancelTyped() {
        // Blitztext was activated for the panel; hand focus back to Mail.
        if let pid = typedSession?.capture.pid {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        typedSession = nil
        historyTask?.cancel()
        historyTask = nil
        phase = .idle
        onTypedCancel?()
    }

    /// Called after the user cancelled the input panel (no API call made).
    var onTypedCancel: (() -> Void)?

    func stop() {
        if typedSession != nil, processingTask == nil {
            // Input panel still open: another workflow takes over.
            typedSession = nil
            historyTask = nil
            onTypedInputDismiss?()
            phase = .idle
            return
        }
        if recorder.isRecording {
            recorder.stopRecording()
            guard !TranscriptionQualityService.shouldRejectRecording(duration: recorder.lastRecordingDuration) else {
                recorder.discardRecording()
                phase = .error("Keine Aufnahme erkannt.")
                return
            }
            processRecording()
        } else {
            captureTask?.cancel()
            processingTask?.cancel()
            phase = .idle
        }
    }

    func reset() {
        captureTask?.cancel()
        captureTask = nil
        processingTask?.cancel()
        historyTask = nil
        if typedSession != nil {
            typedSession = nil
            onTypedInputDismiss?()
        }
        if recorder.isRecording {
            recorder.stopRecording()
        }
        recorder.discardRecording()
        phase = .idle
    }

    // MARK: - Two-Phase Processing: Whisper -> Claude

    private func processRecording() {
        guard let url = recorder.recordingURL else {
            phase = .error("Keine Aufnahme vorhanden.")
            return
        }
        phase = .running("Wird transkribiert ...")
        let recordingDuration = recorder.lastRecordingDuration
        let liveSession = recorder.takeLiveSession()
        let vocabularyHints = recordingDuration >= 0.9 ? customTerms : []

        processingTask = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
            }

            // The capture may still be reading Mail; its failure already set
            // the error phase.
            await captureTask?.value
            guard !Task.isCancelled else { return }
            guard let capture = mailCapture else {
                if case .error = phase {} else {
                    phase = .error("Die Mail wurde nicht gelesen. Bitte nochmal versuchen.")
                }
                return
            }

            do {
                let rawText = try await TranscriptionService.transcribe(
                    audioURL: url,
                    customTerms: vocabularyHints,
                    language: language,
                    live: liveSession,
                    recordingDuration: recordingDuration
                )
                let transcript = TranscriptionQualityService.cleanedTranscript(rawText)
                guard !TranscriptionQualityService.isLikelyArtifact(transcript, recordingDuration: recordingDuration) else {
                    phase = .error("Keine Aufnahme erkannt.")
                    return
                }

                if Task.isCancelled { return }

                try await generateAndDeliver(capture: capture, points: transcript, restoringWindow: false)
            } catch {
                reportProcessingError(error)
            }
        }
    }

    // MARK: - Shared: Claude -> paste

    /// Compose mode only: starts the lookup of the newest mail from the first
    /// To recipient, concurrently with dictation or typing. The work runs on
    /// the AppleScript queue, not on the main thread.
    private func startHistoryLookup(for content: MailCaptureContent?) {
        historyTask = nil
        guard case .compose(let context)? = content, let name = context.toRecipients.first else { return }
        historyTask = Task { await MailHistoryService.lookup(displayName: name) }
    }

    private static func typedPanelTitle(for content: MailCaptureContent) -> String {
        switch content {
        case .reply(let context):
            return MailReplyTypedInput.title(sender: context.sender)
        case .compose(let context):
            return MailReplyTypedInput.composeTitle(recipients: context.toRecipients)
        }
    }

    /// Claude writes the reply (or the new mail) from the captured Mail state
    /// and the points (dictated transcript or typed text), then it goes to the
    /// regular paste path. With `restoringWindow` (typed flow) Mail's window
    /// is brought back to the front first, because Blitztext's input panel
    /// was the active app.
    private func generateAndDeliver(
        capture: MailCapture,
        points: String,
        restoringWindow: Bool
    ) async throws {
        phase = .running("Formuliert \u{2026}")

        let reply: String
        var subject = ""
        var hints: [MailReplyHint] = []
        switch capture.content {
        case .reply(let context):
            let result = try await AnthropicService.completeReply(
                systemPrompt: MailReplyPromptBuilder.systemPrompt(
                    customInstruction: settings.systemPrompt,
                    customTerms: customTerms
                ),
                userMessage: MailReplyPromptBuilder.userMessage(context: context, transcript: points)
            )
            reply = result.reply
            hints = result.hints
        case .compose(let context):
            // Bounded by the lookup's own budget; no history on any failure.
            let history = await historyTask?.value
            historyTask = nil
            if Task.isCancelled { return }
            let result = try await AnthropicService.completeCompose(
                systemPrompt: MailReplyPromptBuilder.composeSystemPrompt(
                    customInstruction: settings.systemPrompt,
                    customTerms: customTerms
                ),
                userMessage: MailReplyPromptBuilder.composeUserMessage(context: context, history: history, transcript: points)
            )
            reply = result.reply
            subject = result.subject
        }

        if Task.isCancelled { return }

        if restoringWindow {
            let outcome = await MailWindowFocusService.restore(window: capture.window, pid: capture.pid)
            if Task.isCancelled { return }
            if outcome == .windowGone {
                onClipboardFallback?(reply)
                phase = .error(MailReplyTypedInput.windowGoneMessage)
                return
            }
        }

        if case .compose = capture.content {
            // The paste must land in the message body, never in To/Subject:
            // if the body cannot be focused, the text goes to the clipboard.
            var bodyFocused = false
            if let window = capture.window, MailWindowFocusService.windowIsOpen(window) {
                bodyFocused = await MailComposeService.prepareForPaste(window: window, subject: subject)
            }
            if Task.isCancelled { return }
            guard bodyFocused else {
                onClipboardFallback?(reply)
                phase = .error(MailComposeService.bodyNotFocusedMessage)
                return
            }
            // An empty new body has nothing before the cursor.
            onNewMailBody?()
        }

        phase = .done(reply)
        // Hints first: the host stashes them and shows them only after the
        // paste triggered by `onOutput` succeeded. A new mail has none.
        if !hints.isEmpty {
            onHints?(hints, capture.window)
        }
        onOutput?(reply)
    }

    private func reportProcessingError(_ error: Error) {
        // stop() already reset the phase; a cancelled request must not overwrite it.
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return
        }
        phase = .error(error.localizedDescription)
    }
}
