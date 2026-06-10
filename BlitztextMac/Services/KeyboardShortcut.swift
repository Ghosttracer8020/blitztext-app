import Foundation
import CoreGraphics

/// A user-recorded hotkey: a single non-modifier key plus optional modifiers,
/// or a modifier-only shortcut (keyCode == nil) — a single modifier (right
/// Option alone as push-to-talk) or a modifier chord (right Option + right
/// Command). Every modifier keeps its left/right distinction so e.g. a
/// right-Option combo does not block the left Option key's character layer
/// (⌥L = @ on German layouts).
struct KeyboardShortcut: Equatable {
    /// nil = modifier-only shortcut (fires on the modifier state alone)
    var keyCode: Int?
    /// Generic modifier bits (subset of CGEventFlags: ⌘⇧⌥⌃ + fn)
    var modifiers: UInt64
    /// Device-specific left/right bits captured at record time for the
    /// modifiers present in `modifiers`. Exactly one recorded side of a
    /// modifier means that physical key is required; none or both = any side.
    var deviceSideBits: UInt64

    var isModifierOnly: Bool { keyCode == nil }

    /// Marker on synthetic CGEvents posted by this app (e.g. the auto-paste
    /// Cmd+V) so the hotkey tap never matches or swallows its own events.
    static let syntheticEventTag: Int64 = 0x424C_5A54 // "BLZT"

    static let commandMask: UInt64 = 0x10_0000  // CGEventFlags.maskCommand
    static let shiftMask: UInt64 = 0x2_0000     // .maskShift
    static let optionMask: UInt64 = 0x8_0000    // .maskAlternate
    static let controlMask: UInt64 = 0x4_0000   // .maskControl
    static let fnMask: UInt64 = 0x80_0000       // .maskSecondaryFn
    static let genericMask: UInt64 =
        commandMask | shiftMask | optionMask | controlMask | fnMask

    /// NX device-dependent bits: left/right physical key per modifier.
    static let sidePairs: [(generic: UInt64, left: UInt64, right: UInt64, symbol: String)] = [
        (controlMask, 0x0001, 0x2000, "\u{2303}"),
        (shiftMask, 0x0002, 0x0004, "\u{21E7}"),
        (optionMask, 0x0020, 0x0040, "\u{2325}"),
        (commandMask, 0x0008, 0x0010, "\u{2318}"),
    ]

    /// Keys for which macOS sets the fn flag implicitly (F-keys, arrows,
    /// navigation block). The flag is unreliable across keyboards there, so
    /// it is stripped at capture and ignored at match time.
    static let impliedFnKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1-F12
        123, 124, 125, 126,                                     // arrows
        115, 116, 117, 119, 121,                                // nav block
    ]

    init(keyCode: Int?, rawModifierFlags: UInt64) {
        self.keyCode = keyCode
        var generic = rawModifierFlags & Self.genericMask
        if let keyCode, Self.impliedFnKeyCodes.contains(keyCode) {
            generic &= ~Self.fnMask
        }
        self.modifiers = generic
        var sides: UInt64 = 0
        for pair in Self.sidePairs where generic & pair.generic != 0 {
            sides |= rawModifierFlags & (pair.left | pair.right)
        }
        self.deviceSideBits = sides
    }

    /// Exact match for a keyDown: same key, exactly the recorded modifier set.
    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard let ownKeyCode = self.keyCode, keyCode == Int64(ownKeyCode) else { return false }
        var relevantMask = Self.genericMask
        if Self.impliedFnKeyCodes.contains(ownKeyCode) {
            relevantMask &= ~Self.fnMask
        }
        guard flags.rawValue & relevantMask == modifiers else { return false }
        return sidesSatisfied(by: flags)
    }

    /// Exact match for a modifier-only shortcut against the current flag
    /// state: exactly the recorded modifier set, nothing more.
    func matchesModifierState(_ flags: CGEventFlags) -> Bool {
        guard isModifierOnly, modifiers != 0 else { return false }
        guard flags.rawValue & Self.genericMask == modifiers else { return false }
        return sidesSatisfied(by: flags)
    }

    /// Whether the recorded modifiers are still held (combo-end detection).
    /// A shortcut without modifiers never ends via flagsChanged. Additional
    /// modifiers joining do NOT end the combo: an accidental Shift brush
    /// mid-dictation must not stop a hold-mode recording.
    func requiredModifiersStillHeld(_ flags: CGEventFlags) -> Bool {
        guard modifiers != 0 else { return true }
        guard flags.rawValue & modifiers == modifiers else { return false }
        return sidesSatisfied(by: flags)
    }

    private func sidesSatisfied(by flags: CGEventFlags) -> Bool {
        for pair in Self.sidePairs where modifiers & pair.generic != 0 {
            let recorded = deviceSideBits & (pair.left | pair.right)
            // Exactly one recorded side -> that physical key must be down
            if recorded == pair.left || recorded == pair.right {
                if flags.rawValue & recorded == 0 { return false }
            }
        }
        return true
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers & Self.fnMask != 0 { parts.append("fn") }
        for pair in Self.sidePairs where modifiers & pair.generic != 0 {
            let recorded = deviceSideBits & (pair.left | pair.right)
            switch recorded {
            case pair.left: parts.append("\(pair.symbol)L")
            case pair.right: parts.append("\(pair.symbol)R")
            default: parts.append(pair.symbol)
            }
        }
        if let keyCode {
            parts.append(Self.keyName(for: keyCode))
        }
        return parts.joined(separator: " ")
    }

    /// Display names for common ANSI virtual key codes. Letter positions
    /// match QWERTZ except Y/Z, which are swapped vs. the printed label.
    static func keyName(for keyCode: Int) -> String {
        if let name = keyNames[keyCode] { return name }
        return "#\(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        49: "Space", 36: "\u{21A9}", 48: "\u{21E5}",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        117: "\u{2326}", 115: "\u{2196}", 119: "\u{2198}", 116: "\u{21DE}", 121: "\u{21DF}",
        47: ".", 43: ",", 44: "/", 41: ";", 39: "'", 27: "-", 24: "=",
        33: "[", 30: "]", 42: "\\", 50: "`", 10: "\u{00A7}",
    ]
}

extension KeyboardShortcut: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case deviceSideBits
        /// Legacy key from the Option-only side-distinction iteration.
        case optionSideBits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decodeIfPresent(Int.self, forKey: .keyCode)
        modifiers = try container.decodeIfPresent(UInt64.self, forKey: .modifiers) ?? 0
        deviceSideBits = try container.decodeIfPresent(UInt64.self, forKey: .deviceSideBits)
            ?? container.decodeIfPresent(UInt64.self, forKey: .optionSideBits)
            ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(deviceSideBits, forKey: .deviceSideBits)
    }
}
