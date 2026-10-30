import XCTest

final class PromptTextPromptBuilderTests: XCTestCase {
    func testDefaultPromptDescribesNumberedListAndForbidsInventing() {
        let prompt = PromptTextPromptBuilder.systemPrompt(
            customInstruction: "",
            outputLanguage: .spoken,
            customTerms: []
        )
        XCTAssertTrue(prompt.contains("nummerierte Liste"))
        XCTAssertTrue(prompt.contains("Erfinde nichts"))
    }

    func testCustomInstructionReplacesDefaultEntirely() {
        let prompt = PromptTextPromptBuilder.systemPrompt(
            customInstruction: "Formuliere Prompts immer fuer Claude Code.",
            outputLanguage: .spoken,
            customTerms: []
        )
        XCTAssertTrue(prompt.hasPrefix("Formuliere Prompts immer fuer Claude Code."))
        XCTAssertFalse(prompt.contains("nummerierte Liste"))
        XCTAssertFalse(prompt.contains(PromptTextPromptBuilder.defaultSystemPrompt))
    }

    func testWhitespaceOnlyInstructionCountsAsEmpty() {
        let prompt = PromptTextPromptBuilder.systemPrompt(
            customInstruction: "   \n\t  ",
            outputLanguage: .spoken,
            customTerms: []
        )
        XCTAssertTrue(prompt.hasPrefix(PromptTextPromptBuilder.defaultSystemPrompt))
    }

    func testEnglishAppendsInstructionEvenWithCustomBase() {
        let defaultPrompt = PromptTextPromptBuilder.systemPrompt(
            customInstruction: "",
            outputLanguage: .english,
            customTerms: []
        )
        XCTAssertTrue(defaultPrompt.contains("Schreibe den fertigen Prompt auf Englisch"))

        let customPrompt = PromptTextPromptBuilder.systemPrompt(
            customInstruction: "Eigene Anweisung.",
            outputLanguage: .english,
            customTerms: []
        )
        XCTAssertTrue(customPrompt.hasPrefix("Eigene Anweisung."))
        XCTAssertTrue(customPrompt.contains("Schreibe den fertigen Prompt auf Englisch"))
    }

    func testCustomTermsAreAppended() {
        let prompt = PromptTextPromptBuilder.systemPrompt(
            customInstruction: "",
            outputLanguage: .spoken,
            customTerms: ["ParkourONE", "Blitztext"]
        )
        XCTAssertTrue(prompt.contains("ParkourONE, Blitztext"))
        XCTAssertTrue(prompt.contains("Wichtig: Diese Eigennamen und Fachbegriffe"))
    }

    func testEmptyCustomTermsAppendNothing() {
        let withEmptyTerms = PromptTextPromptBuilder.systemPrompt(
            customInstruction: "",
            outputLanguage: .spoken,
            customTerms: []
        )
        XCTAssertEqual(withEmptyTerms, AddressingRule.appended(to: PromptTextPromptBuilder.defaultSystemPrompt))
        XCTAssertFalse(withEmptyTerms.contains("Wichtig: Diese Eigennamen"))
    }
}

final class AddressingRuleTests: XCTestCase {
    func testRuleForbidsSwitchingToSieAndKeepsDuForAI() {
        XCTAssertTrue(AddressingRule.text.contains("nie von „du\"/„ihr\" zu „Sie\""))
        XCTAssertTrue(AddressingRule.text.contains("Claude wird immer geduzt"))
        XCTAssertTrue(AddressingRule.text.contains("bedeutet nicht „Sie\""))
    }

    func testAppendedKeepsPromptAndAddsRuleAtEnd() {
        let result = AddressingRule.appended(to: "Eigener Prompt.")
        XCTAssertTrue(result.hasPrefix("Eigener Prompt."))
        XCTAssertTrue(result.hasSuffix(AddressingRule.text))
    }

    func testPromptTextAppendsRuleWithAndWithoutCustomInstruction() {
        for instruction in ["", "Formuliere Prompts immer fuer Claude Code."] {
            for language in [PromptOutputLanguage.spoken, .english] {
                let prompt = PromptTextPromptBuilder.systemPrompt(
                    customInstruction: instruction,
                    outputLanguage: language,
                    customTerms: ["Blitztext"]
                )
                XCTAssertTrue(prompt.hasSuffix(AddressingRule.text), "instruction=\(instruction) language=\(language)")
            }
        }
    }
}
