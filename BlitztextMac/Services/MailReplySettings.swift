import Foundation

// Foundation-only (plus KeyboardShortcut): compiles directly into the test
// target without WorkflowProtocol.swift.

/// Who dictates the mails: used for greeting-independent parts of the prompts
/// (closing name, "Stichpunkte von <Vorname>"). Both parts may be empty.
struct MailSender: Equatable {
    var firstName: String = ""
    var fullName: String = ""

    /// First name; falls back to the first word of the full name.
    var first: String {
        let trimmed = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return fullName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    /// Full name; falls back to the first name.
    var full: String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? first : trimmed
    }

    var isKnown: Bool { !first.isEmpty }
}

struct MailReplySettings: Codable, Equatable {
    /// Empty = built-in instruction (see MailReplyPromptBuilder).
    var systemPrompt: String = ""
    var customName: String = ""
    /// "Dein Name" - empty on a fresh install (see `migratingSenderName`).
    var senderFirstName: String = ""
    var senderFullName: String = ""
    /// True once the one-time prefill for settings that predate the name
    /// fields ran. Without it a name cleared on purpose would be prefilled
    /// again on every launch.
    var senderNameMigrated: Bool = false

    init(
        systemPrompt: String = "",
        customName: String = "",
        senderFirstName: String = "",
        senderFullName: String = "",
        senderNameMigrated: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.customName = customName
        self.senderFirstName = senderFirstName
        self.senderFullName = senderFullName
        self.senderNameMigrated = senderNameMigrated
    }

    enum CodingKeys: String, CodingKey {
        case systemPrompt
        case customName
        case senderFirstName
        case senderFullName
        case senderNameMigrated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        customName = try container.decodeIfPresent(String.self, forKey: .customName) ?? ""
        senderFirstName = try container.decodeIfPresent(String.self, forKey: .senderFirstName) ?? ""
        senderFullName = try container.decodeIfPresent(String.self, forKey: .senderFullName) ?? ""
        senderNameMigrated = try container.decodeIfPresent(Bool.self, forKey: .senderNameMigrated) ?? false
    }

    var sender: MailSender {
        MailSender(firstName: senderFirstName, fullName: senderFullName)
    }

    /// One-time prefill so the original owner's behavior stays unchanged: the
    /// mail prompts used to hardcode "Ben" / "Ben Scheffler". Settings that
    /// existed before the name fields (`settingsFileExists`) belong to him;
    /// a fresh install starts empty and asks for the name.
    static func migratingSenderName(stored: MailReplySettings?, settingsFileExists: Bool) -> MailReplySettings {
        var settings = stored ?? MailReplySettings()
        guard !settings.senderNameMigrated else { return settings }
        settings.senderNameMigrated = true
        if settingsFileExists && settings.senderFirstName.isEmpty && settings.senderFullName.isEmpty {
            settings.senderFirstName = "Ben"
            settings.senderFullName = "Ben Scheffler"
        }
        return settings
    }
}

/// Shared logic of the one-time "add a default shortcut to stored profiles"
/// migrations (one persisted flag per shortcut).
enum ShortcutAdditionMigration {
    /// - Parameters:
    ///   - stored: shortcuts read from disk; nil if the settings file has none
    ///     (fresh install), in which case `defaults` apply unchanged.
    ///   - alreadyMigrated: persisted flag. Without it a shortcut the user
    ///     cleared on purpose would reappear on every launch, because a
    ///     cleared shortcut and a never-migrated profile look the same.
    /// - Returns: the shortcuts to use and the new value of the flag.
    static func resolve(
        id: String,
        defaultShortcut: KeyboardShortcut,
        stored: [String: KeyboardShortcut]?,
        alreadyMigrated: Bool,
        defaults: [String: KeyboardShortcut]
    ) -> (shortcuts: [String: KeyboardShortcut], migrated: Bool) {
        guard var shortcuts = stored else {
            return (defaults, true)
        }
        if alreadyMigrated || shortcuts[id] != nil {
            return (shortcuts, true)
        }
        let taken = shortcuts.values.contains {
            $0.keyCode == defaultShortcut.keyCode && $0.modifiers == defaultShortcut.modifiers
        }
        if !taken {
            shortcuts[id] = defaultShortcut
        }
        // Decided either way: never retry, even if the combo is free later.
        return (shortcuts, true)
    }
}

/// One-time addition of the UltraDic Mail shortcut (right-Option+M) to
/// shortcut sets stored before the workflow existed.
enum MailReplyShortcutMigration {
    static let workflowID = "mailReply"

    /// Right-Option + M (keyCode 46). 0x40 = NX device bit for the right Option key.
    static let defaultShortcut = KeyboardShortcut(
        keyCode: 46,
        rawModifierFlags: KeyboardShortcut.optionMask | 0x40
    )

    static func resolve(
        stored: [String: KeyboardShortcut]?,
        alreadyMigrated: Bool,
        defaults: [String: KeyboardShortcut]
    ) -> (shortcuts: [String: KeyboardShortcut], migrated: Bool) {
        ShortcutAdditionMigration.resolve(
            id: workflowID,
            defaultShortcut: defaultShortcut,
            stored: stored,
            alreadyMigrated: alreadyMigrated,
            defaults: defaults
        )
    }
}

/// One-time addition of the typed UltraDic Mail shortcut (right-Option+N).
/// Not a WorkflowType: it starts the same workflow, but as a single press
/// that opens an input panel instead of recording.
enum MailReplyTypedShortcutMigration {
    static let shortcutID = "mailReplyTyped"

    /// Right-Option + N (keyCode 45).
    static let defaultShortcut = KeyboardShortcut(
        keyCode: 45,
        rawModifierFlags: KeyboardShortcut.optionMask | 0x40
    )

    static func resolve(
        stored: [String: KeyboardShortcut]?,
        alreadyMigrated: Bool,
        defaults: [String: KeyboardShortcut]
    ) -> (shortcuts: [String: KeyboardShortcut], migrated: Bool) {
        ShortcutAdditionMigration.resolve(
            id: shortcutID,
            defaultShortcut: defaultShortcut,
            stored: stored,
            alreadyMigrated: alreadyMigrated,
            defaults: defaults
        )
    }
}
