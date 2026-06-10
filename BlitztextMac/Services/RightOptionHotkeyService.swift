import Cocoa

/// Letter-key hotkeys with the RIGHT Option key as modifier (e.g. right-Alt + K).
///
/// Uses an active CGEventTap instead of NSEvent monitors so the letter key is
/// swallowed and never reaches the focused application while dictating.
/// Requires Accessibility permission (already needed for auto-paste).
@MainActor
final class RightOptionHotkeyService {
    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    private(set) var isRunning = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// keyCode -> workflow, updated from settings
    private var bindings: [Int64: WorkflowType] = [:]
    /// keyCode currently held as part of an active combo
    private var activeKeyCode: Int64?

    /// Device-dependent flag bit for the right Option key (NX_DEVICERALTKEYMASK)
    private static let rightOptionFlagMask: UInt64 = 0x40

    /// ANSI virtual key codes for letters. Positions match QWERTZ for all
    /// letters except Y/Z, which are swapped relative to the printed label.
    static let letterKeyCodes: [(letter: String, keyCode: Int)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3),
        ("G", 5), ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37),
        ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15),
        ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7),
    ]

    static func letter(forKeyCode keyCode: Int) -> String? {
        letterKeyCodes.first(where: { $0.keyCode == keyCode })?.letter
    }

    func updateBindings(_ keyMap: [String: Int]) {
        bindings = keyMap.reduce(into: [:]) { result, entry in
            guard let type = WorkflowType(rawValue: entry.key) else { return }
            result[Int64(entry.value)] = type
        }
    }

    /// Creates the event tap. Safe to call repeatedly; retries are cheap when
    /// Accessibility permission has not been granted yet.
    func startIfNeeded() {
        guard !isRunning else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<RightOptionHotkeyService>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            // The tap's run loop source is installed on the main run loop,
            // so this callback always runs on the main thread.
            return MainActor.assumeIsolated {
                service.handle(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // No Accessibility permission yet; caller retries later.
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        activeKeyCode = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            return handleKeyDown(event)

        case .keyUp:
            return handleKeyUp(event)

        case .flagsChanged:
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Swallow key repeats of an active combo key
        if keyCode == activeKeyCode {
            return nil
        }

        guard isRightOptionHeld(event.flags),
              let workflow = bindings[keyCode] else {
            return Unmanaged.passUnretained(event)
        }

        // A different bound key while a combo is active: swallow it so no
        // stray Option-layer glyph reaches the focused app mid-dictation.
        guard activeKeyCode == nil else {
            return nil
        }

        activeKeyCode = keyCode
        onHotkeyEvent?(.down(workflow))
        return nil
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        guard keyCode == activeKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        activeKeyCode = nil
        if let workflow = bindings[keyCode] {
            onHotkeyEvent?(.up(workflow))
        }
        return nil
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        // Releasing right Option while the letter is still held also ends the combo
        guard let keyCode = activeKeyCode, !isRightOptionHeld(event.flags) else {
            return
        }

        activeKeyCode = nil
        if let workflow = bindings[keyCode] {
            onHotkeyEvent?(.up(workflow))
        }
    }

    private func isRightOptionHeld(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate)
            && flags.rawValue & Self.rightOptionFlagMask != 0
    }
}
