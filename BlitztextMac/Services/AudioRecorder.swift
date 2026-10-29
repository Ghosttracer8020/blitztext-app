import AVFoundation
import Observation

@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    var isRecording = false
    var recordingURL: URL?
    var errorMessage: String?
    var audioLevel: Float = 0
    /// Five smoothed band levels (0...1, lowest band first); empty when no
    /// analysis is running. Drives the pill bars.
    var audioBands: [Float] = []
    var lastRecordingDuration: TimeInterval = 0

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    /// Analysis-only engine: its tap feeds the band analyzer. The file that
    /// goes to transcription is still written by `audioRecorder`, unchanged.
    private var bandEngine: AVAudioEngine?
    private var currentFileURL: URL?
    /// Live transcription session fed by the same tap; nil for local-only runs.
    /// The workflow takes it with `takeLiveSession()` after `stopRecording()`.
    private(set) var liveSession: LiveTranscriptionSession?
    private var configObserver: NSObjectProtocol?
    /// Per recording; set on `bandQueue` when the engine is torn down so a
    /// config-change restart already queued behind the stop cannot revive it.
    private var stopFlag: EngineStopFlag?
    private static let bandQueue = DispatchQueue(label: "blitztext.band-analysis", qos: .userInitiated)

    private func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blitztext-\(UUID().uuidString).m4a")
    }

    /// `live` opens a streaming transcription session for this recording. The
    /// file is written either way: it is the fallback if the live path fails.
    func startRecording(live: LiveTranscriptionRequest? = nil) {
        liveSession?.cancel()
        liveSession = nil
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
            if let live {
                let session = LiveTranscriptionSession(request: live)
                session.start()
                liveSession = session
            }
            startMetering()
            startBandAnalysis()
        } catch {
            currentFileURL = nil
            errorMessage = "Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        stopMetering()
        stopBandAnalysis(finishing: liveSession)
        lastRecordingDuration = audioRecorder?.currentTime ?? 0
        audioRecorder?.stop()
        isRecording = false
        recordingURL = currentFileURL
        currentFileURL = nil
        audioRecorder = nil
        audioLevel = 0
    }

    /// Hands the live session to the caller (once). The caller owns awaiting
    /// its result; `discardRecording` no longer cancels it afterwards.
    func takeLiveSession() -> LiveTranscriptionSession? {
        defer { liveSession = nil }
        return liveSession
    }

    func discardRecording() {
        liveSession?.cancel()
        liveSession = nil
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

    /// Starts an input tap purely for spectral analysis. The engine is started
    /// off the main thread (start can block for tens of ms) and restarted on
    /// configuration changes (device switch, Bluetooth). Failure is
    /// non-fatal: the bars then stay dots while recording itself is unaffected.
    private func startBandAnalysis() {
        stopBandAnalysis()
        let engine = AVAudioEngine()
        bandEngine = engine
        let publish: @Sendable ([Float]) -> Void = { [weak self, weak engine] bands in
            DispatchQueue.main.async {
                // Compare identity so a stale block from an old engine cannot
                // write into a newer recording.
                guard let self, let engine, self.bandEngine === engine else { return }
                self.audioBands = bands
            }
        }
        let queue = Self.bandQueue
        let stopped = EngineStopFlag()
        stopFlag = stopped
        let liveAudio: (@Sendable (Data) -> Void)? = liveSession.map { session in
            { data in session.append(data) }
        }
        queue.async { Self.configureAndStart(engine, stopped: stopped, publish: publish, liveAudio: liveAudio) }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak engine] _ in
            guard let engine else { return }
            queue.async { Self.configureAndStart(engine, stopped: stopped, publish: publish, liveAudio: liveAudio) }
        }
    }

    /// `finishing` is told that no more audio follows - on the same queue as
    /// the tap removal, so the commit comes after the last appended buffer.
    private func stopBandAnalysis(finishing live: LiveTranscriptionSession? = nil) {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        let engine = bandEngine
        let stopped = stopFlag
        stopFlag = nil
        if engine != nil || live != nil {
            // Serialized behind a possibly pending start on the same queue.
            Self.bandQueue.async {
                stopped?.set()
                engine?.inputNode.removeTap(onBus: 0)
                engine?.stop()
                live?.endOfAudio()
            }
        }
        bandEngine = nil
        audioBands = []
    }

    /// (Re)installs the tap for the engine's current input format and starts it.
    /// Runs on `bandQueue`.
    private static func configureAndStart(
        _ engine: AVAudioEngine,
        stopped: EngineStopFlag,
        publish: @escaping @Sendable ([Float]) -> Void,
        liveAudio: (@Sendable (Data) -> Void)?
    ) {
        guard !stopped.isSet else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0,
              let analyzer = PillBandAnalyzer(sampleRate: format.sampleRate) else { return }

        // One converter per input format (a device switch re-enters here with a
        // new format); it is only touched from the tap callback.
        let pcmConverter = liveAudio == nil ? nil : PCM16Converter(inputFormat: format)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Runs on the audio thread, never on main. The FFT only runs when
            // a publish is due (~30 Hz).
            if let liveAudio, let pcmConverter {
                let pcm = pcmConverter.convert(buffer)
                if !pcm.isEmpty { liveAudio(pcm) }
            }
            guard let channel = buffer.floatChannelData?[0] else { return }
            let due = analyzer.shouldPublish()
            let bands = analyzer.process(samples: channel, count: Int(buffer.frameLength), analyze: due)
            if due { publish(bands) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
        }
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
