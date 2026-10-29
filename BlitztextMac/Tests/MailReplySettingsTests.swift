import XCTest

final class MailReplySettingsTests: XCTestCase {
    // MARK: - Tolerant decoding

    func testEmptyObjectDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(MailReplySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, MailReplySettings())
        XCTAssertEqual(settings.systemPrompt, "")
        XCTAssertEqual(settings.customName, "")
    }

    func testPartialObjectKeepsKnownFieldsAndIgnoresUnknownOnes() throws {
        let json = #"{"systemPrompt":"Kurz.","somethingNew":42}"#
        let settings = try JSONDecoder().decode(MailReplySettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.systemPrompt, "Kurz.")
        XCTAssertEqual(settings.customName, "")
    }

    func testRoundTrip() throws {
        let original = MailReplySettings(systemPrompt: "A", customName: "Mail")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(MailReplySettings.self, from: data), original)
    }

    // MARK: - Shortcut migration

    private let optionMask = KeyboardShortcut.optionMask
    private let rightOption: UInt64 = 0x40

    private func shortcut(_ keyCode: Int) -> KeyboardShortcut {
        KeyboardShortcut(keyCode: keyCode, rawModifierFlags: optionMask | rightOption)
    }

    private var defaults: [String: KeyboardShortcut] {
        ["transcription": shortcut(40), "mailReply": MailReplyShortcutMigration.defaultShortcut]
    }

    func testDefaultShortcutIsRightOptionM() {
        let value = MailReplyShortcutMigration.defaultShortcut
        XCTAssertEqual(value.keyCode, 46)
        XCTAssertEqual(value.modifiers, optionMask)
        XCTAssertEqual(value.deviceSideBits, rightOption)
        XCTAssertEqual(value, shortcut(46))
    }

    func testFreshInstallGetsDefaultsAsIs() {
        let result = MailReplyShortcutMigration.resolve(stored: nil, alreadyMigrated: false, defaults: defaults)
        XCTAssertEqual(result.shortcuts, defaults)
        XCTAssertTrue(result.migrated)
    }

    func testStoredProfileWithoutMailReplyGetsTheShortcut() {
        let stored = ["transcription": shortcut(40), "textImprover": shortcut(38)]
        let result = MailReplyShortcutMigration.resolve(stored: stored, alreadyMigrated: false, defaults: defaults)
        XCTAssertEqual(result.shortcuts["mailReply"], MailReplyShortcutMigration.defaultShortcut)
        XCTAssertEqual(result.shortcuts["transcription"], shortcut(40))
        XCTAssertEqual(result.shortcuts["textImprover"], shortcut(38))
        XCTAssertEqual(result.shortcuts.count, 3)
        XCTAssertTrue(result.migrated)
    }

    func testExistingMailReplyBindingIsKept() {
        let custom = KeyboardShortcut(keyCode: 12, rawModifierFlags: optionMask | rightOption)
        let result = MailReplyShortcutMigration.resolve(stored: ["mailReply": custom], alreadyMigrated: false, defaults: defaults)
        XCTAssertEqual(result.shortcuts["mailReply"], custom)
        XCTAssertTrue(result.migrated)
    }

    func testConflictingShortcutBlocksTheMigration() {
        // Another workflow already sits on right-Option+M.
        let stored = ["emojiText": shortcut(46)]
        let result = MailReplyShortcutMigration.resolve(stored: stored, alreadyMigrated: false, defaults: defaults)
        XCTAssertNil(result.shortcuts["mailReply"])
        XCTAssertEqual(result.shortcuts["emojiText"], shortcut(46))
        XCTAssertTrue(result.migrated, "decided once, not retried every launch")
    }

    func testSameKeyWithDifferentModifiersDoesNotConflict() {
        let commandM = KeyboardShortcut(keyCode: 46, rawModifierFlags: KeyboardShortcut.commandMask)
        let result = MailReplyShortcutMigration.resolve(stored: ["emojiText": commandM], alreadyMigrated: false, defaults: defaults)
        XCTAssertEqual(result.shortcuts["mailReply"], MailReplyShortcutMigration.defaultShortcut)
    }

    func testLeftOptionMStillCountsAsConflict() {
        // keyCode + modifiers decide; the recorded side does not.
        let leftOptionM = KeyboardShortcut(keyCode: 46, rawModifierFlags: optionMask | 0x20)
        let result = MailReplyShortcutMigration.resolve(stored: ["emojiText": leftOptionM], alreadyMigrated: false, defaults: defaults)
        XCTAssertNil(result.shortcuts["mailReply"])
    }

    func testClearedShortcutIsNotReaddedOnceMigrated() {
        let stored = ["transcription": shortcut(40)]
        let result = MailReplyShortcutMigration.resolve(stored: stored, alreadyMigrated: true, defaults: defaults)
        XCTAssertNil(result.shortcuts["mailReply"])
        XCTAssertTrue(result.migrated)
    }

    func testModifierOnlyBindingsDoNotConflict() {
        let optionAlone = KeyboardShortcut(keyCode: nil, rawModifierFlags: optionMask | rightOption)
        let result = MailReplyShortcutMigration.resolve(stored: ["dampfAblassen": optionAlone], alreadyMigrated: false, defaults: defaults)
        XCTAssertEqual(result.shortcuts["mailReply"], MailReplyShortcutMigration.defaultShortcut)
    }

    // MARK: - Anthropic response parsing

    func testExtractTextJoinsTextBlocks() throws {
        let json = #"{"content":[{"type":"text","text":"Hallo Thomas,\n\n"},{"type":"text","text":"danke."}]}"#
        XCTAssertEqual(try AnthropicService.extractText(from: Data(json.utf8)), "Hallo Thomas,\n\ndanke.")
    }

    func testExtractTextIgnoresNonTextBlocks() throws {
        let json = #"{"content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"Antwort"}]}"#
        XCTAssertEqual(try AnthropicService.extractText(from: Data(json.utf8)), "Antwort")
    }

    func testExtractTextThrowsWithoutContent() {
        XCTAssertThrowsError(try AnthropicService.extractText(from: Data(#"{"content":[]}"#.utf8)))
        XCTAssertThrowsError(try AnthropicService.extractText(from: Data("{}".utf8)))
    }

    // MARK: - Structured reply parsing

    /// Wraps the model's JSON text into a Messages API response.
    private func response(text: String, stopReason: String? = nil) -> Data {
        var object: [String: Any] = ["content": [["type": "text", "text": text]]]
        if let stopReason { object["stop_reason"] = stopReason }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParseReplyReadsStructuredJSON() throws {
        let text = #"{"reply":"Hallo Thomas,\n\nok.","hints":[{"kind":"widerspruch","text":"A"},{"kind":"schon_beantwortet","text":"B"},{"kind":"offen","text":"C"}]}"#
        let result = try AnthropicService.parseReply(from: response(text: text, stopReason: "end_turn"))
        XCTAssertEqual(result.reply, "Hallo Thomas,\n\nok.")
        XCTAssertEqual(result.hints.map(\.kind), [.widerspruch, .schonBeantwortet, .offen])
        XCTAssertEqual(result.hints.map(\.text), ["A", "B", "C"])
    }

    func testParseReplyWithoutHintsFieldGivesNoHints() throws {
        let result = try AnthropicService.parseReply(from: response(text: #"{"reply":"Text"}"#))
        XCTAssertEqual(result, MailReplyResult(reply: "Text", hints: []))
    }

    func testParseReplyDropsUnknownKindsAndEmptyTexts() throws {
        let text = #"{"reply":"Text","hints":[{"kind":"stil","text":"x"},{"kind":"offen","text":"  "},{"kind":"offen"},{"kind":"offen","text":"Frage"}]}"#
        let result = try AnthropicService.parseReply(from: response(text: text))
        XCTAssertEqual(result.hints, [MailReplyHint(kind: .offen, text: "Frage")])
    }

    func testParseReplyKeepsValidHintsAmongMalformedOnes() throws {
        let text = #"{"reply":"Text","hints":["bare",{"kind":5,"text":["x"]},{"kind":" Widerspruch ","text":"Echt"}]}"#
        let result = try AnthropicService.parseReply(from: response(text: text))
        XCTAssertEqual(result.reply, "Text")
        XCTAssertEqual(result.hints, [MailReplyHint(kind: .widerspruch, text: "Echt")])
    }

    func testParseReplyCapsHintsAtFive() throws {
        let hint = #"{"kind":"offen","text":"x"}"#
        let text = #"{"reply":"Text","hints":["# + Array(repeating: hint, count: 7).joined(separator: ",") + #"]}"#
        XCTAssertEqual(try AnthropicService.parseReply(from: response(text: text)).hints.count, 5)
    }

    func testParseReplyJoinsTextBlocksBeforeDecoding() throws {
        let json = #"{"content":[{"type":"text","text":"{\"reply\":\"Te"},{"type":"text","text":"xt\",\"hints\":[]}"}]}"#
        XCTAssertEqual(try AnthropicService.parseReply(from: Data(json.utf8)), MailReplyResult(reply: "Text", hints: []))
    }

    func testParseReplyFallsBackToWholeTextWhenNotJSON() throws {
        let result = try AnthropicService.parseReply(from: response(text: "Nur Text"))
        XCTAssertEqual(result, MailReplyResult(reply: "Nur Text", hints: []))
    }

    func testParseReplyThrowsOnMaxTokens() {
        let json = #"{"reply":"abgeschnitten","hints":[]}"#
        XCTAssertThrowsError(try AnthropicService.parseReply(from: response(text: json, stopReason: "max_tokens"))) { error in
            guard case AnthropicError.truncated = error else { return XCTFail("expected truncated, got \(error)") }
        }
        XCTAssertThrowsError(try AnthropicService.parseReply(from: response(text: "abgeschnitten", stopReason: "max_tokens")))
    }

    func testParseReplyThrowsWithoutAnyContent() {
        XCTAssertThrowsError(try AnthropicService.parseReply(from: Data(#"{"content":[]}"#.utf8)))
    }

    func testRequestUsesStructuredOutputsWithoutTools() throws {
        let payload = AnthropicMessagesRequest(
            model: "m", max_tokens: AnthropicService.maxTokens, system: "s",
            messages: [.init(role: "user", content: "u")],
            output_config: .init(format: .init(schema: AnthropicService.replySchema))
        )
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["tools"])
        XCTAssertNil(object["tool_choice"])
        let format = try XCTUnwrap((object["output_config"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(AnthropicService.maxTokens, 3000)

        // Schema: all objects closed and fully required, enum generated from Kind.
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["reply", "hints"])
        let hints = try XCTUnwrap((schema["properties"] as? [String: Any])?["hints"] as? [String: Any])
        let item = try XCTUnwrap(hints["items"] as? [String: Any])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        XCTAssertEqual(item["required"] as? [String], ["kind", "text"])
        let kind = try XCTUnwrap((item["properties"] as? [String: Any])?["kind"] as? [String: Any])
        XCTAssertEqual(kind["enum"] as? [String], MailReplyHint.Kind.allCases.map(\.rawValue))
    }

    func testMissingKeyMessageIsGerman() {
        XCTAssertEqual(
            AnthropicError.notConfigured.errorDescription,
            "Anthropic API Key fehlt. Bitte in den Einstellungen hinterlegen."
        )
    }
}
