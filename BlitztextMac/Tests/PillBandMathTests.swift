import XCTest

final class PillBandMathTests: XCTestCase {
    func testBarMappingPutsHighestBandInCentreAndLowestOnOutsidePair() {
        let bars = PillBandMath.barLevels(from: [0.1, 0.2, 0.3, 0.4, 0.5])
        XCTAssertEqual(bars, [0.1, 0.2, 0.3, 0.4, 0.5, 0.4, 0.3, 0.2, 0.1])
    }

    func testBarMappingWithWrongBandCountYieldsDots() {
        XCTAssertEqual(PillBandMath.barLevels(from: []), Array(repeating: 0, count: 9))
        XCTAssertEqual(PillBandMath.barLevels(from: [1, 1, 1]), Array(repeating: 0, count: 9))
    }

    func testBarMappingClampsOutOfRangeValues() {
        let bars = PillBandMath.barLevels(from: [-1, 2, 0, 0, 0])
        XCTAssertEqual(bars[0], 0)
        XCTAssertEqual(bars[1], 1)
        XCTAssertEqual(bars[7], 1)
    }

    func testRestBarIsARoundDot() {
        XCTAssertEqual(PillBarGeometry.height(forLevel: 0), PillBarGeometry.barWidth)
        XCTAssertEqual(PillBarGeometry.height(forLevel: 1), PillBarGeometry.maxHeight)
        XCTAssertEqual(PillBarGeometry.height(forLevel: 7), PillBarGeometry.maxHeight)
    }

    func testGateKeepsSilenceAtZero() {
        XCTAssertEqual(PillBandMath.normalize(decibels: -120), 0)
        XCTAssertEqual(PillBandMath.normalize(decibels: PillBandMath.floorDB + 1), 0)
        XCTAssertEqual(PillBandMath.normalize(decibels: PillBandMath.ceilingDB + 10), 1)
        XCTAssertGreaterThan(PillBandMath.normalize(decibels: -50), 0.1)
    }

    func testSmoothingAttackIsFasterThanRelease() {
        let rise = PillBandMath.smooth(current: 0, target: 1, deltaTime: 0.04)
        let fall = PillBandMath.smooth(current: 1, target: 0, deltaTime: 0.04)
        XCTAssertEqual(rise, 1 - exp(-1), accuracy: 0.001)
        XCTAssertGreaterThan(rise, 1 - fall)
    }

    func testSmoothingConvergesAndNeverOvershoots() {
        var value: Float = 0
        for _ in 0..<200 {
            value = PillBandMath.smooth(current: value, target: 0.6, deltaTime: 0.02)
            XCTAssertLessThanOrEqual(value, 0.6 + 1e-6)
        }
        XCTAssertEqual(value, 0.6, accuracy: 0.001)
    }

    func testBandRangesAreContiguousAndNonEmpty() {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let ranges = PillBandMath.bandBinRanges(sampleRate: rate, fftSize: 2048)
            XCTAssertEqual(ranges.count, 5)
            for range in ranges { XCTAssertFalse(range.isEmpty) }
            for pair in zip(ranges, ranges.dropFirst()) {
                XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound)
            }
        }
    }

    private func feed(_ analyzer: PillBandAnalyzer, frequency: Double, amplitude: Float, rate: Double, buffers: Int) -> [Float] {
        var phase = 0.0
        var result: [Float] = []
        for _ in 0..<buffers {
            let samples: [Float] = (0..<1024).map { _ in
                defer { phase += 2 * .pi * frequency / rate }
                return amplitude * Float(sin(phase))
            }
            result = samples.withUnsafeBufferPointer { analyzer.process(samples: $0.baseAddress!, count: $0.count) }
        }
        return result
    }

    func testAnalyzerSilenceStaysAtZero() throws {
        let analyzer = try XCTUnwrap(PillBandAnalyzer(sampleRate: 48_000))
        let zeros = [Float](repeating: 0, count: 1024)
        var bands: [Float] = []
        for _ in 0..<20 {
            bands = zeros.withUnsafeBufferPointer { analyzer.process(samples: $0.baseAddress!, count: $0.count) }
        }
        XCTAssertEqual(bands, [0, 0, 0, 0, 0])
    }

    func testAnalyzerSineLightsTheMatchingBand() throws {
        let analyzer = try XCTUnwrap(PillBandAnalyzer(sampleRate: 48_000))
        // 1 kHz falls in band 2 (about 520 Hz - 1.19 kHz).
        let bands = feed(analyzer, frequency: 1000, amplitude: 0.5, rate: 48_000, buffers: 30)
        XCTAssertGreaterThan(bands[2], 0.5)
        for index in [0, 1, 3, 4] { XCTAssertLessThan(bands[index], bands[2]) }
        // Residual is smoothing tail from the first, partially filled windows.
        XCTAssertEqual(bands[0], 0, accuracy: 0.02)
        XCTAssertEqual(bands[4], 0, accuracy: 0.02)
    }

    func testAnalyzerReleasesAfterSignalStops() throws {
        let analyzer = try XCTUnwrap(PillBandAnalyzer(sampleRate: 48_000))
        _ = feed(analyzer, frequency: 300, amplitude: 0.5, rate: 48_000, buffers: 30)
        let zeros = [Float](repeating: 0, count: 1024)
        var bands: [Float] = []
        for _ in 0..<40 {
            bands = zeros.withUnsafeBufferPointer { analyzer.process(samples: $0.baseAddress!, count: $0.count) }
        }
        XCTAssertEqual(bands[1], 0, accuracy: 0.02)
    }

    func testPublishIsThrottledToThirtyHertz() throws {
        let analyzer = try XCTUnwrap(PillBandAnalyzer(sampleRate: 48_000))
        XCTAssertTrue(analyzer.shouldPublish(now: 100))
        XCTAssertFalse(analyzer.shouldPublish(now: 100.01))
        XCTAssertTrue(analyzer.shouldPublish(now: 100.04))
    }
}
