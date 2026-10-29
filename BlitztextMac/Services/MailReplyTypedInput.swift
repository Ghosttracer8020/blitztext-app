import Foundation

// Pure helpers of the typed Blitztext Mail input panel. Foundation-only:
// compiles into the test target.

enum MailSenderName {
    /// Display name of a sender as Mail returns it: `Name <addr>`,
    /// `"Last, First" <addr>`, `<addr>` or a bare address. Falls back to the
    /// address when there is no name, and to "" for blank input.
    static func displayName(from sender: String) -> String {
        let text = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        guard let open = text.lastIndex(of: "<") else { return text }

        let name = unquote(String(text[..<open]))
        if !name.isEmpty { return name }

        let afterOpen = text[text.index(after: open)...]
        let address = afterOpen
            .prefix(while: { $0 != ">" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? text : address
    }

    private static func unquote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "'"]
        while let first = value.first, let last = value.last,
              value.count >= 2, first == last, quotes.contains(first) {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.replacingOccurrences(of: "\\\"", with: "\"")
    }
}

enum MailReplyTypedInput {
    static let placeholder = "Stichpunkte f\u{00FC}r die Antwort \u{2026}"
    static let hint = "Enter: formulieren \u{00B7} \u{21E7}Enter: neue Zeile \u{00B7} Esc: abbrechen"
    static let windowGoneMessage =
        "Antwortfenster nicht mehr offen \u{2013} Text liegt in der Zwischenablage."

    static func title(sender: String) -> String {
        let name = MailSenderName.displayName(from: sender)
        return name.isEmpty ? "Antwort verfassen" : "Antwort an \(name)"
    }

    /// Title for a new mail: "Neue Mail an Anna" (first recipient), else "Neue Mail".
    static func composeTitle(recipients: [String]) -> String {
        guard let first = recipients.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return "Neue Mail verfassen"
        }
        let more = recipients.count > 1 ? " u. a." : ""
        return "Neue Mail an \(first.trimmingCharacters(in: .whitespaces))\(more)"
    }

    /// Only text with content may be submitted.
    static func canSubmit(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MailReplyInputKey {
    enum Action: Equatable {
        case submit
        case insertNewline
        case cancel
        /// Not ours: let the text view handle the key.
        case passThrough
    }

    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
    static let escapeKeyCode: UInt16 = 53

    /// - Parameter hasMarkedText: an input method composition is in progress
    ///   (Enter confirms it, Esc aborts it) - the keys belong to the IME then.
    static func action(keyCode: UInt16, shiftHeld: Bool, hasMarkedText: Bool) -> Action {
        if hasMarkedText { return .passThrough }
        switch keyCode {
        case returnKeyCode, keypadEnterKeyCode:
            return shiftHeld ? .insertNewline : .submit
        case escapeKeyCode:
            return .cancel
        default:
            return .passThrough
        }
    }
}
