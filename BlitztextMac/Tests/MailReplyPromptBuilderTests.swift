import XCTest

final class MailReplyPromptBuilderTests: XCTestCase {
    private let sender = MailSender(firstName: "Anna", fullName: "Anna Muster")
    private let anonymous = MailSender()

    private let context = MailContext(
        subject: "Angebot Kurs",
        sender: "Thomas Meier <thomas@example.com>",
        dateReceived: "Montag, 26. Oktober 2026 um 09:15:00",
        content: "Hallo Ben,\n\nkannst du mir ein Angebot schicken?\n\nLG Thomas",
        toRecipients: ["ben@example.com"],
        ccRecipients: ["anna@example.com"]
    )

    func testEmptyInstructionFallsBackToDefault() {
        XCTAssertEqual(
            MailReplyPromptBuilder.systemPrompt(customInstruction: "  \n ", customTerms: [], sender: sender),
            MailReplyPromptBuilder.defaultSystemPrompt(for: sender) + "\n\n" + MailReplyPromptBuilder.hintContract(for: sender)
                + "\n\n" + MailReplyPromptBuilder.replyAddressingContract(for: sender)
        )
    }

    func testCustomInstructionReplacesDefault() {
        let prompt = MailReplyPromptBuilder.systemPrompt(customInstruction: "Antworte kurz.", customTerms: [], sender: sender)
        XCTAssertTrue(prompt.hasPrefix("Antworte kurz."))
        XCTAssertFalse(prompt.contains(MailReplyPromptBuilder.defaultSystemPrompt(for: sender)))
    }

    func testHintContractIsAppendedWithDefaultAndCustomInstruction() {
        for instruction in ["", "Antworte kurz."] {
            let prompt = MailReplyPromptBuilder.systemPrompt(customInstruction: instruction, customTerms: [], sender: sender)
            XCTAssertTrue(prompt.contains(MailReplyPromptBuilder.hintContract(for: sender)))
            XCTAssertTrue(prompt.contains("JSON-Objekt mit zwei Feldern"))
            XCTAssertTrue(prompt.contains("Die Antwort folgt immer den Stichpunkten von Anna"))
            XCTAssertTrue(prompt.contains("höchstens 5"))
            XCTAssertTrue(prompt.contains("widerspruch"))
            XCTAssertTrue(prompt.contains("schon_beantwortet"))
            XCTAssertTrue(prompt.contains("offen"))
            XCTAssertTrue(prompt.contains("leeres Array"))
        }
    }

    func testDefaultPromptKeepsUnansweredQuestionsOutOfTheReply() {
        XCTAssertFalse(MailReplyPromptBuilder.defaultSystemPrompt(for: sender).contains("erwähnst du nicht.\n"))
        XCTAssertTrue(MailReplyPromptBuilder.defaultSystemPrompt(for: sender).contains("Prüfhinweise"))
    }

    func testAddressingContractDefaultsToDuAndIsAppendedBehindCustomInstruction() {
        for instruction in ["", "Antworte kurz."] {
            let prompt = MailReplyPromptBuilder.systemPrompt(customInstruction: instruction, customTerms: [], sender: sender)
            XCTAssertTrue(prompt.contains(MailReplyPromptBuilder.replyAddressingContract(for: sender)))
            XCTAssertTrue(prompt.contains("Immer Du. Sie nur, wenn"))
            XCTAssertTrue(prompt.contains("Sie, Ihnen, Ihr, Ihre"))
            XCTAssertTrue(prompt.contains("„siezen\""))
            XCTAssertTrue(prompt.contains("„per Sie\""))
            XCTAssertTrue(prompt.contains("„Sie-Form\""))
            XCTAssertTrue(prompt.contains("keine Anrede"))
            XCTAssertTrue(prompt.contains("Hallo zusammen,"))
            XCTAssertTrue(prompt.contains("Guten Tag Frau Meier,"))
            XCTAssertFalse(prompt.contains("parkourone.com"))
            XCTAssertFalse(prompt.contains("LETZTE MAIL"))
        }
    }

    func testUserMessageHasNoHistorySection() {
        let message = MailReplyPromptBuilder.userMessage(context: context, transcript: "Zusage", sender: sender)
        XCTAssertFalse(message.contains("LETZTE MAIL"))
        XCTAssertTrue(message.hasSuffix("=== STICHPUNKTE VON ANNA ===\nZusage"))
    }

    func testCustomTermsAreAppended() {
        let prompt = MailReplyPromptBuilder.systemPrompt(customInstruction: "", customTerms: ["ParkourONE", "UltraDic"], sender: sender)
        XCTAssertTrue(prompt.hasPrefix(MailReplyPromptBuilder.defaultSystemPrompt(for: sender)))
        XCTAssertTrue(prompt.contains("ParkourONE, UltraDic"))
        XCTAssertTrue(prompt.contains(MailReplyPromptBuilder.hintContract(for: sender)))
    }

    func testDefaultPromptCarriesTheCoreRules() {
        let prompt = MailReplyPromptBuilder.defaultSystemPrompt(for: sender)
        XCTAssertTrue(prompt.contains("Erfinde nichts dazu"))
        XCTAssertTrue(prompt.contains("kein ausformuliertes Diktat"))
        XCTAssertTrue(prompt.contains("Kurz und auf den Punkt, aber freundlich"))
        XCTAssertTrue(prompt.contains("Jeder Gedanke kommt genau einmal vor"))
        XCTAssertFalse(prompt.contains("Ordne jeden Stichpunkt der Stelle in ihrer Mail zu"))
        XCTAssertTrue(prompt.contains("Standard ist Du"))
        XCTAssertTrue(prompt.contains("Sprache der letzten eingegangenen Nachricht"))
        XCTAssertTrue(prompt.contains("Antworte auf die Mail"))
        XCTAssertTrue(prompt.contains("darunter „Anna\"."))
        XCTAssertTrue(prompt.contains("darunter „Anna Muster\"."))
        XCTAssertTrue(prompt.contains("Keine Signatur"))
        XCTAssertTrue(prompt.contains("Kein Betreff"))
    }

    func testDefaultPromptReferencesTheSectionHeaders() {
        XCTAssertTrue(MailReplyPromptBuilder.defaultSystemPrompt(for: sender).contains("ORIGINALE MAIL"))
        XCTAssertTrue(MailReplyPromptBuilder.defaultSystemPrompt(for: sender).contains("STICHPUNKTE VON ANNA"))
    }

    func testUserMessageHasDelimitedSectionsInOrder() {
        let message = MailReplyPromptBuilder.userMessage(context: context, transcript: "Antworte auf die Mail: Punkt eins.", sender: sender)
        let mailRange = message.range(of: MailReplyPromptBuilder.originalMailHeader)
        let pointsRange = message.range(of: MailReplyPromptBuilder.pointsHeader(for: sender))
        XCTAssertNotNil(mailRange)
        XCTAssertNotNil(pointsRange)
        XCTAssertLessThan(mailRange!.lowerBound, pointsRange!.lowerBound)
        XCTAssertTrue(message.hasSuffix("Antworte auf die Mail: Punkt eins."))
    }

    func testUserMessageContainsMailFields() {
        let message = MailReplyPromptBuilder.userMessage(context: context, transcript: "x", sender: sender)
        XCTAssertTrue(message.contains("Betreff: Angebot Kurs"))
        XCTAssertTrue(message.contains("Von: Thomas Meier <thomas@example.com>"))
        XCTAssertTrue(message.contains("Datum: Montag, 26. Oktober 2026 um 09:15:00"))
        XCTAssertTrue(message.contains("An: ben@example.com"))
        XCTAssertTrue(message.contains("Cc: anna@example.com"))
        XCTAssertTrue(message.contains("kannst du mir ein Angebot schicken?"))
    }

    func testRecipientLinesAreOmittedWhenEmpty() {
        var bare = context
        bare.toRecipients = []
        bare.ccRecipients = []
        let message = MailReplyPromptBuilder.userMessage(context: bare, transcript: "x", sender: sender)
        XCTAssertFalse(message.contains("An:"))
        XCTAssertFalse(message.contains("Cc:"))
    }

    // MARK: - Configured sender name

    private func allPrompts(for sender: MailSender) -> [String] {
        [
            MailReplyPromptBuilder.systemPrompt(customInstruction: "", customTerms: [], sender: sender),
            MailReplyPromptBuilder.composeSystemPrompt(customInstruction: "", customTerms: [], sender: sender),
            MailReplyPromptBuilder.userMessage(context: context, transcript: "x", sender: sender),
            MailReplyPromptBuilder.pointsHeader(for: sender),
        ]
    }

    func testNoPromptHardcodesTheOriginalOwnersName() {
        for who in [sender, anonymous] {
            for prompt in allPrompts(for: who) {
                XCTAssertFalse(prompt.contains("Scheffler"))
                XCTAssertFalse(prompt.contains("BEN"))
                XCTAssertFalse(prompt.contains("Bens "))
                XCTAssertFalse(prompt.contains("von Ben"))
            }
        }
    }

    func testConfiguredNamesAreInjectedIntoPromptsAndHeaders() {
        let reply = MailReplyPromptBuilder.systemPrompt(customInstruction: "", customTerms: [], sender: sender)
        XCTAssertTrue(reply.contains("im Namen von Anna"))
        XCTAssertTrue(reply.contains("STICHPUNKTE VON ANNA"))
        XCTAssertTrue(reply.contains("darunter „Anna Muster\""))
        let compose = MailReplyPromptBuilder.composeSystemPrompt(customInstruction: "", customTerms: [], sender: sender)
        XCTAssertTrue(compose.contains("im Namen von Anna"))
        XCTAssertTrue(compose.contains("darunter „Anna\""))
        XCTAssertEqual(MailReplyPromptBuilder.pointsHeader(for: sender), "=== STICHPUNKTE VON ANNA ===")
    }

    func testEmptyNameRefersToTheSenderAndHasNoNameLine() {
        let reply = MailReplyPromptBuilder.systemPrompt(customInstruction: "", customTerms: [], sender: anonymous)
        XCTAssertTrue(reply.contains("im Namen des Absenders"))
        XCTAssertTrue(reply.contains("STICHPUNKTE DES ABSENDERS"))
        XCTAssertTrue(reply.contains("ohne Namenszeile"))
        XCTAssertTrue(reply.contains("„Der Absender“ ist die Person, die diktiert"))
        XCTAssertFalse(reply.contains("darunter „"))
        XCTAssertEqual(MailReplyPromptBuilder.pointsHeader(for: anonymous), "=== STICHPUNKTE DES ABSENDERS ===")
        // The sender note also survives a custom instruction.
        let custom = MailReplyPromptBuilder.systemPrompt(customInstruction: "Kurz.", customTerms: [], sender: anonymous)
        XCTAssertTrue(custom.contains("„Der Absender“ ist die Person, die diktiert"))
    }

    func testSenderFallsBackBetweenFirstAndFullName() {
        XCTAssertEqual(MailSender(firstName: "", fullName: "Anna Muster").first, "Anna")
        XCTAssertEqual(MailSender(firstName: "Anna", fullName: "").full, "Anna")
        XCTAssertEqual(MailSender(firstName: "  Anna ", fullName: " Anna Muster ").full, "Anna Muster")
        XCTAssertFalse(MailSender(firstName: " ", fullName: "").isKnown)
    }

    func testUserMessageUsesTheConfiguredFirstNameHeader() {
        let message = MailReplyPromptBuilder.userMessage(context: context, transcript: "Zusage", sender: sender)
        XCTAssertTrue(message.hasSuffix("=== STICHPUNKTE VON ANNA ===\nZusage"))
        let bare = MailReplyPromptBuilder.userMessage(context: context, transcript: "Zusage", sender: anonymous)
        XCTAssertTrue(bare.hasSuffix("=== STICHPUNKTE DES ABSENDERS ===\nZusage"))
    }
}
