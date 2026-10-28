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

    func testMissingKeyMessageIsGerman() {
        XCTAssertEqual(
            AnthropicError.notConfigured.errorDescription,
            "Anthropic API Key fehlt. Bitte in den Einstellungen hinterlegen."
        )
    }
}
