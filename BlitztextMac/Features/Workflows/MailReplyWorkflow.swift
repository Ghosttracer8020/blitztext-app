import Foundation
import AppKit
import Observation
import os

private let mailReplyLogger = Logger(subsystem: "app.blitztext.mac", category: "MailReply")

/// Dictated bullet points -> reply body for the Apple Mail reply window that
/// is frontmost. Reads the original mail at recording start (focus is right
/// then), transcribes remotely, lets Claude write the reply and hands it to
/// the regular paste path. Never sends anything.
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
    private var mailContext: MailContext?
    private var processingTask: Task<Void, Never>?

    init(settings: MailReplySettings, customTerms: [String] = [], language: String = "de") {
        self.settings = settings
        self.customTerms = customTerms
        self.language = language
    }

    // MARK: - Recording State

    var isRecording: Bool { recorder.isRecording }
    var audioLevel: Float { recorder.audioLevel }

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

        recorder.startRecording()

        if let error = recorder.errorMessage {
            phase = .error(error)
            return
        }

        phase = .running("Liest Mail \u{2026}")

        do {
            mailContext = try MailContextService.capture()
        } catch {
            mailReplyLogger.error("Mail context capture failed: \(error.localizedDescription, privacy: .private)")
            recorder.stopRecording()
            recorder.discardRecording()
            phase = .error(error.localizedDescription)
            return
        }

        phase = .running("Aufnahme l\u{00E4}uft ...")
    }

    func stop() {
        if recorder.isRecording {
            recorder.stopRecording()
            guard !TranscriptionQualityService.shouldRejectRecording(duration: recorder.lastRecordingDuration) else {
                recorder.discardRecording()
                phase = .error("Keine Aufnahme erkannt.")
                return
            }
            processRecording()
        } else {
            processingTask?.cancel()
            phase = .idle
        }
    }

    func reset() {
        processingTask?.cancel()
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
        guard let context = mailContext else {
            try? FileManager.default.removeItem(at: url)
            phase = .error("Die Mail wurde nicht gelesen. Bitte nochmal versuchen.")
            return
        }

        phase = .running("Wird transkribiert ...")
        let recordingDuration = recorder.lastRecordingDuration
        let vocabularyHints = recordingDuration >= 0.9 ? customTerms : []

        processingTask = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
            }

            do {
                let rawText = try await TranscriptionService.transcribe(
                    audioURL: url,
                    customTerms: vocabularyHints,
                    language: language
                )
                let transcript = TranscriptionQualityService.cleanedTranscript(rawText)
                guard !TranscriptionQualityService.isLikelyArtifact(transcript, recordingDuration: recordingDuration) else {
                    phase = .error("Keine Aufnahme erkannt.")
                    return
                }

                if Task.isCancelled { return }

                phase = .running("Formuliert \u{2026}")

                let reply = try await AnthropicService.complete(
                    systemPrompt: MailReplyPromptBuilder.systemPrompt(
                        customInstruction: settings.systemPrompt,
                        customTerms: customTerms
                    ),
                    userMessage: MailReplyPromptBuilder.userMessage(context: context, transcript: transcript)
                )

                if Task.isCancelled { return }

                phase = .done(reply)
                onOutput?(reply)
            } catch {
                // stop() already reset the phase; a cancelled request must not overwrite it.
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                phase = .error(error.localizedDescription)
            }
        }
    }
}
