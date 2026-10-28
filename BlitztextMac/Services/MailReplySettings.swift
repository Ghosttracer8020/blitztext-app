import Foundation

// Foundation-only (plus KeyboardShortcut): compiles directly into the test
// target without WorkflowProtocol.swift.

struct MailReplySettings: Codable, Equatable {
    /// Empty = built-in instruction (see MailReplyPromptBuilder).
    var systemPrompt: String = ""
    var customName: String = ""

    init(systemPrompt: String = "", customName: String = "") {
        self.systemPrompt = systemPrompt
        self.customName = customName
    }

    enum CodingKeys: String, CodingKey {
        case systemPrompt
        case customName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        customName = try container.decodeIfPresent(String.self, forKey: .customName) ?? ""
    }
}

/// One-time addition of the Blitztext Mail shortcut (right-Option+M) to
/// shortcut sets stored before the workflow existed.
enum MailReplyShortcutMigration {
    static let workflowID = "mailReply"

    /// Right-Option + M (keyCode 46). 0x40 = NX device bit for the right Option key.
    static let defaultShortcut = KeyboardShortcut(
        keyCode: 46,
        rawModifierFlags: KeyboardShortcut.optionMask | 0x40
    )

    /// - Parameters:
    ///   - stored: shortcuts read from disk; nil if the settings file has none
    ///     (fresh install), in which case `defaults` apply unchanged.
    ///   - alreadyMigrated: persisted flag. Without it a shortcut the user
    ///     cleared on purpose would reappear on every launch, because a
    ///     cleared shortcut and a never-migrated profile look the same.
    /// - Returns: the shortcuts to use and the new value of the flag.
    static func resolve(
        stored: [String: KeyboardShortcut]?,
        alreadyMigrated: Bool,
        defaults: [String: KeyboardShortcut]
    ) -> (shortcuts: [String: KeyboardShortcut], migrated: Bool) {
        guard var shortcuts = stored else {
            return (defaults, true)
        }
        if alreadyMigrated || shortcuts[workflowID] != nil {
            return (shortcuts, true)
        }
        let taken = shortcuts.values.contains {
            $0.keyCode == defaultShortcut.keyCode && $0.modifiers == defaultShortcut.modifiers
        }
        if !taken {
            shortcuts[workflowID] = defaultShortcut
        }
        // Decided either way: never retry, even if the combo is free later.
        return (shortcuts, true)
    }
}
