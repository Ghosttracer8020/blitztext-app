import XCTest

final class BuiltInHotkeysTests: XCTestCase {
    private let commandMask = KeyboardShortcut.commandMask
    private let shiftMask = KeyboardShortcut.shiftMask
    private let optionMask = KeyboardShortcut.optionMask
    private let controlMask = KeyboardShortcut.controlMask
    private let fnMask = KeyboardShortcut.fnMask
    private let leftCommand: UInt64 = 0x08
    private let rightCommand: UInt64 = 0x10
    private let rightOption: UInt64 = 0x40
    private let rightControl: UInt64 = 0x2000

    private func activeIDs(_ shortcuts: [String: KeyboardShortcut]) -> Set<String> {
        Set(BuiltInHotkey.active(customShortcuts: shortcuts).map(\.workflowID))
    }

    private func hotkey(_ workflowID: String) -> BuiltInHotkey {
        guard let hotkey = BuiltInHotkey.hotkey(forWorkflowID: workflowID) else {
            preconditionFailure("no built-in hotkey for \(workflowID)")
        }
        return hotkey
    }

    // MARK: - Table

    func testAllSixBuiltInsHaveExpectedIDsModifiersAndLabels() {
        let expected: [(String, UInt64, String)] = [
            ("transcription", fnMask | shiftMask, "fn + Shift"),
            ("localTranscription", fnMask | shiftMask | controlMask, "fn + Shift + Ctrl"),
            ("textImprover", fnMask | controlMask, "fn + Control"),
            ("dampfAblassen", fnMask | optionMask, "fn + Option"),
            ("emojiText", fnMask | commandMask, "fn + Cmd"),
            ("promptText", fnMask | shiftMask | commandMask, "fn + Shift + Cmd"),
        ]
        XCTAssertEqual(BuiltInHotkey.all.count, expected.count)
        for (id, modifiers, label) in expected {
            let entry = hotkey(id)
            XCTAssertEqual(entry.modifiers, modifiers, "modifiers for \(id)")
            XCTAssertEqual(entry.label, label, "label for \(id)")
        }
    }

    func testNoCustomShortcutsLeavesAllBuiltInsActive() {
        XCTAssertEqual(BuiltInHotkey.active(customShortcuts: [:]).count, 6)
        for entry in BuiltInHotkey.all {
            XCTAssertNil(BuiltInHotkey.claimant(of: entry, in: [:]), "\(entry.workflowID) must be unclaimed")
        }
    }

    // MARK: - Ben's stored settings (the reported bug)

    /// promptText is recorded as fn + left Command, which is exactly the
    /// emoji built-in's modifier set — without the claim rule both fired and
    /// the built-in won the race.
    func testBensShortcutsClaimOnlyTheEmojiBuiltIn() {
        let shortcuts: [String: KeyboardShortcut] = [
            "promptText": KeyboardShortcut(keyCode: nil, rawModifierFlags: fnMask | commandMask | leftCommand),
            "emojiText": KeyboardShortcut(keyCode: 44, rawModifierFlags: commandMask | rightCommand),
            "transcription": KeyboardShortcut(
                keyCode: nil,
                rawModifierFlags: commandMask | optionMask | rightOption | rightCommand
            ),
            "textImprover": KeyboardShortcut(keyCode: nil, rawModifierFlags: optionMask | rightOption),
            "dampfAblassen": KeyboardShortcut(
                keyCode: nil,
                rawModifierFlags: optionMask | controlMask | rightOption | rightControl
            ),
        ]

        XCTAssertEqual(
            BuiltInHotkey.claimant(of: hotkey("emojiText"), in: shortcuts),
            "promptText",
            "fn + \u{2318} is claimed by the prompt workflow"
        )
        XCTAssertEqual(
            activeIDs(shortcuts),
            ["transcription", "localTranscription", "textImprover", "dampfAblassen", "promptText"],
            "the other five built-ins stay active"
        )
    }

    // MARK: - Claim rule

    func testKeyedShortcutWithSameModifiersClaimsBuiltIn() {
        let shortcuts = ["textImprover": KeyboardShortcut(keyCode: 40, rawModifierFlags: fnMask | commandMask)] // fn+Cmd+K
        XCTAssertEqual(BuiltInHotkey.claimant(of: hotkey("emojiText"), in: shortcuts), "textImprover")
        XCTAssertFalse(activeIDs(shortcuts).contains("emojiText"))
    }

    func testCommandOnlyShortcutClaimsNothing() {
        let shortcuts = ["emojiText": KeyboardShortcut(keyCode: 44, rawModifierFlags: commandMask | rightCommand)]
        XCTAssertEqual(BuiltInHotkey.active(customShortcuts: shortcuts).count, 6, "no built-in uses \u{2318} alone")
    }

    func testDeviceSideBitsAreIgnoredForClaiming() {
        let left = ["promptText": KeyboardShortcut(keyCode: nil, rawModifierFlags: fnMask | commandMask | leftCommand)]
        let right = ["promptText": KeyboardShortcut(keyCode: nil, rawModifierFlags: fnMask | commandMask | rightCommand)]
        XCTAssertEqual(BuiltInHotkey.claimant(of: hotkey("emojiText"), in: left), "promptText")
        XCTAssertEqual(BuiltInHotkey.claimant(of: hotkey("emojiText"), in: right), "promptText")
    }

    func testWorkflowRecordingItsOwnBuiltInComboClaimsIt() {
        let shortcuts = [
            "promptText": KeyboardShortcut(keyCode: nil, rawModifierFlags: fnMask | shiftMask | commandMask),
        ]
        XCTAssertEqual(
            BuiltInHotkey.claimant(of: hotkey("promptText"), in: shortcuts),
            "promptText",
            "the combo must not fire through both hotkey systems"
        )
        XCTAssertFalse(activeIDs(shortcuts).contains("promptText"))
    }

    func testOwnWorkflowWinsOverAlphabeticallyEarlierClaimant() {
        let shortcuts = [
            "promptText": KeyboardShortcut(keyCode: nil, rawModifierFlags: fnMask | shiftMask | commandMask),
            "dampfAblassen": KeyboardShortcut(keyCode: 40, rawModifierFlags: fnMask | shiftMask | commandMask),
        ]
        XCTAssertEqual(BuiltInHotkey.claimant(of: hotkey("promptText"), in: shortcuts), "promptText")
    }

    func testLowestIDWinsWhenSeveralForeignWorkflowsClaim() {
        let shortcuts = [
            "textImprover": KeyboardShortcut(keyCode: 40, rawModifierFlags: fnMask | commandMask),
            "dampfAblassen": KeyboardShortcut(keyCode: 38, rawModifierFlags: fnMask | commandMask),
        ]
        XCTAssertEqual(BuiltInHotkey.claimant(of: hotkey("emojiText"), in: shortcuts), "dampfAblassen")
    }

    func testExtraModifierDoesNotClaim() {
        let shortcuts = [
            "promptText": KeyboardShortcut(keyCode: nil, rawModifierFlags: fnMask | commandMask | optionMask),
        ]
        XCTAssertEqual(BuiltInHotkey.active(customShortcuts: shortcuts).count, 6, "fn+\u{2318}+\u{2325} is a different set")
    }
}
