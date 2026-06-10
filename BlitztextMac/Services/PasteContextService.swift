import AppKit
import ApplicationServices

/// Reads the character immediately before the insertion point in the focused
/// text element of the frontmost app via the Accessibility API. Used to
/// decide whether a paste needs a leading space (e.g. consecutive dictations:
/// the previous transcript ended with "." and the new one would otherwise
/// stick to it).
enum PasteContextService {
    /// Characters after which no leading space should be inserted.
    private static let noSpaceAfter = Set(" \t\n\r([{\u{201E}\u{201A}\u{00AB}\u{2039}'\"/-\u{2013}\u{2014}")

    /// Whether text inserted at the current cursor position needs a leading
    /// space. Returns false when the context cannot be determined (no AX
    /// support in the target, cursor at start, selection active).
    static func insertionNeedsLeadingSpace() -> Bool {
        guard let previous = characterBeforeCursor() else { return false }
        return !noSpaceAfter.contains(previous)
    }

    private static func characterBeforeCursor() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()
        // Never stall the paste on an unresponsive target app.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }

        var selectedRange = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selectedRange) else { return nil }

        // Only a collapsed cursor with at least one character before it is
        // meaningful; an active selection gets replaced by the paste anyway.
        guard selectedRange.length == 0, selectedRange.location > 0 else { return nil }

        var queryRange = CFRange(location: selectedRange.location - 1, length: 1)
        guard let queryValue = AXValueCreate(.cfRange, &queryRange) else { return nil }

        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            queryValue,
            &stringRef
        ) == .success, let result = stringRef as? String else { return nil }

        return result.first
    }
}
