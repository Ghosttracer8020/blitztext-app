import ApplicationServices
import Foundation
import os

private let mailComposeLogger = Logger(subsystem: "app.blitztext.mac", category: "MailCompose")

/// What Blitztext Mail knows about a new mail the user is writing, as read
/// from the compose window. Display names only: Mail's To/Cc fields expose
/// no addresses through Accessibility.
struct MailComposeContext: Equatable {
    var toRecipients: [String] = []
    var ccRecipients: [String] = []
    var subject: String = ""
}

/// How the focused Mail window is treated.
enum MailWindowKind: Equatable {
    /// Compose window whose title carries a reply/forward prefix: the
    /// original mail is the selected message.
    case reply
    /// Compose window without such a prefix ("Neue E-Mail" or a typed
    /// subject): a mail written from scratch.
    case compose
    /// No compose window (no To field): the legacy selection flow applies.
    case other

    /// An unreadable title (AX timeout) with a To field keeps the reply path,
    /// as before compose mode existed: the reply flow then reads the selected
    /// message or reports an error, but never writes a context-free mail.
    static func classify(title: String?, hasToField: Bool) -> MailWindowKind {
        guard hasToField else { return .other }
        guard let title else { return .reply }
        return MailContextService.hasReplyPrefix(title) ? .reply : .compose
    }
}

/// Reads and prepares Mail's compose window through Accessibility. The field
/// lookup prefers Mail's AXIdentifiers and falls back to the label in front
/// of the field; names cleaning is pure and testable.
enum MailComposeService {
    static let toFieldIdentifier = "Mail.toField"
    static let ccFieldIdentifier = "Mail.ccField"
    static let subjectFieldIdentifier = "Mail.subjectField"
    private static let ccLabels: Set<String> = ["Kopie:", "Cc:"]
    private static let subjectLabels: Set<String> = ["Betreff:", "Subject:"]
    /// Object replacement character: Mail's AXValue holds one per recipient token.
    private static let attachmentMarker = "\u{FFFC}"
    private static let axTimeout: Float = 0.25
    /// Shown when the text could not be placed in the message body.
    static let bodyNotFocusedMessage = "Mail-Text liegt in der Zwischenablage (Mailtext nicht gefunden)."
    private static let bodyDescriptions = ["message body", "nachrichtentext"]

    // MARK: - Pure helpers

    /// One child of the compose window, as far as field detection needs it.
    struct FieldCandidate: Equatable {
        let role: String?
        let identifier: String?
        let value: String?
    }

    /// Positions (in the candidate list) of the To, Cc and subject fields.
    struct FieldIndices: Equatable {
        var to: Int?
        var cc: Int?
        var subject: Int?
    }

    /// Finds the address and subject fields among the window's children.
    /// AXIdentifier wins; otherwise the static text right before a text field
    /// names it ("Kopie:" / "Betreff:"). "Blindkopie:" is not a Cc label.
    /// Only `Mail.toField` is verified live; `Mail.ccField` and
    /// `Mail.subjectField` are guesses, the label fallback carries them.
    static func classify(fields: [FieldCandidate]) -> FieldIndices {
        var result = FieldIndices()
        var label = ""
        for (index, field) in fields.enumerated() {
            if field.role == kAXStaticTextRole as String {
                label = field.value ?? ""
                continue
            }
            guard field.role == kAXTextFieldRole as String else { continue }
            if field.identifier == toFieldIdentifier {
                result.to = index
            } else if field.identifier == ccFieldIdentifier || (result.cc == nil && ccLabels.contains(label)) {
                result.cc = index
            } else if field.identifier == subjectFieldIdentifier || (result.subject == nil && subjectLabels.contains(label)) {
                result.subject = index
            }
            label = ""
        }
        return result
    }

    /// True if an AXWebArea description marks the message body (Mail's
    /// compose window can hold further web areas, e.g. the signature picker).
    static func isBodyDescription(_ description: String?) -> Bool {
        guard let description = description?.lowercased() else { return false }
        return bodyDescriptions.contains { description.contains($0) }
    }

    /// Recipient display names of one address field. Mail renders each
    /// recipient as a token (child with the name) and puts only the marker
    /// character into the field value; text typed but not yet tokenized stays
    /// in the value and is used when there are no tokens.
    static func recipientNames(tokenNames: [String], fieldValue: String) -> [String] {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: attachmentMarker, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tokens = tokenNames.map(clean).filter { !$0.isEmpty }
        if !tokens.isEmpty { return tokens }
        return clean(fieldValue)
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Reading

    /// Caps one traversal: the AX calls are blocking (up to `axTimeout`
    /// each), so a slow Mail must not stall for seconds.
    private final class Budget {
        private var nodes: Int
        private let deadline: ContinuousClock.Instant

        init(maxNodes: Int = 300, seconds: Double = 1.5) {
            nodes = maxNodes
            deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        }

        /// Spends one node; false once the node count or the time is used up.
        func spend() -> Bool {
            nodes -= 1
            return nodes >= 0 && ContinuousClock.now < deadline
        }
    }

    private struct Fields {
        let to: AXUIElement
        let cc: AXUIElement?
        let subject: AXUIElement?
    }

    /// Recipients and subject of the compose window; nil if it has no To field.
    static func readContext(of window: AXUIElement) -> MailComposeContext? {
        guard let fields = fields(in: window) else { return nil }
        return MailComposeContext(
            toRecipients: recipients(of: fields.to),
            ccRecipients: fields.cc.map(recipients(of:)) ?? [],
            subject: fields.subject.flatMap { string($0, kAXValueAttribute) } ?? ""
        )
    }

    private static func fields(in window: AXUIElement) -> Fields? {
        let budget = Budget()
        var elements: [AXUIElement] = []
        var candidates: [FieldCandidate] = []
        for child in children(of: window) {
            guard budget.spend() else { break }
            let role = string(child, kAXRoleAttribute)
            let isText = role == kAXStaticTextRole as String
            let isField = role == kAXTextFieldRole as String
            elements.append(child)
            candidates.append(FieldCandidate(
                role: role,
                identifier: isField ? string(child, kAXIdentifierAttribute) : nil,
                value: isText ? string(child, kAXValueAttribute) : nil
            ))
        }
        let indices = classify(fields: candidates)
        guard let to = indices.to else { return nil }
        return Fields(to: elements[to], cc: indices.cc.map { elements[$0] }, subject: indices.subject.map { elements[$0] })
    }

    private static func recipients(of field: AXUIElement) -> [String] {
        let tokens = children(of: field).prefix(50).compactMap { string($0, kAXValueAttribute) }
        return recipientNames(tokenNames: tokens, fieldValue: string(field, kAXValueAttribute) ?? "")
    }

    // MARK: - Delivery

    /// Prepares the window for the paste: fills the subject if it is still
    /// empty (never overwrites one), then makes sure the message body has
    /// the keyboard focus. Never sends anything. The AX reads run off the
    /// main thread; only the writes happen here.
    /// - Returns: true if the body has the focus, i.e. a paste lands in the
    ///   mail text. On false the caller must not paste.
    @MainActor
    static func prepareForPaste(window: MailReplyWindowRef, subject: String) async -> Bool {
        let element = window.element
        AXUIElementSetMessagingTimeout(element, axTimeout)

        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSubject.isEmpty,
           let field = await offMain({ emptySubjectField(in: element) }) {
            let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, trimmedSubject as CFString)
            if result != .success {
                mailComposeLogger.error("Setting the subject failed: \(result.rawValue)")
            }
        }

        return await focusBody(of: window)
    }

    private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    private static func emptySubjectField(in window: AXUIElement) -> AXUIElement? {
        guard let field = fields(in: window)?.subject else { return nil }
        let current = string(field, kAXValueAttribute) ?? ""
        return current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? field : nil
    }

    @MainActor
    private static func focusBody(of window: MailReplyWindowRef) async -> Bool {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        let windowElement = window.element

        if await offMain({ bodyHasFocus(app: app, window: windowElement) }) { return true }
        guard let body = await offMain({ findBody(in: windowElement) }) else {
            mailComposeLogger.error("Message body not found in the compose window")
            return false
        }
        AXUIElementSetMessagingTimeout(body, axTimeout)
        // Whether Mail honours AXFocused on its web area is not verified
        // live; a failure here ends in the clipboard fallback of the caller.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(body, kAXFocusedAttribute as CFString, &settable) != .success || !settable.boolValue {
            mailComposeLogger.error("AXFocused of the message body reports not settable")
        }
        let result = AXUIElementSetAttributeValue(body, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if result != .success {
            mailComposeLogger.error("Focusing the message body failed: \(result.rawValue)")
            return false
        }

        // Focus changes arrive asynchronously; give Mail a moment.
        let deadline = ContinuousClock.now + .milliseconds(300)
        while ContinuousClock.now < deadline {
            if await offMain({ bodyHasFocus(app: app, window: windowElement) }) { return true }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        let focused = await offMain { bodyHasFocus(app: app, window: windowElement) }
        if !focused { mailComposeLogger.error("Focus is still not in the message body after the wait") }
        return focused
    }

    private static func bodyHasFocus(app: AXUIElement, window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref else { return false }
        var element: AXUIElement? = (ref as! AXUIElement)
        // The focused node can be a child of the web area; walk up a few levels.
        for _ in 0..<8 {
            guard let current = element else { return false }
            if CFEqual(current, window) { return false }
            if string(current, kAXRoleAttribute) == "AXWebArea" { return true }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else { return false }
            element = (parentRef as! AXUIElement)
        }
        return false
    }

    /// The message body is the web area described as "message body"; any
    /// other web area is only a fallback. Bounded by node count and time.
    private static func findBody(in window: AXUIElement) -> AXUIElement? {
        let budget = Budget()
        var firstWebArea: AXUIElement?

        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard budget.spend() else { return nil }
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                if isBodyDescription(string(element, kAXDescriptionAttribute)) { return element }
                if firstWebArea == nil { firstWebArea = element }
                return nil
            }
            guard depth < 8 else { return nil }
            for child in children(of: element) {
                // Toolbars and the formatting bar never hold the body.
                if string(child, kAXRoleAttribute) == kAXToolbarRole as String { continue }
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }

        return search(window, depth: 0) ?? firstWebArea
    }

    // MARK: - AX access

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
