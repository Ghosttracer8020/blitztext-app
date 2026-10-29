import Accelerate
import Foundation

/// Pure helpers for the pill's audio-reactive bars: band edges, gating,
/// smoothing and the band -> bar mirror mapping. No UI, no AVFoundation.
enum PillBandMath {
    static let bandCount = 5
    static let barCount = 9

    /// Analysis range for the five log-spaced bands.
    static let lowFrequency: Double = 100
    static let highFrequency: Double = 6000

    /// Band energy (dBFS, power summed over the band's bins) that maps to 0 / 1.
    /// Uncalibrated starting values; tune on a real microphone.
    static let floorDB: Float = -70
    static let ceilingDB: Float = -35
    /// Normalized values below this are treated as silence so the bars stay
    /// round dots in a quiet room.
    static let gate: Float = 0.1

    /// Time constants (seconds) of the one-pole smoother.
    static let attackTime: Float = 0.04
    static let releaseTime: Float = 0.15

    /// FFT bin ranges (inclusive lower, exclusive upper) for each band.
    static func bandBinRanges(sampleRate: Double, fftSize: Int) -> [Range<Int>] {
        let ratio = pow(highFrequency / lowFrequency, 1.0 / Double(bandCount))
        let maxBin = fftSize / 2 - 1
        var ranges: [Range<Int>] = []
        var lowerBin = max(1, Int((lowFrequency * Double(fftSize) / sampleRate).rounded()))
        for band in 1...bandCount {
            let edge = lowFrequency * pow(ratio, Double(band))
            var upperBin = Int((edge * Double(fftSize) / sampleRate).rounded())
            upperBin = min(max(upperBin, lowerBin + 1), maxBin)
            let lower = min(lowerBin, upperBin - 1)
            ranges.append(lower..<upperBin)
            lowerBin = upperBin
        }
        return ranges
    }

    /// Maps a band energy in dB to 0...1 with a noise gate.
    static func normalize(decibels: Float) -> Float {
        let value = (decibels - floorDB) / (ceilingDB - floorDB)
        let clamped = min(max(value, 0), 1)
        return clamped < gate ? 0 : clamped
    }

    /// One-pole smoothing with separate attack (rising) and release (falling).
    static func smooth(
        current: Float,
        target: Float,
        deltaTime: Float,
        attack: Float = attackTime,
        release: Float = releaseTime
    ) -> Float {
        let tau = max(target > current ? attack : release, 0.0001)
        let alpha = 1 - exp(-max(deltaTime, 0) / tau)
        return current + (target - current) * alpha
    }

    /// Mirrors five band levels (lowest band first) onto nine bars: the
    /// centre bar shows the highest band, the outermost pair the lowest.
    /// Missing or malformed input yields all zeros (round dots).
    static func barLevels(from bands: [Float]) -> [Float] {
        guard bands.count == bandCount else { return Array(repeating: 0, count: barCount) }
        let centre = barCount / 2
        return (0..<barCount).map { bar in
            let distance = abs(bar - centre)
            return min(max(bands[bandCount - 1 - distance], 0), 1)
        }
    }
}

/// Turns microphone buffers into five smoothed, gated band levels (0...1).
/// Not thread-safe: feed it from a single thread (the audio tap thread).
final class PillBandAnalyzer: @unchecked Sendable {
    private let sampleRate: Double
    private let fftSize = 2048
    private let log2n: vDSP_Length = 11
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let windowSum: Float
    private let binRanges: [Range<Int>]

    private var ring: [Float]
    private var ringIndex = 0
    private var linear: [Float]
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var power: [Float]
    private var smoothed = [Float](repeating: 0, count: PillBandMath.bandCount)
    private var targets = [Float](repeating: 0, count: PillBandMath.bandCount)
    /// Samples ingested since the last FFT; drives the smoother's dt.
    private var pendingSamples = 0
    private var lastPublishTime: CFAbsoluteTime = 0

    init?(sampleRate: Double) {
        guard sampleRate > 0, let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2)) else { return nil }
        self.sampleRate = sampleRate
        fftSetup = setup
        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = hann
        windowSum = hann.reduce(0, +)
        binRanges = PillBandMath.bandBinRanges(sampleRate: sampleRate, fftSize: fftSize)
        ring = [Float](repeating: 0, count: fftSize)
        linear = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        realPart = [Float](repeating: 0, count: fftSize / 2)
        imagPart = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Consumes one buffer of mono samples and returns the smoothed bands.
    /// Samples are always ingested (cheap); the FFT only runs when `analyze`
    /// is true. The smoother's dt covers all samples since the last FFT, so
    /// skipped buffers do not slow the response down.
    func process(samples: UnsafePointer<Float>, count: Int, analyze: Bool = true) -> [Float] {
        guard count > 0 else { return smoothed }
        // Keep the most recent `fftSize` samples in a ring.
        let start = max(0, count - fftSize)
        for i in start..<count {
            ring[ringIndex] = samples[i]
            ringIndex = (ringIndex + 1) % fftSize
        }
        pendingSamples += count
        guard analyze else { return smoothed }

        // Linearize the ring (oldest first) and apply the Hann window.
        for i in 0..<fftSize {
            linear[i] = ring[(ringIndex + i) % fftSize]
        }
        vDSP_vmul(linear, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        computeTargets()
        let deltaTime = Float(Double(pendingSamples) / sampleRate)
        pendingSamples = 0
        for band in 0..<PillBandMath.bandCount {
            smoothed[band] = PillBandMath.smooth(
                current: smoothed[band],
                target: targets[band],
                deltaTime: deltaTime
            )
        }
        return smoothed
    }

    /// True at most ~30 times per second; the caller publishes only then.
    func shouldPublish(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard now - lastPublishTime >= 1.0 / 30.0 else { return false }
        lastPublishTime = now
        return true
    }

    private func computeTargets() {
        realPart.withUnsafeMutableBufferPointer { realBuffer in
            imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )
                windowed.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
            }
        }

        // zrip scales by 2: a full-scale sine reads 0 dB after this division.
        let scale = 1 / (windowSum * windowSum)
        for (band, range) in binRanges.enumerated() {
            var sum: Float = 0
            for bin in range { sum += power[bin] }
            let decibels = 10 * log10(max(sum * scale, 1e-12))
            targets[band] = PillBandMath.normalize(decibels: decibels)
        }
    }
}
