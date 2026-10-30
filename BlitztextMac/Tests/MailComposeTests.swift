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
        XCTAssertTrue(prompt.contains("Immer Du."))
                XCTAssertTrue(prompt.contains("Guten Tag Frau Meier,"))
        XCTAssertTrue(prompt.contains("Vorname"))
        XCTAssertTrue(prompt.contains("neutrale Begrüßung"))
        XCTAssertTrue(prompt.contains("Bei Du: „Viele Grüße\", darunter „Ben\". „Liebe Grüße\" nur, wenn Ben es im Diktat ausdrücklich sagt."))
        XCTAssertTrue(prompt.contains("darunter „Ben\""))
        XCTAssertTrue(prompt.contains("darunter „Ben Scheffler\""))
        XCTAssertTrue(prompt.contains("Nach dem Namen endet der Text"))
        XCTAssertTrue(prompt.contains("keine originale Mail"))
        XCTAssertTrue(MailReplyPromptBuilder.defaultComposeSystemPrompt.contains("Erfinde nichts dazu"))
    }

    func testCustomInstructionCannotDropComposeRules() {
        let prompt = MailReplyPromptBuilder.composeSystemPrompt(customInstruction: "Schreib kurz.", customTerms: [])
        XCTAssertTrue(prompt.contains("Immer Du."))
        XCTAssertTrue(prompt.contains("darunter „Ben Scheffler\""))
    }

    func testAddressingRuleIsDuByDefaultWithExplicitSieTriggers() {
        for prompt in [MailReplyPromptBuilder.composeContract,
                       MailReplyPromptBuilder.composeSystemPrompt(customInstruction: "Schreib kurz.", customTerms: [])] {
            XCTAssertTrue(prompt.contains("Immer Du. Sie nur, wenn"))
            XCTAssertTrue(prompt.contains("„siezen\""))
            XCTAssertTrue(prompt.contains("„per Sie\""))
            XCTAssertTrue(prompt.contains("„Sie-Form\""))
            XCTAssertTrue(prompt.contains("Ihnen"))
            XCTAssertTrue(prompt.contains("keine Anrede"))
            XCTAssertTrue(prompt.contains("Hallo Jörg,"))
            XCTAssertTrue(prompt.contains("Hallo zusammen,"))
            XCTAssertFalse(prompt.contains("parkourone.com"))
            XCTAssertFalse(prompt.contains("LETZTE MAIL"))
        }
    }

    func testComposeUserMessageHasNoHistorySection() {
        let message = MailReplyPromptBuilder.composeUserMessage(context: context, transcript: "Termin")
        XCTAssertFalse(message.contains("LETZTE MAIL"))
        XCTAssertFalse(message.contains("Auszug:"))
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
