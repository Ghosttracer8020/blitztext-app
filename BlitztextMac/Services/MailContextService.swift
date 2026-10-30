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

/// The reply window that was focused when the mail was captured, so the typed
/// flow can bring exactly that window back after the input panel closed.
struct MailReplyWindowRef {
    let pid: pid_t
    let element: AXUIElement
    let title: String?
}

/// What was read from Mail: the thread of the selected message for a reply,
/// the recipients and subject of the compose window for a new mail.
enum MailCaptureContent {
    case reply(MailContext)
    case compose(MailComposeContext)
}

/// Everything the workflow needs from the moment Mail was frontmost.
struct MailCapture {
    let content: MailCaptureContent
    let pid: pid_t
    let window: MailReplyWindowRef?
}

enum MailContextError: LocalizedError, Equatable {
    case notMail
    case automationDenied
    case noSelection
    case noQuotedOriginal
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
        case .noQuotedOriginal:
            return "In Mail ist keine passende Nachricht markiert, und im Antwortfenster konnte ich das zitierte Original nicht lesen. Markiere die Mail, auf die du antwortest, im Postfach."
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

    private static let replyPrefixPattern = #"^(re|aw|fwd|fw|wg)\s*:\s*"#

    /// True if the title starts with a reply/forward prefix ("Re:", "AW:", ...).
    static func hasReplyPrefix(_ title: String) -> Bool {
        collapseWhitespace(title).range(of: replyPrefixPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True only for real reply prefixes ("Re:", "AW:"), not for forwards.
    static func hasRealReplyPrefix(_ title: String) -> Bool {
        collapseWhitespace(title).range(of: #"^(re|aw)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Strips repeated reply/forward prefixes ("Re:", "AW:", "Fwd:", "Fw:",
    /// "WG:", any case), collapses whitespace, trims.
    static func normalizeSubject(_ subject: String) -> String {
        var text = collapseWhitespace(subject)
        while let range = text.range(of: replyPrefixPattern, options: [.regularExpression, .caseInsensitive]) {
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

    /// Sender and date from the attribution line Mail puts above the quoted
    /// original ("Am 19.10.2026 um 19:14 schrieb Name <addr>:").
    struct Attribution: Equatable {
        let date: String
        let sender: String
    }

    private static let attributionPatterns = [
        #"^Am\s+(.+?)\s+schrieb\s+(.+?)\s*:$"#,
        // English: anchor on the time ("..., at 7:14 PM, Name wrote:") so a comma
        // inside the sender's name ("Doe, Jane") stays part of the sender.
        #"^On\s+(.+?\bat\s+\d{1,2}[:.]\d{2}(?::\d{2})?(?:\s*[AP]M)?),\s+(.+?)\s+wrote\s*:$"#,
        // English without time: a date like "Oct 19, 2026" or a comma-free one.
        #"^On\s+((?:\w+,\s+)?\w+\.?\s+\d{1,2},\s+\d{4}|[^,]+?),\s+(.+?)\s+wrote\s*:$"#,
    ]

    /// Parses one line as an attribution ("Am ... schrieb X:" / "On ..., X wrote:").
    /// Returns nil for any other line.
    static func parseAttribution(_ line: String) -> Attribution? {
        let text = collapseWhitespace(line)
        for pattern in attributionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges == 3,
                  let dateRange = Range(match.range(at: 1), in: text),
                  let senderRange = Range(match.range(at: 2), in: text)
            else { continue }
            let sender = String(text[senderRange])
            guard !sender.isEmpty else { continue }
            return Attribution(date: String(text[dateRange]), sender: sender)
        }
        return nil
    }

    /// Builds the quoted original from the text lines of a reply body. Lines
    /// before the attribution line are the user's own part (empty, dictated,
    /// signature) and are dropped. The attribution may be split over several
    /// nodes (address as link, wrapped line), so up to `maxAttributionSpan`
    /// consecutive lines are joined for matching. Without an attribution line
    /// the original cannot be told from the user's own text: nil, no guessing.
    static let maxAttributionSpan = 4

    static func quotedText(fromBodyLines lines: [String]) -> (text: String, attribution: Attribution)? {
        let cleaned = lines
            .map { $0.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for index in cleaned.indices {
            for span in 1...maxAttributionSpan where index + span <= cleaned.count {
                let joined = cleaned[index..<(index + span)].joined(separator: " ")
                guard let attribution = parseAttribution(joined) else { continue }
                let rest = cleaned[(index + span)...]
                // Only the attribution itself: no original text behind it.
                guard !rest.isEmpty else { return nil }
                return ((joined + "\n" + rest.joined(separator: "\n")), attribution)
            }
        }
        return nil
    }

    /// Context built from the reply window alone, for when the selected
    /// message is gone or differs (mail opened later via link).
    static func contextFromReplyWindow(
        title: String,
        body: (text: String, attribution: Attribution),
        compose: MailComposeContext?
    ) -> MailContext {
        let to = compose?.toRecipients ?? []
        return MailContext(
            subject: normalizeSubject(title),
            sender: body.attribution.sender,
            dateReceived: body.attribution.date,
            content: truncate(body.text),
            toRecipients: to,
            ccRecipients: compose?.ccRecipients ?? []
        )
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Capture (needs a running Mail)

    /// Must be called while Mail is frontmost with the reply or compose window
    /// focused. Remembers Mail's pid and that window. A reply window reads the
    /// selected message on the AppleScript queue (awaited, never blocking the
    /// main thread); a compose window without reply prefix reads only itself,
    /// no selection.
    @MainActor
    static func captureWithWindow() async throws -> MailCapture {
        try ensureMailIsFrontmost()
        let pid = NSWorkspace.shared.frontmostApplication!.processIdentifier

        let window = focusedWindowRef(pid: pid)
        let windowTitle = window?.title

        let composeContext = window.flatMap { MailComposeService.readContext(of: $0.element) }
        if let composeContext,
           MailWindowKind.classify(title: windowTitle, hasToField: true) == .compose {
            return MailCapture(content: .compose(composeContext), pid: pid, window: window)
        }

        let selectionError: Error
        do {
            let message = try await readSelectedMessage()
            if let windowTitle, !windowTitle.isEmpty,
               !subjectsMatch(windowTitle: windowTitle, selectedSubject: message.subject) {
                selectionError = MailContextError.subjectMismatch(window: windowTitle, selected: message.subject)
            } else {
                if windowTitle?.isEmpty ?? true {
                    mailContextLogger.notice("Reply window title unavailable; using selection without subject check")
                }
                var result = message
                result.content = truncate(message.content)
                mailContextLogger.notice("Mail context from selection")
                return MailCapture(content: .reply(result), pid: pid, window: window)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Any other selection failure (nothing selected, Mail timed out,
            // automation refused): the fallback below needs only Accessibility.
            selectionError = error
        }

        // Nothing usable selected (e.g. the mail was opened later from a link):
        // the quoted original in the reply window is the context instead.
        // Real replies only; a forward window must not become reply context.
        guard let window, let windowTitle, hasRealReplyPrefix(windowTitle) else {
            mailContextLogger.notice("No mail context: selection unusable and window is not a reply")
            throw selectionError
        }
        if let body = await MailComposeService.readReplyBodyLines(of: window.element),
           let quoted = quotedText(fromBodyLines: body) {
            mailContextLogger.notice("Mail context from reply window (selection fallback)")
            let context = contextFromReplyWindow(title: windowTitle, body: quoted, compose: composeContext)
            return MailCapture(content: .reply(context), pid: pid, window: window)
        }
        mailContextLogger.notice("No mail context: selection unusable and no quoted original with attribution in the reply window")
        // A mismatch or Mail error is more telling than the generic hint; only
        // the plain "nothing selected" case gets the quote-specific message.
        if let known = selectionError as? MailContextError, known == .noSelection {
            throw MailContextError.noQuotedOriginal
        }
        throw selectionError
    }

    @MainActor
    static func ensureMailIsFrontmost() throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == mailBundleIdentifier else {
            throw MailContextError.notMail
        }
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        focusedWindowRef(pid: pid)?.title
    }

    static func focusedWindowRef(pid: pid_t) -> MailReplyWindowRef? {
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
        let title: String?
        if AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleRef
        ) == .success {
            title = titleRef as? String
        } else {
            title = nil
        }
        return MailReplyWindowRef(pid: pid, element: window, title: title)
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

    /// NSAppleScript is not thread-safe: every script of the app runs on this
    /// one serial queue, never two at once from different threads.
    static let scriptQueue = DispatchQueue(label: "app.blitztext.mac.mail-applescript", qos: .userInitiated)

    /// Runs a script and maps its errors. Call only on `scriptQueue`.
    static func executeScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw MailContextError.unreadable
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            mailContextLogger.error("Mail script failed: \(code)")
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
        return descriptor
    }

    /// Runs on the shared script queue; the caller awaits, so the main
    /// thread stays free meanwhile.
    private static func readSelectedMessage() async throws -> MailContext {
        let descriptor: NSAppleEventDescriptor = try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                continuation.resume(with: Result { try executeScript(selectionScript) })
            }
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
