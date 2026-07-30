import AVFoundation
import Observation

@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    var isRecording = false
    var recordingURL: URL?
    var errorMessage: String?
    var audioLevel: Float = 0
    var lastRecordingDuration: TimeInterval = 0

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var currentFileURL: URL?

    private func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blitztext-\(UUID().uuidString).m4a")
    }

    func startRecording() {
        errorMessage = nil
        lastRecordingDuration = 0
        recordingURL = nil
        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let fileURL = makeRecordingURL()
            currentFileURL = fileURL
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            // record() can fail without throwing (input device busy, e.g. when
            // the previous recording was torn down microseconds earlier).
            // Silently ignoring it produced a zero-length recording that only
            // surfaced later as "Keine Aufnahme erkannt.".
            guard recorder.record() else {
                currentFileURL = nil
                try? FileManager.default.removeItem(at: fileURL)
                errorMessage = "Mikrofon ist gerade nicht verfügbar."
                return
            }
            audioRecorder = recorder
            isRecording = true
            startMetering()
        } catch {
            currentFileURL = nil
            errorMessage = "Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        stopMetering()
        lastRecordingDuration = audioRecorder?.currentTime ?? 0
        audioRecorder?.stop()
        isRecording = false
        recordingURL = currentFileURL
        currentFileURL = nil
        audioRecorder = nil
        audioLevel = 0
    }

    func discardRecording() {
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }

        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
            self.currentFileURL = nil
        }
    }

    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.audioRecorder?.updateMeters()
            let power = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
            let normalized = max(0, min(1, (power + 50) / 50))
            self.audioLevel = normalized
        }
    }

    private func stopMetering() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            Task { @MainActor in
                self.errorMessage = "Aufnahme fehlgeschlagen"
            }
        }
    }
}
