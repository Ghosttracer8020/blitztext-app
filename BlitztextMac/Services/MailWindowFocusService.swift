import AppKit
import ApplicationServices

/// Brings Mail's remembered reply window back to the front after the typed
/// input panel (which made Blitztext the active app) is gone, so the regular
/// paste path lands in the right text field.
@MainActor
enum MailWindowFocusService {
    enum Outcome: Equatable {
        case ready
        case windowGone
    }

    /// Longest wait for Mail to become frontmost; the paste path retries on
    /// its own afterwards.
    static let frontmostTimeout: Duration = .seconds(1)
    private static let pollInterval: Duration = .milliseconds(20)

    /// An AX element of a closed window answers `invalidUIElement`. Other
    /// errors (a busy Mail times out) do not prove the window is gone.
    static func windowIsOpen(_ window: MailReplyWindowRef) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &value)
        return result != .invalidUIElement
    }

    static func restore(window: MailReplyWindowRef?, pid: pid_t) async -> Outcome {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return .windowGone
        }
        if let window, !windowIsOpen(window) {
            return .windowGone
        }

        app.activate(options: [])
        if let window { raise(window) }

        let deadline = ContinuousClock.now + frontmostTimeout
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
              ContinuousClock.now < deadline {
            // Sleep throws at once once cancelled; leave instead of spinning.
            do { try await Task.sleep(for: pollInterval) } catch { break }
        }
        if Task.isCancelled { return .ready }

        if let window {
            // Raising before Mail is active can be ignored; repeat once it is.
            guard windowIsOpen(window) else { return .windowGone }
            raise(window)
        }
        return .ready
    }

    private static func raise(_ window: MailReplyWindowRef) {
        let element = window.element
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Screen holding the center of the reply window (AX uses a top-left
    /// origin on the primary screen, Cocoa a bottom-left one).
    static func screen(of window: MailReplyWindowRef?) -> NSScreen? {
        guard let window,
              let primary = NSScreen.screens.first,
              let position = axPoint(window.element, kAXPositionAttribute),
              let size = axSize(window.element, kAXSizeAttribute) else { return nil }
        let center = CGPoint(
            x: position.x + size.width / 2,
            y: primary.frame.height - (position.y + size.height / 2)
        )
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private static func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
