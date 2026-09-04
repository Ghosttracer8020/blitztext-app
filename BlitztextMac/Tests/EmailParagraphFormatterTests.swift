import XCTest

/// Covers rule R0-R5 of EmailParagraphFormatter.format via the 20 mandatory
/// scenarios from SPEC-formatter.md, using real German (and a few English)
/// dictation-style example texts.
final class EmailParagraphFormatterTests: XCTestCase {

    func testGreetingAndSignOffAroundPlainBody() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Hallo Thomas, vielen Dank für deine Nachricht. Ich schaue mir das morgen an und melde mich. Viele Grüße Ben"
            ),
            "Hallo Thomas,\n\nvielen Dank für deine Nachricht. Ich schaue mir das morgen an und melde mich.\n\nViele Grüße\nBen"
        )
    }

    func testFormalGreetingWithCommaSignOffAndFullName() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Sehr geehrte Frau Müller, anbei erhalten Sie die Unterlagen. Mit freundlichen Grüßen, Ben Schmidt."
            ),
            "Sehr geehrte Frau Müller,\n\nanbei erhalten Sie die Unterlagen.\n\nMit freundlichen Grüßen\nBen Schmidt"
        )
    }

    func testLiebeGreetingAndLiebeGrüßeSignOff() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Liebe Anna, danke dir für die schnelle Rückmeldung. Liebe Grüße, dein Ben"
            ),
            "Liebe Anna,\n\ndanke dir für die schnelle Rückmeldung.\n\nLiebe Grüße\ndein Ben"
        )
    }

    func testGutenMorgenGreetingAndBisMorgenSignOffWithTrailingPeriod() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Guten Morgen zusammen. Kurze Info, das Meeting ist auf 14 Uhr verschoben. Bis morgen. Ben."
            ),
            "Guten Morgen zusammen.\n\nKurze Info, das Meeting ist auf 14 Uhr verschoben.\n\nBis morgen\nBen"
        )
    }

    func testShortQuestionWithoutGreetingOrSignOffStaysUnchanged() {
        let text = "Kannst du mir bitte die Datei schicken?"
        XCTAssertEqual(EmailParagraphFormatter.format(text), text)
    }

    func testShortGreetingWithoutSignOffStaysUnchanged() {
        let text = "Hallo Thomas, kannst du mir kurz die Datei schicken?"
        XCTAssertEqual(EmailParagraphFormatter.format(text), text)
    }

    func testGreetingWithTwentyFivePlusWordsAndNoSignOffGetsParagraphAfterGreeting() {
        let prefix = "Hallo Team, "
        let rest = "ich wollte euch kurz über den aktuellen Stand unseres Projekts informieren und dazu die nächsten Schritte besprechen die wir in den kommenden Wochen gemeinsam angehen sollten damit wir das Ziel rechtzeitig und ohne größere Probleme erreichen können."
        let result = EmailParagraphFormatter.format(prefix + rest)

        XCTAssertTrue(result.hasPrefix("Hallo Team,\n\n"))
        XCTAssertEqual(String(result.dropFirst("Hallo Team,\n\n".count)), rest)
    }

    func testHalloMidSentenceIsNotTreatedAsGreeting() {
        let text = "Ich habe ihm dann hallo gesagt und wir sind zusammen essen gegangen."
        XCTAssertEqual(EmailParagraphFormatter.format(text), text)
    }

    func testSignOffRejectedWhenTooManyWordsFollowThePhrase() {
        let text = "Viele Grüße an deine Familie und sag ihr, dass wir uns freuen."
        XCTAssertEqual(EmailParagraphFormatter.format(text), text)
    }

    func testDankeUndVieleGrüßeBreaksAtSentenceStart() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Hallo Lisa, das Angebot passt so. Danke und viele Grüße Ben"
            ),
            "Hallo Lisa,\n\ndas Angebot passt so.\n\nDanke und viele Grüße\nBen"
        )
    }

    func testTextWithExistingNewlineIsLeftUnchanged() {
        let text = "Hallo Thomas,\nschon formatiert."
        XCTAssertEqual(EmailParagraphFormatter.format(text), text)
    }

    func testFormatIsIdempotent() {
        let text = "Hallo Thomas, vielen Dank für deine Nachricht. Ich schaue mir das morgen an und melde mich. Viele Grüße Ben"
        let once = EmailParagraphFormatter.format(text)
        let twice = EmailParagraphFormatter.format(once)
        XCTAssertEqual(twice, once)
    }

    func testEnglishGreetingAndBestRegardsSignOff() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Hi John, thanks for the update. I will review the draft tomorrow and get back to you. Best regards, Ben"
            ),
            "Hi John,\n\nthanks for the update. I will review the draft tomorrow and get back to you.\n\nBest regards\nBen"
        )
    }

    func testLgAbbreviationSignOff() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Hallo Max, passt für mich, wir machen das so wie besprochen. LG Ben"
            ),
            "Hallo Max,\n\npasst für mich, wir machen das so wie besprochen.\n\nLG\nBen"
        )
    }

    func testPeriodAfterGreetingIsPreserved() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Hallo Thomas. Vielen Dank für das Gespräch gestern. Ich melde mich Anfang nächster Woche. Viele Grüße Ben"
            ),
            "Hallo Thomas.\n\nVielen Dank für das Gespräch gestern. Ich melde mich Anfang nächster Woche.\n\nViele Grüße\nBen"
        )
    }

    func testSignOffRejectedWhenSentenceBeforePhraseIsTooLong() {
        let text = "Hallo zusammen, ich freue mich auf deine Antwort und sende dir und dem ganzen Team viele Grüße Ben"
        XCTAssertEqual(EmailParagraphFormatter.format(text), text)
    }

    func testMitFreundlichenGrüßenWithoutNameDropsTrailingPeriod() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Sehr geehrter Herr Krause, wir bestätigen Ihren Termin am Montag. Mit freundlichen Grüßen."
            ),
            "Sehr geehrter Herr Krause,\n\nwir bestätigen Ihren Termin am Montag.\n\nMit freundlichen Grüßen"
        )
    }

    func testBisBaldKeepsExclamationMark() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Hallo Tim, wir sehen uns dann am Freitag im Park. Bis bald! Ben"
            ),
            "Hallo Tim,\n\nwir sehen uns dann am Freitag im Park.\n\nBis bald!\nBen"
        )
    }

    func testSwissSpellingGrüsseIsTreatedLikeGrüße() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Hallo Peter, wir sehen uns am Montag im Büro. Viele Grüsse Ben"
            ),
            "Hallo Peter,\n\nwir sehen uns am Montag im Büro.\n\nViele Grüsse\nBen"
        )
    }

    func testLowercaseInputCapitalizesOnlyFirstLetterOfSignOffLine() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "hallo anna, vielen dank für deine nachricht. ich schaue mir das morgen an und melde mich. viele grüße ben"
            ),
            "hallo anna,\n\nvielen dank für deine nachricht. ich schaue mir das morgen an und melde mich.\n\nViele grüße\nben"
        )
    }

    func testEmptyStringAndBareGreetingStayUnchanged() {
        XCTAssertEqual(EmailParagraphFormatter.format(""), "")
        XCTAssertEqual(EmailParagraphFormatter.format("Hallo"), "Hallo")
    }

    // MARK: - Regression: abbreviation/number periods must not be mistaken for sentence punctuation

    func testGreetingWithTitleAbbreviationDoesNotSplitBeforeSurname() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Guten Tag Herr Dr. Schmidt, anbei erhalten Sie die Unterlagen wie besprochen. Mit freundlichen Grüßen Ben"
            ),
            "Guten Tag Herr Dr. Schmidt,\n\nanbei erhalten Sie die Unterlagen wie besprochen.\n\nMit freundlichen Grüßen\nBen"
        )
    }

    func testHalloGreetingWithTitleAbbreviationDoesNotSplitBeforeSurname() {
        XCTAssertEqual(
            EmailParagraphFormatter.format(
                "Hallo Herr Dr. Schmidt, anbei erhalten Sie die Unterlagen wie besprochen gestern. Mit freundlichen Grüßen Ben"
            ),
            "Hallo Herr Dr. Schmidt,\n\nanbei erhalten Sie die Unterlagen wie besprochen gestern.\n\nMit freundlichen Grüßen\nBen"
        )
    }

    func testGreetingWindowWithDictatedTimePeriodDoesNotSplitTheNumber() {
        // "14.30" has no comma within the 6-word greeting window, so per R1 there is
        // no recognizable greeting terminator here -- the greeting must not be
        // touched (and in particular never split as "14." / "30").
        let text = "Guten Morgen zusammen wir treffen uns um 14.30 Uhr, das Meeting beginnt pünktlich heute. Viele Grüße Ben"
        let result = EmailParagraphFormatter.format(text)
        XCTAssertFalse(result.contains("14.\n\n30"))
        XCTAssertTrue(result.hasSuffix("Viele Grüße\nBen"))
    }

    func testSignOffSentenceStartSkipsAbbreviationPeriodAndRejectsTooLongSentence() {
        // The nearest ". "-shaped substring before "viele Grüße" is "Dr. ", which is
        // an abbreviation, not a real sentence end. The true (single) sentence has
        // 11 words before the sign-off phrase, over R2c's 8-word cap, so the
        // sign-off must be rejected entirely and the text must stay unchanged.
        let text = "Und dann war da noch Frau Dr. Meier hat zugesagt und viele Grüße Ben"
        XCTAssertEqual(EmailParagraphFormatter.format(text), text)
    }
}
