import AVFoundation

/// Converts microphone buffers (any rate / channel count, usually Float32) to
/// the live API's wire format: PCM16 little-endian, mono, 24 kHz.
///
/// Holds resampler state, so one instance belongs to one input format and must
/// be driven from a single thread (the audio tap callback does that).
final class PCM16Converter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(LiveEvents.sampleRate),
                  channels: 1,
                  interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
        self.ratio = outputFormat.sampleRate / inputFormat.sampleRate
    }

    /// Returns the converted bytes; empty when nothing could be produced.
    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        guard buffer.frameLength > 0 else { return Data() }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return Data() }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil,
              output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { return Data() }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
