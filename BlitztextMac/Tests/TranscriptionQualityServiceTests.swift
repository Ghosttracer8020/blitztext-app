import XCTest

final class TranscriptionQualityServiceTests: XCTestCase {
    func testRejectsTooShortRecordings() {
        XCTAssertTrue(TranscriptionQualityService.shouldRejectRecording(duration: 0.1))
        XCTAssertFalse(TranscriptionQualityService.shouldRejectRecording(duration: 0.5))
    }

    func testCleanedTranscriptTrimsOuterWhitespaceOnly() {
        // Inner newlines must survive: dictated emails rely on paragraph breaks
        let input = "\n  Hallo,\n\nzwei Abs\u{00E4}tze.  \n"
        XCTAssertEqual(
            TranscriptionQualityService.cleanedTranscript(input),
            "Hallo,\n\nzwei Abs\u{00E4}tze."
        )
    }

    func testEmptyOrLetterlessTranscriptsAreArtifacts() {
        XCTAssertTrue(TranscriptionQualityService.isLikelyArtifact("   ", recordingDuration: 2))
        XCTAssertTrue(TranscriptionQualityService.isLikelyArtifact("... !!", recordingDuration: 2))
    }

    func testImplausiblyLongTextForShortRecordingIsArtifact() {
        // Whisper hallucination pattern: lots of text from a sub-second clip
        XCTAssertTrue(TranscriptionQualityService.isLikelyArtifact(
            "Untertitel im Auftrag des ZDF f\u{00FC}r funk, 2017",
            recordingDuration: 0.5
        ))
        XCTAssertTrue(TranscriptionQualityService.isLikelyArtifact(
            String(repeating: "viel Text ", count: 8),
            recordingDuration: 0.7
        ))
    }

    func testNormalTranscriptPasses() {
        XCTAssertFalse(TranscriptionQualityService.isLikelyArtifact(
            "Das ist ein ganz normaler Satz.",
            recordingDuration: 3.0
        ))
        XCTAssertFalse(TranscriptionQualityService.isLikelyArtifact(
            "Ja.",
            recordingDuration: 0.6
        ))
    }
}
