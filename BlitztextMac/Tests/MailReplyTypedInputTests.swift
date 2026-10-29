import XCTest

final class MailReplyTypedInputTests: XCTestCase {
    // MARK: - Sender display name

    func testNameWithAddress() {
        XCTAssertEqual(MailSenderName.displayName(from: "Max Muster <max@example.com>"), "Max Muster")
    }

    func testQuotedLastFirstName() {
        XCTAssertEqual(MailSenderName.displayName(from: "\"Muster, Max\" <max@example.com>"), "Muster, Max")
    }

    func testSingleQuotedName() {
        XCTAssertEqual(MailSenderName.displayName(from: "'Max Muster' <max@example.com>"), "Max Muster")
    }

    func testAddressOnlyInBrackets() {
        XCTAssertEqual(MailSenderName.displayName(from: "<max@example.com>"), "max@example.com")
    }

    func testBareAddress() {
        XCTAssertEqual(MailSenderName.displayName(from: "max@example.com"), "max@example.com")
    }

    func testBlankInput() {
        XCTAssertEqual(MailSenderName.displayName(from: "  \n "), "")
    }

    func testWhitespaceAroundNameAndUmlauts() {
        XCTAssertEqual(MailSenderName.displayName(from: "  Jürgen Müller   <j@example.com>  "), "Jürgen Müller")
    }

    func testNameContainingAngleBracketUsesLastOne() {
        XCTAssertEqual(MailSenderName.displayName(from: "Max <Chef> <max@example.com>"), "Max <Chef>")
    }

    // MARK: - Title

    func testTitleWithName() {
        XCTAssertEqual(MailReplyTypedInput.title(sender: "Anna <a@b.de>"), "Antwort an Anna")
    }

    func testTitleWithoutSender() {
        XCTAssertEqual(MailReplyTypedInput.title(sender: ""), "Antwort verfassen")
    }

    // MARK: - Submit gate

    func testBlankTextCannotBeSubmitted() {
        XCTAssertFalse(MailReplyTypedInput.canSubmit(""))
        XCTAssertFalse(MailReplyTypedInput.canSubmit(" \n\t "))
        XCTAssertTrue(MailReplyTypedInput.canSubmit("zusagen"))
        XCTAssertEqual(MailReplyTypedInput.trimmed("  ja\n"), "ja")
    }

    // MARK: - Key decision

    func testEnterSubmits() {
        XCTAssertEqual(MailReplyInputKey.action(keyCode: 36, shiftHeld: false, hasMarkedText: false), .submit)
        XCTAssertEqual(MailReplyInputKey.action(keyCode: 76, shiftHeld: false, hasMarkedText: false), .submit)
    }

    func testShiftEnterInsertsNewline() {
        XCTAssertEqual(MailReplyInputKey.action(keyCode: 36, shiftHeld: true, hasMarkedText: false), .insertNewline)
        XCTAssertEqual(MailReplyInputKey.action(keyCode: 76, shiftHeld: true, hasMarkedText: false), .insertNewline)
    }

    func testEscapeCancels() {
        XCTAssertEqual(MailReplyInputKey.action(keyCode: 53, shiftHeld: false, hasMarkedText: false), .cancel)
    }

    func testOtherKeysPassThrough() {
        XCTAssertEqual(MailReplyInputKey.action(keyCode: 0, shiftHeld: false, hasMarkedText: false), .passThrough)
    }

    func testKeysBelongToInputMethodWhileComposing() {
        XCTAssertEqual(MailReplyInputKey.action(keyCode: 36, shiftHeld: false, hasMarkedText: true), .passThrough)
        XCTAssertEqual(MailReplyInputKey.action(keyCode: 53, shiftHeld: false, hasMarkedText: true), .passThrough)
    }

    // MARK: - Shortcut migration

    private let rightOption: UInt64 = 0x40

    private func shortcut(_ keyCode: Int) -> KeyboardShortcut {
        KeyboardShortcut(keyCode: keyCode, rawModifierFlags: KeyboardShortcut.optionMask | rightOption)
    }

    private var defaults: [String: KeyboardShortcut] {
        ["transcription": shortcut(40), MailReplyTypedShortcutMigration.shortcutID: MailReplyTypedShortcutMigration.defaultShortcut]
    }

    func testTypedDefaultIsRightOptionN() {
        let value = MailReplyTypedShortcutMigration.defaultShortcut
        XCTAssertEqual(value.keyCode, 45)
        XCTAssertEqual(value.modifiers, KeyboardShortcut.optionMask)
        XCTAssertEqual(value.deviceSideBits, rightOption)
        XCTAssertEqual(MailReplyTypedShortcutMigration.shortcutID, "mailReplyTyped")
    }

    func testFreshInstallGetsTypedDefault() {
        let result = MailReplyTypedShortcutMigration.resolve(stored: nil, alreadyMigrated: false, defaults: defaults)
        XCTAssertEqual(result.shortcuts, defaults)
        XCTAssertTrue(result.migrated)
    }

    func testStoredProfileGetsTypedShortcut() {
        let stored = ["transcription": shortcut(40), "mailReply": shortcut(46)]
        let result = MailReplyTypedShortcutMigration.resolve(stored: stored, alreadyMigrated: false, defaults: defaults)
        XCTAssertEqual(result.shortcuts["mailReplyTyped"], MailReplyTypedShortcutMigration.defaultShortcut)
        XCTAssertEqual(result.shortcuts.count, 3)
        XCTAssertTrue(result.migrated)
    }

    func testTypedMigrationSkipsWhenKeyComboTaken() {
        let stored = ["emojiText": shortcut(45)]
        let result = MailReplyTypedShortcutMigration.resolve(stored: stored, alreadyMigrated: false, defaults: defaults)
        XCTAssertNil(result.shortcuts["mailReplyTyped"])
        XCTAssertEqual(result.shortcuts, stored)
        XCTAssertTrue(result.migrated)
    }

    func testTypedMigrationRunsOnlyOnce() {
        let stored = ["transcription": shortcut(40)]
        let result = MailReplyTypedShortcutMigration.resolve(stored: stored, alreadyMigrated: true, defaults: defaults)
        XCTAssertNil(result.shortcuts["mailReplyTyped"], "cleared on purpose must stay cleared")
        XCTAssertTrue(result.migrated)
    }

    func testExistingTypedShortcutIsKept() {
        let custom = shortcut(12)
        let result = MailReplyTypedShortcutMigration.resolve(
            stored: ["mailReplyTyped": custom], alreadyMigrated: false, defaults: defaults
        )
        XCTAssertEqual(result.shortcuts["mailReplyTyped"], custom)
    }
}
