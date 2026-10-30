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

    // MARK: - Reply window fallback

    func testParsesGermanAttribution() {
        let attribution = MailContextService.parseAttribution(
            "Am 19.10.2026 um 19:14 schrieb Resort Mark <info@resort.example>:")
        XCTAssertEqual(attribution, .init(date: "19.10.2026 um 19:14", sender: "Resort Mark <info@resort.example>"))
    }

    func testParsesEnglishAttribution() {
        let attribution = MailContextService.parseAttribution("On Oct 19, 2026, at 7:14 PM, Jane Doe <jane@x.example> wrote:")
        XCTAssertEqual(attribution?.sender, "Jane Doe <jane@x.example>")
        XCTAssertEqual(attribution?.date, "Oct 19, 2026, at 7:14 PM")
    }

    func testAttributionToleratesWhitespaceAndRejectsOtherLines() {
        XCTAssertNotNil(MailContextService.parseAttribution("  Am 1.1.2026   schrieb  Max :\n"))
        XCTAssertNil(MailContextService.parseAttribution("Am Montag schrieb ich dir schon etwas"))
        XCTAssertNil(MailContextService.parseAttribution("Guten Tag,"))
        XCTAssertNil(MailContextService.parseAttribution(""))
    }

    func testQuotedTextDropsOwnPartBeforeAttribution() {
        let result = MailContextService.quotedText(fromBodyLines: [
            "Danke dir!", "\u{FFFC}", "Am 19.10.2026 um 19:14 schrieb Anna <a@x.example>:", "Hallo Ben,", "", "bis Freitag?",
        ])
        XCTAssertEqual(result?.text, "Am 19.10.2026 um 19:14 schrieb Anna <a@x.example>:\nHallo Ben,\nbis Freitag?")
        XCTAssertEqual(result?.attribution.sender, "Anna <a@x.example>")
    }

    func testQuotedTextNilWithoutAttribution() {
        XCTAssertNil(MailContextService.quotedText(fromBodyLines: [" Hallo ", "Welt", "Gruss, Ben"]))
    }

    func testQuotedTextFindsAttributionSplitOverNodes() {
        let result = MailContextService.quotedText(fromBodyLines: [
            "Mein Entwurf", "Am 19.10.2026 um 19:14 schrieb Anna", "<a@x.example>:", "Hallo Ben",
        ])
        XCTAssertEqual(result?.attribution.sender, "Anna <a@x.example>")
        XCTAssertEqual(result?.text, "Am 19.10.2026 um 19:14 schrieb Anna <a@x.example>:\nHallo Ben")
    }

    func testEnglishAttributionWithCommaInName() {
        let a = MailContextService.parseAttribution("On Oct 19, 2026, at 7:14 PM, Doe, Jane <j@x.example> wrote:")
        XCTAssertEqual(a?.sender, "Doe, Jane <j@x.example>")
        XCTAssertEqual(a?.date, "Oct 19, 2026, at 7:14 PM")
        let b = MailContextService.parseAttribution("On Oct 19, 2026, Jane <j@x.example> wrote:")
        XCTAssertEqual(b?.sender, "Jane <j@x.example>")
        XCTAssertEqual(b?.date, "Oct 19, 2026")
    }

    func testOnlyRealReplyPrefixesQualifyForFallback() {
        XCTAssertTrue(MailContextService.hasRealReplyPrefix("Re: Angebot"))
        XCTAssertTrue(MailContextService.hasRealReplyPrefix("AW: Angebot"))
        XCTAssertFalse(MailContextService.hasRealReplyPrefix("Fwd: Angebot"))
        XCTAssertFalse(MailContextService.hasRealReplyPrefix("WG: Angebot"))
        XCTAssertFalse(MailContextService.hasRealReplyPrefix("Angebot"))
    }

    func testQuotedTextNilWithoutOriginal() {
        XCTAssertNil(MailContextService.quotedText(fromBodyLines: []))
        XCTAssertNil(MailContextService.quotedText(fromBodyLines: ["", "\u{FFFC}", "  "]))
        XCTAssertNil(MailContextService.quotedText(fromBodyLines: ["Eigener Text", "Am 1.1.2026 schrieb Max:"]))
    }

    func testContextFromReplyWindowUsesAttributionAndRecipients() {
        let body = MailContextService.quotedText(fromBodyLines: ["Am 1.1.2026 um 10:00 schrieb Max <m@x.example>:", "Hi"])!
        let context = MailContextService.contextFromReplyWindow(
            title: "AW: Re: Angebot",
            body: body,
            compose: MailComposeContext(toRecipients: ["Max"], ccRecipients: ["Eva"], subject: "")
        )
        XCTAssertEqual(context.subject, "Angebot")
        XCTAssertEqual(context.sender, "Max <m@x.example>")
        XCTAssertEqual(context.dateReceived, "1.1.2026 um 10:00")
        XCTAssertEqual(context.toRecipients, ["Max"])
        XCTAssertEqual(context.ccRecipients, ["Eva"])
        XCTAssertTrue(context.content.hasSuffix("Hi"))
    }

    func testContextFromReplyWindowTruncates() {
        let body = MailContextService.quotedText(fromBodyLines: ["Am 1.1.2026 schrieb Max:", String(repeating: "x", count: 50_000)])!
        let context = MailContextService.contextFromReplyWindow(
            title: "Re: Thema", body: body,
            compose: MailComposeContext(toRecipients: ["Max", "Eva"], ccRecipients: [], subject: ""))
        XCTAssertEqual(context.sender, "Max")
        XCTAssertEqual(context.content.count, MailContextService.maxContentCharacters)
    }
}
