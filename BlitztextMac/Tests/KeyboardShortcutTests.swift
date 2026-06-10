import XCTest
import CoreGraphics

final class KeyboardShortcutTests: XCTestCase {
    private let optionMask = KeyboardShortcut.optionMask
    private let commandMask = KeyboardShortcut.commandMask
    private let shiftMask = KeyboardShortcut.shiftMask
    private let fnMask = KeyboardShortcut.fnMask
    private let leftOption: UInt64 = 0x20
    private let rightOption: UInt64 = 0x40
    private let leftCommand: UInt64 = 0x08
    private let rightCommand: UInt64 = 0x10

    private func flags(_ raw: UInt64) -> CGEventFlags {
        CGEventFlags(rawValue: raw)
    }

    // MARK: - Keyed matching

    func testKeyedShortcutMatchesExactModifiers() {
        let shortcut = KeyboardShortcut(keyCode: 40, rawModifierFlags: optionMask | rightOption) // rAlt+K
        XCTAssertTrue(shortcut.matches(keyCode: 40, flags: flags(optionMask | rightOption)))
        XCTAssertFalse(shortcut.matches(keyCode: 38, flags: flags(optionMask | rightOption)), "wrong key")
        XCTAssertFalse(shortcut.matches(keyCode: 40, flags: flags(optionMask | commandMask | rightOption)), "extra modifier")
        XCTAssertFalse(shortcut.matches(keyCode: 40, flags: flags(0)), "no modifiers")
    }

    func testRightOptionSideIsRequired() {
        let shortcut = KeyboardShortcut(keyCode: 40, rawModifierFlags: optionMask | rightOption)
        XCTAssertFalse(shortcut.matches(keyCode: 40, flags: flags(optionMask | leftOption)), "left Option must not trigger")
        XCTAssertTrue(shortcut.matches(keyCode: 40, flags: flags(optionMask | rightOption)))
    }

    func testBothOptionSidesRecordedMatchesEitherSide() {
        let shortcut = KeyboardShortcut(keyCode: 40, rawModifierFlags: optionMask | leftOption | rightOption)
        XCTAssertTrue(shortcut.matches(keyCode: 40, flags: flags(optionMask | leftOption)))
        XCTAssertTrue(shortcut.matches(keyCode: 40, flags: flags(optionMask | rightOption)))
    }

    func testBareKeyShortcutMatchesWithoutModifiers() {
        let shortcut = KeyboardShortcut(keyCode: 96, rawModifierFlags: 0) // F5
        XCTAssertTrue(shortcut.matches(keyCode: 96, flags: flags(0)))
        XCTAssertFalse(shortcut.matches(keyCode: 96, flags: flags(commandMask)))
    }

    // MARK: - Implied fn normalization (F-keys, arrows)

    func testImpliedFnIsStrippedAtCaptureAndIgnoredAtMatch() {
        // macOS sets the fn flag on F-key keyDowns implicitly
        let shortcut = KeyboardShortcut(keyCode: 96, rawModifierFlags: fnMask) // F5 captured with fn
        XCTAssertEqual(shortcut.modifiers, 0, "implied fn must be stripped")
        XCTAssertTrue(shortcut.matches(keyCode: 96, flags: flags(fnMask)), "matches with fn flag present")
        XCTAssertTrue(shortcut.matches(keyCode: 96, flags: flags(0)), "matches without fn flag")
    }

    func testImpliedFnDoesNotEndHoldViaFlagsChanged() {
        let shortcut = KeyboardShortcut(keyCode: 96, rawModifierFlags: fnMask)
        // While F5 is held, flagsChanged events carry no fn bit
        XCTAssertTrue(shortcut.requiredModifiersStillHeld(flags(0)))
    }

    // MARK: - Modifier-only shortcuts

    func testModifierOnlyMatchesExactState() {
        let shortcut = KeyboardShortcut(keyCode: nil, rawModifierFlags: optionMask | rightOption)
        XCTAssertTrue(shortcut.isModifierOnly)
        XCTAssertTrue(shortcut.matchesModifierState(flags(optionMask | rightOption)))
        XCTAssertFalse(shortcut.matchesModifierState(flags(optionMask | leftOption)), "wrong side")
        XCTAssertFalse(shortcut.matchesModifierState(flags(optionMask | commandMask | rightOption)), "superset state")
        XCTAssertFalse(shortcut.matchesModifierState(flags(0)))
    }

    func testModifierChordMatchesBothSides() {
        let chord = KeyboardShortcut(
            keyCode: nil,
            rawModifierFlags: optionMask | commandMask | rightOption | rightCommand
        )
        XCTAssertTrue(chord.matchesModifierState(flags(optionMask | commandMask | rightOption | rightCommand)))
        XCTAssertFalse(
            chord.matchesModifierState(flags(optionMask | commandMask | rightOption | leftCommand)),
            "left Command must not satisfy a right-Command chord"
        )
    }

    func testRequiredModifiersStillHeldToleratesExtraModifiers() {
        // Accidental Shift brush mid-dictation must not end the combo
        let shortcut = KeyboardShortcut(keyCode: nil, rawModifierFlags: optionMask | rightOption)
        XCTAssertTrue(shortcut.requiredModifiersStillHeld(flags(optionMask | shiftMask | rightOption)))
        XCTAssertFalse(shortcut.requiredModifiersStillHeld(flags(shiftMask)), "option released")
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = KeyboardShortcut(
            keyCode: nil,
            rawModifierFlags: optionMask | commandMask | rightOption | rightCommand
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLegacyOptionSideBitsDecodesIntoDeviceSideBits() throws {
        let legacyJSON = #"{"keyCode":40,"modifiers":524288,"optionSideBits":64}"#
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.keyCode, 40)
        XCTAssertEqual(decoded.modifiers, optionMask)
        XCTAssertEqual(decoded.deviceSideBits, rightOption)
        XCTAssertTrue(decoded.matches(keyCode: 40, flags: flags(optionMask | rightOption)))
    }

    // MARK: - Display

    func testDisplayString() {
        XCTAssertEqual(
            KeyboardShortcut(keyCode: 40, rawModifierFlags: optionMask | rightOption).displayString,
            "\u{2325}R K"
        )
        XCTAssertEqual(
            KeyboardShortcut(keyCode: nil, rawModifierFlags: optionMask | commandMask | rightOption | rightCommand).displayString,
            "\u{2325}R \u{2318}R"
        )
        XCTAssertEqual(
            KeyboardShortcut(keyCode: 96, rawModifierFlags: fnMask).displayString,
            "F5"
        )
    }
}
