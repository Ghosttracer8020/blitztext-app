import Cocoa

/// User-configurable hotkeys: a single key or any modifier+key combination
/// per workflow (recorded in settings, e.g. right-Alt+K or F5).
///
/// Uses an active CGEventTap instead of NSEvent monitors so the bound key is
/// swallowed and never reaches the focused application while dictating.
/// The tap runs on a dedicated thread with its own run loop: an active
/// keyboard tap on the app's main run loop would add systemwide typing
/// latency whenever the main thread is busy, and main-thread stalls beyond
/// ~1s would get the tap disabled by the system mid-combo.
/// Requires Accessibility permission (already needed for auto-paste).
@MainActor
final class CustomHotkeyService {
    var onHotkeyEvent: ((HotkeyEvent) -> Void)? {
        didSet { state.onEvent = makeEventSink() }
    }

    private let state = CustomHotkeyTapState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    func updateBindings(_ shortcuts: [String: KeyboardShortcut]) {
        let resolved = shortcuts.compactMap { entry -> (KeyboardShortcut, WorkflowType)? in
            guard let type = WorkflowType(rawValue: entry.key) else { return nil }
            return (entry.value, type)
        }
        state.setBindings(resolved)
    }

    /// While the settings UI records a new shortcut, the tap passes all
    /// events through so the recorded combo does not trigger a workflow.
    /// On resume, `drainingKeyCode` (the just-recorded key, possibly still
    /// physically held) is swallowed until its keyUp so the fresh binding
    /// does not fire immediately via autorepeat.
    func setSuspended(_ suspended: Bool, drainingKeyCode: Int? = nil) {
        state.setSuspended(suspended, drainingKeyCode: drainingKeyCode.map(Int64.init))
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
            let state = Unmanaged<CustomHotkeyTapState>
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
        thread.name = "BlitztextHotkeyTap"
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
final class CustomHotkeyTapState: @unchecked Sendable {
    private struct ActiveCombo {
        /// nil for modifier-only shortcuts
        let keyCode: Int64?
        let shortcut: KeyboardShortcut
        let workflow: WorkflowType
    }

    private let lock = NSLock()
    private var bindings: [(shortcut: KeyboardShortcut, workflow: WorkflowType)] = []
    /// Combo currently held.
    private var active: ActiveCombo?
    /// Key still physically held after its required modifiers were released
    /// first. Its remaining autorepeats and keyUp are swallowed so no stray
    /// character reaches the focused app.
    private var drainKeyCode: Int64?
    private var suspended = false

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

    func setBindings(_ newBindings: [(KeyboardShortcut, WorkflowType)]) {
        lock.withLock { bindings = newBindings }
    }

    func setSuspended(_ value: Bool, drainingKeyCode: Int64? = nil) {
        lock.withLock {
            suspended = value
            // Do not keep half-finished combo state across a suspension.
            active = nil
            drainKeyCode = value ? nil : drainingKeyCode
        }
    }

    func reset() {
        lock.withLock {
            active = nil
            drainKeyCode = nil
        }
    }

    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Never match or swallow this app's own synthetic events
        // (e.g. the auto-paste Cmd+V posted by performPaste).
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardShortcut.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        var emit: HotkeyEvent?
        var swallow = false
        var reenableTap: CFMachPort?

        lock.lock()
        let sink = _onEvent

        if suspended, type != .tapDisabledByTimeout, type != .tapDisabledByUserInput {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // While disabled we may have missed the combo's keyUp: end the
            // combo so hold-mode recordings are not stranded and the next
            // plain press of the key is not swallowed.
            if let combo = active {
                emit = .up(combo.workflow)
            }
            active = nil
            drainKeyCode = nil
            reenableTap = _tapPort

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == active?.keyCode || keyCode == drainKeyCode {
                // Autorepeats of the combo key, or of a key still held after
                // its modifiers were released first.
                swallow = true
            } else if let match = bindings.first(where: { $0.shortcut.matches(keyCode: keyCode, flags: event.flags) }) {
                if active == nil && drainKeyCode == nil {
                    active = ActiveCombo(
                        keyCode: keyCode,
                        shortcut: match.shortcut,
                        workflow: match.workflow
                    )
                    emit = .down(match.workflow)
                } else if let combo = active, combo.shortcut.isModifierOnly {
                    // Upgrade: a keyed binding fired while its modifier-only
                    // prefix is active (e.g. rAlt dictation -> rAlt+J combo).
                    // The in-flight recording is discarded, not transcribed.
                    active = ActiveCombo(
                        keyCode: keyCode,
                        shortcut: match.shortcut,
                        workflow: match.workflow
                    )
                    emit = .switchTo(match.workflow)
                }
                // A second bound combo during an active keyed one is
                // swallowed so no stray character reaches the focused app.
                swallow = true
            }

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if let combo = active, let comboKey = combo.keyCode, keyCode == comboKey {
                active = nil
                emit = .up(combo.workflow)
                swallow = true
            } else if keyCode == drainKeyCode {
                drainKeyCode = nil
                swallow = true
            }

        case .flagsChanged:
            if let combo = active {
                if combo.shortcut.isModifierOnly,
                   // Only a *growing* modifier set is an upgrade. Without this
                   // guard, releasing one modifier of a chord (rAlt+rCmd ->
                   // rAlt) matches the shorter binding and switches away,
                   // discarding the finished recording instead of transcribing.
                   combo.shortcut.requiredModifiersStillHeld(event.flags),
                   let upgrade = bindings.first(where: {
                       $0.shortcut.isModifierOnly
                           && $0.shortcut != combo.shortcut
                           && $0.shortcut.matchesModifierState(event.flags)
                   }) {
                    // Upgrade: the held modifier set grew into a more
                    // specific modifier-only binding (e.g. rAlt dictation
                    // -> rAlt+rCmd). The in-flight recording is discarded.
                    active = ActiveCombo(
                        keyCode: nil,
                        shortcut: upgrade.shortcut,
                        workflow: upgrade.workflow
                    )
                    emit = .switchTo(upgrade.workflow)
                } else if !combo.shortcut.requiredModifiersStillHeld(event.flags) {
                    // Releasing a required modifier ends the combo; a
                    // still-held key keeps draining until its physical keyUp.
                    active = nil
                    drainKeyCode = combo.keyCode
                    emit = .up(combo.workflow)
                }
            } else if drainKeyCode == nil,
                      let match = bindings.first(where: { $0.shortcut.matchesModifierState(event.flags) }) {
                // Modifier-only shortcut (e.g. right-Option alone as
                // push-to-talk): fires on the exact modifier state.
                active = ActiveCombo(
                    keyCode: nil,
                    shortcut: match.shortcut,
                    workflow: match.workflow
                )
                emit = .down(match.workflow)
            }

        default:
            break
        }

        lock.unlock()

        if let reenableTap {
            CGEvent.tapEnable(tap: reenableTap, enable: true)
        }

        if let emit, let sink {
            sink(emit)
        }

        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
