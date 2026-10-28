import AppKit
import ApplicationServices
import os

private let mailContextLogger = Logger(subsystem: "app.blitztext.mac", category: "MailContext")

/// The mail Blitztext Mail answers, as read from Apple Mail.
struct MailContext: Equatable {
    var subject: String
    var sender: String
    var dateReceived: String
    /// Plain text, includes quoted history. Already truncated.
    var content: String
    var toRecipients: [String] = []
    var ccRecipients: [String] = []
}

enum MailContextError: LocalizedError, Equatable {
    case notMail
    case automationDenied
    case noSelection
    case subjectMismatch(window: String, selected: String)
    case scriptFailed(Int)
    case mailNotResponding
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notMail:
            return "Blitztext Mail funktioniert nur in Apple Mail."
        case .automationDenied:
            return "Blitztext darf Mail nicht steuern. Bitte unter Systemeinstellungen \u{2192} Datenschutz & Sicherheit \u{2192} Automation freigeben."
        case .noSelection:
            return "In Mail ist keine Nachricht markiert. Markiere die Mail, auf die du antwortest, im Postfach."
        case .subjectMismatch(let window, let selected):
            return "Die markierte Mail (\u{201E}\(selected)\u{201C}) passt nicht zum Antwortfenster (\u{201E}\(window)\u{201C}). Markiere im Postfach die Mail, auf die du antwortest."
        case .scriptFailed(let code):
            return "Die markierte Mail konnte nicht gelesen werden (Mail-Fehler \(code))."
        case .mailNotResponding:
            return "Mail antwortet nicht. Bitte Mail pr\u{00FC}fen und nochmal versuchen."
        case .unreadable:
            return "Die markierte Mail konnte nicht gelesen werden."
        }
    }
}

/// Reads the reply window title (Accessibility API) and the selected message
/// (AppleScript) from Apple Mail. Subject matching, normalization and
/// truncation are pure functions so they can be tested without Mail.
enum MailContextService {
    static let mailBundleIdentifier = "com.apple.mail"
    /// Upper bound for the quoted thread sent to the model.
    static let maxContentCharacters = 40_000

    // MARK: - Pure helpers

    /// Strips repeated reply/forward prefixes ("Re:", "AW:", "Fwd:", "Fw:",
    /// "WG:", any case), collapses whitespace, trims.
    static func normalizeSubject(_ subject: String) -> String {
        var text = collapseWhitespace(subject)
        while let range = text.range(
            of: #"^(re|aw|fwd|fw|wg)\s*:\s*"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            text.removeSubrange(range)
        }
        return collapseWhitespace(text)
    }

    static func subjectsMatch(windowTitle: String, selectedSubject: String) -> Bool {
        let window = normalizeSubject(windowTitle)
        let selected = normalizeSubject(selectedSubject)
        guard !selected.isEmpty || !window.isEmpty else { return false }
        return window.caseInsensitiveCompare(selected) == .orderedSame
    }

    /// Keeps the start of the string: Mail puts the newest message first and
    /// the quoted history below it.
    static func truncate(_ content: String, limit: Int = maxContentCharacters) -> String {
        guard limit >= 0, content.count > limit else { return content }
        return String(content.prefix(limit))
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Capture (needs a running Mail)

    /// Must be called while Mail is frontmost with the reply window focused.
    /// NSAppleScript is not thread-safe, hence main actor.
    @MainActor
    static func capture() throws -> MailContext {
        try ensureMailIsFrontmost()
        let pid = NSWorkspace.shared.frontmostApplication!.processIdentifier

        let windowTitle = focusedWindowTitle(pid: pid)
        let message = try readSelectedMessage()

        if let windowTitle, !windowTitle.isEmpty {
            guard subjectsMatch(windowTitle: windowTitle, selectedSubject: message.subject) else {
                throw MailContextError.subjectMismatch(
                    window: windowTitle,
                    selected: message.subject
                )
            }
        } else {
            mailContextLogger.notice("Reply window title unavailable; using selection without subject check")
        }

        var result = message
        result.content = truncate(message.content)
        return result
    }

    @MainActor
    static func ensureMailIsFrontmost() throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == mailBundleIdentifier else {
            throw MailContextError.notMail
        }
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        // Never stall the recording start on an unresponsive Mail.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success, let windowRef else { return nil }
        let window = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.25)

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleRef
        ) == .success, let title = titleRef as? String else { return nil }
        return title
    }

    private static let selectionScript = """
    with timeout of 8 seconds
    tell application "Mail"
        set sel to get selection
        if (count of sel) is 0 then return missing value
        set m to item 1 of sel
        set toList to {}
        set ccList to {}
        try
            set toList to address of every to recipient of m
        end try
        try
            set ccList to address of every cc recipient of m
        end try
        return {subject of m, sender of m, (date received of m) as string, content of m, toList, ccList}
    end tell
    end timeout
    """

    @MainActor
    private static func readSelectedMessage() throws -> MailContext {
        guard let script = NSAppleScript(source: selectionScript) else {
            throw MailContextError.unreadable
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            mailContextLogger.error("Mail selection script failed: \(code)")
            // -1743: Automation permission denied; -1744: needs user consent.
            if code == -1743 || code == -1744 {
                throw MailContextError.automationDenied
            }
            // -1712: AppleEvent timed out; -600: Mail not running.
            if code == -1712 || code == -600 {
                throw MailContextError.mailNotResponding
            }
            throw MailContextError.scriptFailed(code)
        }

        guard descriptor.descriptorType != typeNull, descriptor.numberOfItems >= 4 else {
            throw MailContextError.noSelection
        }

        func text(_ index: Int) -> String {
            descriptor.atIndex(index)?.stringValue ?? ""
        }
        func addresses(_ index: Int) -> [String] {
            guard let list = descriptor.atIndex(index), list.numberOfItems > 0 else { return [] }
            return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }
        }

        return MailContext(
            subject: text(1),
            sender: text(2),
            dateReceived: text(3),
            content: text(4),
            toRecipients: addresses(5),
            ccRecipients: addresses(6)
        )
    }
}
