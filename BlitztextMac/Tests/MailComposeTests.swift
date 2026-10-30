import XCTest

/// Pure parts of the "Neue Mail" mode; reading and filling Mail's compose
/// window (Accessibility) needs a running Mail and is exercised manually.
final class MailComposeTests: XCTestCase {
    // MARK: - Window classification

    func testReplyAndForwardPrefixesAreReplyWindows() {
        for title in ["Re: Angebot", "AW: Angebot", "WG: Angebot", "Fwd: Angebot", "Fw: Angebot", "RE:Angebot", "  aw : Angebot"] {
            XCTAssertEqual(MailWindowKind.classify(title: title, hasToField: true), .reply, title)
        }
    }

    func testComposeWindowsWithoutPrefix() {
        for title in ["Neue E-Mail", "Angebot Kurs", "Reservierung Halle", "Fwdkurs", "Termin Re: Planung", ""] {
            XCTAssertEqual(MailWindowKind.classify(title: title, hasToField: true), .compose, title)
        }
    }

    func testUnreadableTitleKeepsTheReplyPath() {
        // An AX timeout must not turn a reply window into a context-free new mail.
        XCTAssertEqual(MailWindowKind.classify(title: nil, hasToField: true), .reply)
    }

    func testWindowWithoutToFieldIsNotCompose() {
        XCTAssertEqual(MailWindowKind.classify(title: "Neue E-Mail", hasToField: false), .other)
        XCTAssertEqual(MailWindowKind.classify(title: "Re: Angebot", hasToField: false), .other)
        XCTAssertEqual(MailWindowKind.classify(title: nil, hasToField: false), .other)
    }

    // MARK: - Recipient names

    func testRecipientNamesComeFromTokens() {
        XCTAssertEqual(
            MailComposeService.recipientNames(tokenNames: ["Thomas Meier", " Anna Muster "], fieldValue: "\u{FFFC}\u{FFFC}"),
            ["Thomas Meier", "Anna Muster"]
        )
    }

    func testEmptyFieldHasNoRecipients() {
        XCTAssertEqual(MailComposeService.recipientNames(tokenNames: [], fieldValue: ""), [])
        XCTAssertEqual(MailComposeService.recipientNames(tokenNames: [], fieldValue: "\u{FFFC}"), [])
        XCTAssertEqual(MailComposeService.recipientNames(tokenNames: ["\u{FFFC}", "  "], fieldValue: ""), [])
    }

    func testUntokenizedTextIsUsedWithoutTokens() {
        XCTAssertEqual(
            MailComposeService.recipientNames(tokenNames: [], fieldValue: "a@b.de, c@d.de; "),
            ["a@b.de", "c@d.de"]
        )
    }

    // MARK: - Prompt

    private let context = MailComposeContext(
        toRecipients: ["Thomas Meier"],
        ccRecipients: ["Anna Muster"],
        subject: "Angebot"
    )

    func testComposeUserMessageHasBothSections() {
        let message = MailReplyPromptBuilder.composeUserMessage(context: context, transcript: "Termin verschieben")
        XCTAssertTrue(message.hasPrefix("=== NEUE MAIL ===\nAn: Thomas Meier\nCc: Anna Muster\nBetreff: Angebot"))
        XCTAssertTrue(message.hasSuffix("=== STICHPUNKTE VON BEN ===\nTermin verschieben"))
        XCTAssertFalse(message.contains("ORIGINALE MAIL"))
    }

    func testComposeUserMessageOmitsEmptyFields() {
        let bare = MailComposeContext(toRecipients: ["Thomas Meier"])
        let message = MailReplyPromptBuilder.composeUserMessage(context: bare, transcript: "x")
        XCTAssertTrue(message.contains("An: Thomas Meier"))
        XCTAssertFalse(message.contains("Cc:"))
        XCTAssertFalse(message.contains("Betreff:"))

        let none = MailReplyPromptBuilder.composeUserMessage(context: MailComposeContext(), transcript: "x")
        XCTAssertFalse(none.contains("An:"))
        XCTAssertTrue(none.contains("keine Empfänger eingetragen"))
    }

    func testComposeContractCarriesGreetingAddressingAndClosingRules() {
        let prompt = MailReplyPromptBuilder.composeContract
        XCTAssertTrue(prompt.contains("Standard ist die Du-Form"))
        XCTAssertFalse(prompt.contains("Standard ist die Sie-Form"))
        XCTAssertTrue(prompt.contains("duzen"))
        XCTAssertTrue(prompt.contains("Guten Tag Frau Meier,"))
        XCTAssertTrue(prompt.contains("Vorname"))
        XCTAssertTrue(prompt.contains("neutrale Begrüßung"))
        XCTAssertTrue(prompt.contains("„Liebe Grüße\" oder „Viele Grüße\""))
        XCTAssertTrue(prompt.contains("darunter „Ben\""))
        XCTAssertTrue(prompt.contains("darunter „Ben Scheffler\""))
        XCTAssertTrue(prompt.contains("Nach dem Namen endet der Text"))
        XCTAssertTrue(prompt.contains("keine originale Mail"))
        XCTAssertTrue(MailReplyPromptBuilder.defaultComposeSystemPrompt.contains("Erfinde nichts dazu"))
    }

    func testCustomInstructionCannotDropComposeRules() {
        let prompt = MailReplyPromptBuilder.composeSystemPrompt(customInstruction: "Schreib kurz.", customTerms: [])
        XCTAssertTrue(prompt.contains("Standard ist die Du-Form"))
        XCTAssertTrue(prompt.contains("darunter „Ben Scheffler\""))
    }

    func testContractDecidesAddressFormFromHistoryDomainAndBullets() {
        let prompt = MailReplyPromptBuilder.composeContract
        XCTAssertTrue(prompt.contains("LETZTE MAIL VON"))
        XCTAssertTrue(prompt.contains("parkourone.com"))
        XCTAssertTrue(prompt.contains("„siezen\""))
        XCTAssertTrue(prompt.contains("Gibt es keinen solchen Abschnitt, schreib per Du."))
        XCTAssertTrue(prompt.contains("Greif ihren Inhalt nicht auf"))
    }

    func testComposeUserMessageWithHistoryPutsSectionBetweenMailAndPoints() {
        let history = MailHistory(sender: "Thomas Meier <t@firma.ch>", dateReceived: "Montag, 5. Oktober 2026", excerpt: "Hallo Ben,\nbis bald")
        let message = MailReplyPromptBuilder.composeUserMessage(context: context, history: history, transcript: "Termin")
        let mail = message.range(of: "=== NEUE MAIL ===")!.lowerBound
        let last = message.range(of: "=== LETZTE MAIL VON Thomas Meier AN BEN ===")!.lowerBound
        let points = message.range(of: "=== STICHPUNKTE VON BEN ===")!.lowerBound
        XCTAssertTrue(mail < last && last < points)
        XCTAssertTrue(message.contains("Absender: Thomas Meier <t@firma.ch>"))
        XCTAssertTrue(message.contains("Datum: Montag, 5. Oktober 2026"))
        XCTAssertTrue(message.contains("Auszug:\nHallo Ben,\nbis bald"))
        XCTAssertTrue(message.hasSuffix("=== STICHPUNKTE VON BEN ===\nTermin"))
    }

    func testComposeUserMessageWithoutHistoryHasNoHistorySection() {
        let message = MailReplyPromptBuilder.composeUserMessage(context: context, transcript: "Termin")
        XCTAssertFalse(message.contains("LETZTE MAIL"))
    }

    // MARK: - History lookup

    func testAppleScriptEscapingHandlesQuotesAndBackslashes() {
        XCTAssertEqual(MailHistoryService.escapeForAppleScript(#"Anna "Ace" Muster"#), #"Anna \"Ace\" Muster"#)
        XCTAssertEqual(MailHistoryService.escapeForAppleScript(#"A\B"#), #"A\\B"#)
        XCTAssertEqual(MailHistoryService.escapeForAppleScript(#"\" + do shell script "x""#), #"\\\" + do shell script \"x\""#)
    }

    func testAppleScriptEscapingHandlesControlCharacters() {
        XCTAssertEqual(MailHistoryService.escapeForAppleScript("a\nb\rc\td"), #"a\nb\rc\td"#)
    }

    func testNewestPicksLatestDateRegardlessOfOrder() {
        func candidate(_ offset: TimeInterval, _ tag: String) -> MailHistoryService.Candidate {
            .init(date: Date(timeIntervalSince1970: 1_700_000_000 + offset), dateText: tag, sender: "Anna", content: tag)
        }
        let list = [candidate(100, "mid"), candidate(900, "newest"), candidate(-50, "old")]
        XCTAssertEqual(MailHistoryService.newest(of: list)?.content, "newest")
        XCTAssertNil(MailHistoryService.newest(of: []))
    }

    func testAddressesBenLooksAtTheGreetingOnly() {
        XCTAssertTrue(MailHistoryService.addressesBen("Hallo Ben,\n\nkurze Frage"))
        XCTAssertTrue(MailHistoryService.addressesBen("\n\n  Lieber Ben!\nText"))
        XCTAssertTrue(MailHistoryService.addressesBen("Sehr geehrter Herr Scheffler,\nText"))
        XCTAssertFalse(MailHistoryService.addressesBen("Guten Morgen Christoph,"))
        XCTAssertFalse(MailHistoryService.addressesBen("Guten Morgen Christoph,\n\nText\nmehr Text\nHallo Ben, spät"))
        XCTAssertFalse(MailHistoryService.addressesBen("Bens Team grüsst\nText"))
        XCTAssertFalse(MailHistoryService.addressesBen("Hallo zusammen,\nText"))
        XCTAssertFalse(MailHistoryService.addressesBen(""))
    }

    func testPreferredTakesNewestMailAddressingBenElseNewest() {
        func candidate(_ offset: TimeInterval, _ content: String) -> MailHistoryService.Candidate {
            .init(date: Date(timeIntervalSince1970: 1_700_000_000 + offset), dateText: content, sender: "Anna", content: content)
        }
        let list = [
            candidate(900, "Guten Morgen Christoph,"),
            candidate(500, "Hallo Ben,"),
            candidate(100, "Hallo Ben, alt"),
        ]
        XCTAssertEqual(MailHistoryService.preferred(of: list)?.content, "Hallo Ben,")
        XCTAssertEqual(MailHistoryService.preferred(of: [list[0]])?.content, "Guten Morgen Christoph,")
        XCTAssertNil(MailHistoryService.preferred(of: []))
    }

    func testSearchNeedlePrefersAddressElseName() {
        XCTAssertEqual(MailHistoryService.searchNeedle(from: "Jörg Birle <joerg@firma.de>"), "joerg@firma.de")
        XCTAssertEqual(MailHistoryService.searchNeedle(from: "Jörg Birle"), "Jörg Birle")
        XCTAssertEqual(MailHistoryService.searchNeedle(from: "\"Birle, Jörg\" <j@f.de>"), "j@f.de")
        XCTAssertNil(MailHistoryService.searchNeedle(from: "Al"))
    }

    func testIsBenRecognizesOwnSender() {
        XCTAssertTrue(MailHistoryService.isBen("Ben Scheffler <ben@parkourone.com>"))
        XCTAssertTrue(MailHistoryService.isBen("ben@parkourone.com"))
        XCTAssertTrue(MailHistoryService.isBen("Ben <b@x.ch>"))
        XCTAssertFalse(MailHistoryService.isBen("Bens Team <t@x.ch>"))
        XCTAssertFalse(MailHistoryService.isBen("Jörg Birle <joerg@firma.de>"))
    }

    func testScriptBoundsContentReadsAndKeepsDeadlineInBothPhases() {
        let script = MailHistoryService.script(forName: "a@b.ch", deadlineSeconds: 5)
        XCTAssertTrue(script.contains("repeat with k from 1 to \(MailHistoryService.maxContentReads)"))
        XCTAssertEqual(script.components(separatedBy: "> 5 then").count - 1, 3)
        XCTAssertTrue(script.contains("seenIds does not contain mid"))
        XCTAssertFalse(script.contains("set dates"))
        XCTAssertFalse(script.contains("date received of found"))
    }

    func testScriptDeadlineStopsBothLoopsAndStaysBelowBudget() {
        let script = MailHistoryService.script(forName: "Anna", deadlineSeconds: 5)
        XCTAssertTrue(script.contains("> 5 then"))
        XCTAssertTrue(script.contains("if expired then exit repeat"))
        XCTAssertLessThan(5 + MailHistoryService.eventTimeoutSeconds, Int(MailHistoryService.budgetSeconds))
    }

    func testScriptEmbedsEscapedNameOnly() {
        let script = MailHistoryService.script(forName: #"O"Neil"#)
        XCTAssertTrue(script.contains(#"set needle to "O\"Neil""#))
        XCTAssertTrue(script.contains("sender contains needle"))
        XCTAssertTrue(script.contains("with timeout of"))
    }

    func testSearchNameRejectsShortAndCleansWhitespace() {
        XCTAssertNil(MailHistoryService.searchName(from: "Al"))
        XCTAssertNil(MailHistoryService.searchName(from: "  A \n"))
        XCTAssertEqual(MailHistoryService.searchName(from: " Anna \n  Muster "), "Anna Muster")
    }

    func testParseBuildsHistoryAndTruncatesExcerpt() {
        let long = String(repeating: "x", count: MailHistoryService.maxExcerptCharacters + 500)
        let history = MailHistoryService.parse(
            sender: "Anna Muster <anna@firma.ch>", dateReceived: " 5. Oktober 2026 ", content: long, name: "anna muster"
        )
        XCTAssertEqual(history?.sender, "Anna Muster <anna@firma.ch>")
        XCTAssertEqual(history?.dateReceived, "5. Oktober 2026")
        XCTAssertEqual(history?.excerpt.count, MailHistoryService.maxExcerptCharacters)
    }

    func testParseReturnsNilWithoutMatchOrContent() {
        XCTAssertNil(MailHistoryService.parse(sender: nil, dateReceived: "d", content: "c", name: "Anna"))
        XCTAssertNil(MailHistoryService.parse(sender: "Peter <p@x.ch>", dateReceived: "d", content: "c", name: "Anna"))
        XCTAssertNil(MailHistoryService.parse(sender: "Anna <a@x.ch>", dateReceived: "d", content: "  ", name: "Anna"))
        XCTAssertNil(MailHistoryService.parse(sender: "Anna <a@x.ch>", dateReceived: "d", content: nil, name: "Anna"))
    }

    // MARK: - Field detection

    private typealias Candidate = MailComposeService.FieldCandidate

    private func text(_ value: String) -> Candidate { Candidate(role: "AXStaticText", identifier: nil, value: value) }
    private func field(_ id: String? = nil) -> Candidate { Candidate(role: "AXTextField", identifier: id, value: nil) }
    private let button = Candidate(role: "AXButton", identifier: nil, value: nil)

    func testClassifyFindsFieldsByLabelFallback() {
        let fields = [
            text("An:"), field("Mail.toField"), button,
            text("Kopie:"), field(), button,
            text("Blindkopie:"), field(), button,
            text("Antwort an:"), field(), button,
            text("Betreff:"), field(),
        ]
        XCTAssertEqual(MailComposeService.classify(fields: fields), .init(to: 1, cc: 4, subject: 13))
    }

    func testClassifyBlindCopyIsNotCc() {
        let fields = [text("An:"), field("Mail.toField"), text("Blindkopie:"), field(), text("Betreff:"), field()]
        XCTAssertEqual(MailComposeService.classify(fields: fields), .init(to: 1, cc: nil, subject: 5))
    }

    func testClassifyResetsLabelAfterEachField() {
        // "Kopie:" labels only the field right behind it, not the one after.
        let fields = [field("Mail.toField"), text("Kopie:"), field(), field()]
        XCTAssertEqual(MailComposeService.classify(fields: fields), .init(to: 0, cc: 2, subject: nil))
    }

    func testClassifyPrefersIdentifiersAndNeedsToField() {
        let byID = [field("Mail.toField"), field("Mail.subjectField"), field("Mail.ccField")]
        XCTAssertEqual(MailComposeService.classify(fields: byID), .init(to: 0, cc: 2, subject: 1))
        XCTAssertEqual(MailComposeService.classify(fields: [text("Betreff:"), field()]), .init(to: nil, cc: nil, subject: 1))
        XCTAssertEqual(MailComposeService.classify(fields: [text("Subject:"), field(), text("Cc:"), field()]).cc, 3)
    }

    func testBodyDescription() {
        XCTAssertTrue(MailComposeService.isBodyDescription("message body"))
        XCTAssertTrue(MailComposeService.isBodyDescription("Nachrichtentext"))
        XCTAssertFalse(MailComposeService.isBodyDescription("signature"))
        XCTAssertFalse(MailComposeService.isBodyDescription(nil))
    }

    func testComposeContractIsAppendedAlsoBehindCustomInstruction() {
        for instruction in ["", "Schreib kurz."] {
            let prompt = MailReplyPromptBuilder.composeSystemPrompt(customInstruction: instruction, customTerms: ["ParkourONE"])
            XCTAssertTrue(prompt.contains(MailReplyPromptBuilder.composeContract))
            XCTAssertTrue(prompt.contains("ParkourONE"))
            XCTAssertFalse(prompt.contains(MailReplyPromptBuilder.hintContract))
        }
        XCTAssertTrue(MailReplyPromptBuilder.composeSystemPrompt(customInstruction: "", customTerms: [])
            .hasPrefix(MailReplyPromptBuilder.defaultComposeSystemPrompt))
        XCTAssertTrue(MailReplyPromptBuilder.composeSystemPrompt(customInstruction: "Schreib kurz.", customTerms: [])
            .hasPrefix("Schreib kurz."))
    }

    // MARK: - API schema and parsing

    private func response(text: String, stopReason: String = "end_turn") -> Data {
        let body: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "stop_reason": stopReason,
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testComposeSchemaRequiresSubjectAndReplyOnly() throws {
        let data = try JSONEncoder().encode(AnthropicService.composeSchema)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "object")
        XCTAssertEqual(json["required"] as? [String], ["subject", "reply"])
        XCTAssertEqual(json["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["subject", "reply"])
    }

    func testParseComposeReadsSubjectAndReply() throws {
        let text = #"{"subject":"Angebot Kurs","reply":"Guten Tag Herr Meier,\n\nok."}"#
        XCTAssertEqual(
            try AnthropicService.parseCompose(from: response(text: text)),
            MailComposeResult(subject: "Angebot Kurs", reply: "Guten Tag Herr Meier,\n\nok.")
        )
    }

    func testParseComposeToleratesMissingSubject() throws {
        XCTAssertEqual(
            try AnthropicService.parseCompose(from: response(text: #"{"reply":"Text"}"#)),
            MailComposeResult(subject: "", reply: "Text")
        )
        XCTAssertEqual(
            try AnthropicService.parseCompose(from: response(text: #"{"subject":null,"reply":"Text"}"#)).subject,
            ""
        )
    }

    func testParseComposeKeepsSubjectOnOneLine() throws {
        let result = try AnthropicService.parseCompose(from: response(text: #"{"subject":" Angebot\nKurs ","reply":"Text"}"#))
        XCTAssertEqual(result.subject, "Angebot Kurs")
    }

    func testParseComposeFallsBackToWholeTextWhenNotJSON() throws {
        XCTAssertEqual(
            try AnthropicService.parseCompose(from: response(text: "Nur Text")),
            MailComposeResult(subject: "", reply: "Nur Text")
        )
    }

    func testParseComposeThrowsOnEmptyReplyAndMaxTokens() {
        XCTAssertThrowsError(try AnthropicService.parseCompose(from: response(text: #"{"subject":"A","reply":"  "}"#)))
        XCTAssertThrowsError(try AnthropicService.parseCompose(from: response(text: #"{"subject":"A","reply":"x"}"#, stopReason: "max_tokens"))) { error in
            guard case AnthropicError.truncated = error else { return XCTFail("expected truncated, got \(error)") }
        }
    }

    // MARK: - Typed panel title

    func testComposeTitle() {
        XCTAssertEqual(MailReplyTypedInput.composeTitle(recipients: []), "Neue Mail verfassen")
        XCTAssertEqual(MailReplyTypedInput.composeTitle(recipients: ["Anna"]), "Neue Mail an Anna")
        XCTAssertEqual(MailReplyTypedInput.composeTitle(recipients: ["Anna", "Tom"]), "Neue Mail an Anna u. a.")
    }
}
