import XCTest

/// Pure parts only; reading Mail itself (AppleScript, Accessibility) needs a
/// running Mail and is exercised manually.
final class MailContextServiceTests: XCTestCase {
    // MARK: - normalizeSubject

    func testStripsReplyAndForwardPrefixesCaseInsensitively() {
        for prefix in ["Re:", "RE:", "re:", "AW:", "Aw:", "Fwd:", "FWD:", "Fw:", "WG:", "Wg:"] {
            XCTAssertEqual(MailContextService.normalizeSubject("\(prefix) Angebot"), "Angebot", prefix)
        }
    }

    func testStripsRepeatedPrefixes() {
        XCTAssertEqual(MailContextService.normalizeSubject("Re: AW: Re: WG: Angebot"), "Angebot")
        XCTAssertEqual(MailContextService.normalizeSubject("RE:RE:Angebot"), "Angebot")
    }

    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(MailContextService.normalizeSubject("  Re:   Angebot \n  Kurs\t2026  "), "Angebot Kurs 2026")
    }

    func testKeepsPrefixLikeWordsInsideTheSubject() {
        XCTAssertEqual(MailContextService.normalizeSubject("Reservierung Halle"), "Reservierung Halle")
        XCTAssertEqual(MailContextService.normalizeSubject("Termin Re: Planung"), "Termin Re: Planung")
        XCTAssertEqual(MailContextService.normalizeSubject("Fwdkurs"), "Fwdkurs")
    }

    func testEmptyAndPrefixOnlySubjects() {
        XCTAssertEqual(MailContextService.normalizeSubject(""), "")
        XCTAssertEqual(MailContextService.normalizeSubject("Re:"), "")
    }

    // MARK: - subjectsMatch

    func testWindowTitleWithReMatchesOriginalSubject() {
        XCTAssertTrue(MailContextService.subjectsMatch(windowTitle: "Re: Angebot Kurs", selectedSubject: "Angebot Kurs"))
    }

    func testPrefixesOnBothSidesAreIgnored() {
        XCTAssertTrue(MailContextService.subjectsMatch(windowTitle: "AW: Angebot Kurs", selectedSubject: "Re: Angebot Kurs"))
        XCTAssertTrue(MailContextService.subjectsMatch(windowTitle: "Fwd: Angebot Kurs", selectedSubject: "WG: Angebot Kurs"))
    }

    func testCaseAndWhitespaceDifferencesStillMatch() {
        XCTAssertTrue(MailContextService.subjectsMatch(windowTitle: "re: angebot   kurs", selectedSubject: "Angebot Kurs"))
    }

    func testDifferentSubjectsDoNotMatch() {
        XCTAssertFalse(MailContextService.subjectsMatch(windowTitle: "Re: Rechnung 4711", selectedSubject: "Angebot Kurs"))
        XCTAssertFalse(MailContextService.subjectsMatch(windowTitle: "Re: Angebot", selectedSubject: "Angebot Kurs"))
    }

    func testEmptySubjectsNeverMatch() {
        XCTAssertFalse(MailContextService.subjectsMatch(windowTitle: "", selectedSubject: ""))
        XCTAssertFalse(MailContextService.subjectsMatch(windowTitle: "Re:", selectedSubject: ""))
        XCTAssertFalse(MailContextService.subjectsMatch(windowTitle: "Re: Angebot", selectedSubject: ""))
    }

    // MARK: - truncate

    func testShortContentIsUnchanged() {
        XCTAssertEqual(MailContextService.truncate("Hallo", limit: 10), "Hallo")
        XCTAssertEqual(MailContextService.truncate("1234567890", limit: 10), "1234567890")
    }

    func testTruncationKeepsTheStartOfTheThread() {
        XCTAssertEqual(MailContextService.truncate("NEUESTE ... aeltere", limit: 7), "NEUESTE")
    }

    func testDefaultLimitIsFortyThousand() {
        XCTAssertEqual(MailContextService.maxContentCharacters, 40_000)
        let long = String(repeating: "a", count: 50_000)
        XCTAssertEqual(MailContextService.truncate(long).count, 40_000)
    }

    func testTruncationNeverSplitsACharacter() {
        let text = String(repeating: "\u{1F600}", count: 20)
        XCTAssertEqual(MailContextService.truncate(text, limit: 5), String(repeating: "\u{1F600}", count: 5))
    }

    // MARK: - Errors

    func testNotMailErrorMessage() {
        XCTAssertEqual(MailContextError.notMail.errorDescription, "Blitztext Mail funktioniert nur in Apple Mail.")
    }

    func testMismatchErrorNamesBothSubjects() {
        let message = MailContextError.subjectMismatch(window: "Re: A", selected: "B").errorDescription ?? ""
        XCTAssertTrue(message.contains("Re: A"))
        XCTAssertTrue(message.contains("B"))
    }
}
