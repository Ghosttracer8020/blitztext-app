import Cocoa
import Observation

enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
    case hold    // Tasten halten = aufnehmen, loslassen = stoppen
    case toggle  // Einmal drücken = starten, nochmal/Escape = stoppen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Halten"
        case .toggle: return "Drücken"
        }
    }

    var description: String {
        switch self {
        case .hold: return "Tasten halten zum Aufnehmen, loslassen zum Stoppen"
        case .toggle: return "Einmal drücken zum Starten, nochmal oder Escape zum Stoppen"
        }
    }
}

enum HotkeyEvent {
    case down(WorkflowType)     // Keys pressed
    case up(WorkflowType)       // Keys released (for hold mode)
    case cancel                 // Escape pressed
    /// A held modifier-only combo grew into a more specific binding
    /// (e.g. right-Option dictation -> right-Option+right-Command combo):
    /// discard the in-flight recording and start the new workflow.
    case switchTo(WorkflowType)
}

@Observable
@MainActor
final class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var activeCombo: WorkflowType?  // Which combo is currently held
    /// Built-in fn combos that are currently active, keyed by the raw value
    /// of their exact `NSEvent.ModifierFlags` set (`NSEvent.ModifierFlags`
    /// itself is not Hashable, so it cannot be a dictionary key). Starts with
    /// all six (upstream behaviour) until `updateCustomShortcuts` first runs;
    /// a recorded shortcut with the same modifiers removes the entry, see
    /// `BuiltInHotkey`.
    private var comboTable: [UInt: WorkflowType] =
        HotkeyService.makeComboTable(from: BuiltInHotkey.all)

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?
    /// Set while the settings UI records a new shortcut.
    var isSuspended = false

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
            return event
        }
        // Escape key monitor for toggle mode
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                if event.keyCode == 53 { // Escape
                    self?.handleEscape()
                }
            }
        }
    }

    /// Recomputes the active built-in combos from the user's recorded
    /// shortcuts. Call whenever `AppSettings.customShortcuts` changes.
    func updateCustomShortcuts(_ shortcuts: [String: KeyboardShortcut]) {
        comboTable = Self.makeComboTable(from: BuiltInHotkey.active(customShortcuts: shortcuts))
    }

    /// Maps the generic CGEventFlags bits of the built-in combos to their
    /// AppKit counterparts explicitly — the two bit layouts are not
    /// interchangeable, so no raw-value casting here.
    private static func makeComboTable(from hotkeys: [BuiltInHotkey]) -> [UInt: WorkflowType] {
        var table: [UInt: WorkflowType] = [:]
        for hotkey in hotkeys {
            guard let type = WorkflowType(rawValue: hotkey.workflowID) else { continue }
            var flags: NSEvent.ModifierFlags = []
            if hotkey.modifiers & KeyboardShortcut.fnMask != 0 { flags.insert(.function) }
            if hotkey.modifiers & KeyboardShortcut.commandMask != 0 { flags.insert(.command) }
            if hotkey.modifiers & KeyboardShortcut.shiftMask != 0 { flags.insert(.shift) }
            if hotkey.modifiers & KeyboardShortcut.optionMask != 0 { flags.insert(.option) }
            if hotkey.modifiers & KeyboardShortcut.controlMask != 0 { flags.insert(.control) }
            table[flags.rawValue] = type
        }
        return table
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
    }

    private func handleFlags(_ event: NSEvent) {
        guard !isSuspended else {
            activeCombo = nil
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Exact match against the active built-in combos
        if let type = comboTable[flags.rawValue] {
            if activeCombo == nil {
                activeCombo = type
                onHotkeyEvent?(.down(type))
            }
            return
        }

        // Keys released -- fire up event
        if let combo = activeCombo {
            activeCombo = nil
            onHotkeyEvent?(.up(combo))
        }
    }

    private func handleEscape() {
        activeCombo = nil
        onHotkeyEvent?(.cancel)
    }
}
