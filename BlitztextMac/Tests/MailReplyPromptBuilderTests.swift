import XCTest

final class MailReplyPromptBuilderTests: XCTestCase {
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
            MailReplyPromptBuilder.systemPrompt(customInstruction: "  \n ", customTerms: []),
            MailReplyPromptBuilder.defaultSystemPrompt + "\n\n" + MailReplyPromptBuilder.hintContract
        )
    }

    func testCustomInstructionReplacesDefault() {
        let prompt = MailReplyPromptBuilder.systemPrompt(customInstruction: "Antworte kurz.", customTerms: [])
        XCTAssertTrue(prompt.hasPrefix("Antworte kurz."))
        XCTAssertFalse(prompt.contains(MailReplyPromptBuilder.defaultSystemPrompt))
    }

    func testHintContractIsAppendedWithDefaultAndCustomInstruction() {
        for instruction in ["", "Antworte kurz."] {
            let prompt = MailReplyPromptBuilder.systemPrompt(customInstruction: instruction, customTerms: [])
            XCTAssertTrue(prompt.contains(MailReplyPromptBuilder.hintContract))
            XCTAssertTrue(prompt.contains("JSON-Objekt mit zwei Feldern"))
            XCTAssertTrue(prompt.contains("Die Antwort folgt immer Bens Stichpunkten"))
            XCTAssertTrue(prompt.contains("höchstens 5"))
            XCTAssertTrue(prompt.contains("widerspruch"))
            XCTAssertTrue(prompt.contains("schon_beantwortet"))
            XCTAssertTrue(prompt.contains("offen"))
            XCTAssertTrue(prompt.contains("leeres Array"))
        }
    }

    func testDefaultPromptKeepsUnansweredQuestionsOutOfTheReply() {
        XCTAssertFalse(MailReplyPromptBuilder.defaultSystemPrompt.contains("erwähnst du nicht.\n"))
        XCTAssertTrue(MailReplyPromptBuilder.defaultSystemPrompt.contains("Prüfhinweise"))
    }

    func testCustomTermsAreAppended() {
        let prompt = MailReplyPromptBuilder.systemPrompt(customInstruction: "", customTerms: ["ParkourONE", "Blitztext"])
        XCTAssertTrue(prompt.hasPrefix(MailReplyPromptBuilder.defaultSystemPrompt))
        XCTAssertTrue(prompt.contains("ParkourONE, Blitztext"))
        XCTAssertTrue(prompt.contains(MailReplyPromptBuilder.hintContract))
    }

    func testDefaultPromptCarriesTheCoreRules() {
        let prompt = MailReplyPromptBuilder.defaultSystemPrompt
        XCTAssertTrue(prompt.contains("Erfinde nichts dazu"))
        XCTAssertTrue(prompt.contains("kein ausformuliertes Diktat"))
        XCTAssertTrue(prompt.contains("Ordne jeden Stichpunkt der Stelle in ihrer Mail zu"))
        XCTAssertTrue(prompt.contains("Du oder Sie"))
        XCTAssertTrue(prompt.contains("Sprache der letzten eingegangenen Nachricht"))
        XCTAssertTrue(prompt.contains("Antworte auf die Mail"))
        XCTAssertTrue(prompt.contains("darunter „Ben\"."))
        XCTAssertTrue(prompt.contains("darunter „Ben Scheffler\"."))
        XCTAssertTrue(prompt.contains("Keine Signatur"))
        XCTAssertTrue(prompt.contains("Kein Betreff"))
    }

    func testDefaultPromptReferencesTheSectionHeaders() {
        XCTAssertTrue(MailReplyPromptBuilder.defaultSystemPrompt.contains("ORIGINALE MAIL"))
        XCTAssertTrue(MailReplyPromptBuilder.defaultSystemPrompt.contains("STICHPUNKTE VON BEN"))
    }

    func testUserMessageHasDelimitedSectionsInOrder() {
        let message = MailReplyPromptBuilder.userMessage(context: context, transcript: "Antworte auf die Mail: Punkt eins.")
        let mailRange = message.range(of: MailReplyPromptBuilder.originalMailHeader)
        let pointsRange = message.range(of: MailReplyPromptBuilder.pointsHeader)
        XCTAssertNotNil(mailRange)
        XCTAssertNotNil(pointsRange)
        XCTAssertLessThan(mailRange!.lowerBound, pointsRange!.lowerBound)
        XCTAssertTrue(message.hasSuffix("Antworte auf die Mail: Punkt eins."))
    }

    func testUserMessageContainsMailFields() {
        let message = MailReplyPromptBuilder.userMessage(context: context, transcript: "x")
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
        let message = MailReplyPromptBuilder.userMessage(context: bare, transcript: "x")
        XCTAssertFalse(message.contains("An:"))
        XCTAssertFalse(message.contains("Cc:"))
    }
}
