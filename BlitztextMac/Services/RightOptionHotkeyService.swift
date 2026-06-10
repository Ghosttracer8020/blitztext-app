import Cocoa

/// Letter-key hotkeys with the RIGHT Option key as modifier (e.g. right-Alt + K).
///
/// Uses an active CGEventTap instead of NSEvent monitors so the letter key is
/// swallowed and never reaches the focused application while dictating.
/// The tap runs on a dedicated thread with its own run loop: an active
/// keyboard tap on the app's main run loop would add systemwide typing
/// latency whenever the main thread is busy, and main-thread stalls beyond
/// ~1s would get the tap disabled by the system mid-combo.
/// Requires Accessibility permission (already needed for auto-paste).
@MainActor
final class RightOptionHotkeyService {
    var onHotkeyEvent: ((HotkeyEvent) -> Void)? {
        didSet { state.onEvent = makeEventSink() }
    }

    private let state = RightOptionTapState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

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
        let resolved = keyMap.reduce(into: [Int64: WorkflowType]()) { result, entry in
            guard let type = WorkflowType(rawValue: entry.key) else { return }
            result[Int64(entry.value)] = type
        }
        state.setBindings(resolved)
    }

    /// Creates the event tap. Safe to call repeatedly; retries are cheap when
    /// Accessibility permission has not been granted yet, and a tap that the
    /// system killed (e.g. after a permission revoke) is recreated.
    func startIfNeeded() {
        if let eventTap {
            if CFMachPortIsValid(eventTap), CGEvent.tapIsEnabled(tap: eventTap) {
                return
            }
            stop()
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let state = Unmanaged<RightOptionTapState>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return state.process(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(state).toOpaque()
        ) else {
            // No Accessibility permission yet; caller retries later.
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        eventTap = tap
        runLoopSource = source
        state.tapPort = tap
        state.onEvent = makeEventSink()

        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            // Returns once the source is invalidated in stop()
            CFRunLoopRun()
        }
        thread.name = "BlitztextRightOptionTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    func stop() {
        // Invalidating port and source removes the run loop's only source,
        // which ends CFRunLoopRun() and lets the tap thread exit.
        state.tapPort = nil
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        eventTap = nil
        runLoopSource = nil
        tapThread = nil
        state.reset()
    }

    deinit {
        // Safety net for the unretained userInfo pointer: never let the tap
        // outlive the state object it points to.
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    private func makeEventSink() -> (@Sendable (HotkeyEvent) -> Void)? {
        guard onHotkeyEvent != nil else { return nil }
        return { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onHotkeyEvent?(event)
                }
            }
        }
    }
}

/// Tap-thread-side state. All members are guarded by `lock`; the CGEventTap
/// callback runs on the dedicated tap thread while bindings and lifecycle
/// updates arrive from the main thread.
final class RightOptionTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [Int64: WorkflowType] = [:]
    /// Key currently held as part of an active combo.
    private var activeKeyCode: Int64?
    /// Key still physically held after right-Option was released first.
    /// Its remaining autorepeats and keyUp are swallowed so no stray
    /// letter reaches the focused app.
    private var drainKeyCode: Int64?

    /// Device-dependent flag bit for the right Option key (NX_DEVICERALTKEYMASK)
    private static let rightOptionFlagMask: UInt64 = 0x40

    private var _tapPort: CFMachPort?
    var tapPort: CFMachPort? {
        get { lock.withLock { _tapPort } }
        set { lock.withLock { _tapPort = newValue } }
    }

    private var _onEvent: (@Sendable (HotkeyEvent) -> Void)?
    var onEvent: (@Sendable (HotkeyEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    func setBindings(_ newBindings: [Int64: WorkflowType]) {
        lock.withLock { bindings = newBindings }
    }

    func reset() {
        lock.withLock {
            activeKeyCode = nil
            drainKeyCode = nil
        }
    }

    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        var emit: HotkeyEvent?
        var swallow = false
        var sink: (@Sendable (HotkeyEvent) -> Void)?

        lock.lock()
        sink = _onEvent

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // While disabled we may have missed the combo's keyUp: end the
            // combo so hold-mode recordings are not stranded and the next
            // plain press of the letter is not swallowed.
            if let keyCode = activeKeyCode, let workflow = bindings[keyCode] {
                emit = .up(workflow)
            }
            activeKeyCode = nil
            drainKeyCode = nil
            if let port = _tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == activeKeyCode || keyCode == drainKeyCode {
                // Autorepeats of the combo key, or of a key still held after
                // the modifier was released first.
                swallow = true
            } else if isRightOptionHeld(event.flags), bindings[keyCode] != nil {
                if activeKeyCode == nil && drainKeyCode == nil {
                    activeKeyCode = keyCode
                    if let workflow = bindings[keyCode] {
                        emit = .down(workflow)
                    }
                }
                // A second bound key during an active combo is swallowed so
                // no stray Option-layer glyph reaches the focused app.
                swallow = true
            }

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == activeKeyCode {
                activeKeyCode = nil
                if let workflow = bindings[keyCode] {
                    emit = .up(workflow)
                }
                swallow = true
            } else if keyCode == drainKeyCode {
                drainKeyCode = nil
                swallow = true
            }

        case .flagsChanged:
            // Releasing right Option while the letter is still held ends the
            // combo; the letter keeps draining until its physical keyUp.
            if let keyCode = activeKeyCode, !isRightOptionHeld(event.flags) {
                activeKeyCode = nil
                drainKeyCode = keyCode
                if let workflow = bindings[keyCode] {
                    emit = .up(workflow)
                }
            }

        default:
            break
        }

        lock.unlock()

        if let emit, let sink {
            sink(emit)
        }

        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func isRightOptionHeld(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate)
            && flags.rawValue & Self.rightOptionFlagMask != 0
    }
}
