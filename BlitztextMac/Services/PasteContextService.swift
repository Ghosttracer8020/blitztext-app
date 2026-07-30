import AppKit
import ApplicationServices

/// Reads the character immediately before the insertion point in the focused
/// text element of the frontmost app via the Accessibility API. Used to
/// decide whether a paste needs a leading space (e.g. consecutive dictations:
/// the previous transcript ended with "." and the new one would otherwise
/// stick to it).
enum PasteContextService {
    /// What the focused element says about the insertion point. `unknown` is
    /// distinct from `noLeadingSpaceNeeded` on purpose: many targets expose no
    /// usable text info at all (Mail's compose view, terminals), and callers
    /// must be able to fall back instead of silently pasting without a space.
    enum InsertionContext {
        case needsLeadingSpace
        case noLeadingSpaceNeeded
        case unknown
    }

    /// Characters after which no leading space should be inserted.
    static let noSpaceAfter = Set(" \t\n\r([{\u{201E}\u{201A}\u{00AB}\u{2039}'\"/-\u{2013}\u{2014}")

    static func needsLeadingSpace(after character: Character) -> Bool {
        !noSpaceAfter.contains(character)
    }

    static func insertionContext() -> InsertionContext {
        let systemWide = AXUIElementCreateSystemWide()
        // Never stall the paste on an unresponsive target app.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return .unknown }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return .unknown }

        var selectedRange = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selectedRange) else { return .unknown }

        // An active selection gets replaced by the paste, and a cursor at the
        // very start has nothing to stick to — both are known-good, not
        // unknown, so no fallback should second-guess them.
        guard selectedRange.length == 0 else { return .noLeadingSpaceNeeded }
        guard selectedRange.location > 0 else { return .noLeadingSpaceNeeded }

        var queryRange = CFRange(location: selectedRange.location - 1, length: 1)
        guard let queryValue = AXValueCreate(.cfRange, &queryRange) else { return .unknown }

        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            queryValue,
            &stringRef
        ) == .success, let result = stringRef as? String, let previous = result.first else {
            return .unknown
        }

        return needsLeadingSpace(after: previous) ? .needsLeadingSpace : .noLeadingSpaceNeeded
    }
}
