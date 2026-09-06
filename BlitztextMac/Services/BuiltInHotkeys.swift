import Foundation

/// The six fixed `fn` combos the app has always shipped with.
///
/// Two independent hotkey systems run side by side: `HotkeyService` watches
/// `NSEvent` flagsChanged for these built-in combos, `CustomHotkeyService`
/// runs a CGEventTap for the user's recorded shortcuts. Neither knew about
/// the other, so a recorded shortcut with the same modifiers as a built-in
/// combo fired BOTH workflows; the built-in one won the race (fn + left ⌘
/// recorded for the prompt workflow started the emoji workflow instead).
///
/// The claim rule fixes that: a built-in combo is claimed — and therefore
/// switched off — as soon as ANY custom shortcut uses exactly the same
/// generic modifier set, whether that shortcut is modifier-only or has a key,
/// and no matter which workflow it belongs to (including the workflow that
/// owns the built-in combo itself). Device side bits (left/right ⌘ …) are
/// deliberately ignored: the built-in combos are side-agnostic, so a
/// left-⌘ binding would still collide with the built-in's right-⌘ press.
/// Unclaimed built-ins stay active in addition to the custom shortcuts,
/// exactly as before — the settings UI calls them "zusätzlich aktiv".
///
/// This type is intentionally free of `WorkflowType` (and of everything else
/// in the app target) so the unit-test target can compile it on its own; the
/// workflow raw value is used as the ID and mapped back in `HotkeyService`.
struct BuiltInHotkey: Equatable {
    /// Equals a `WorkflowType.rawValue`.
    let workflowID: String
    /// Generic modifier bits, built from the `KeyboardShortcut` masks.
    let modifiers: UInt64
    /// Label shown in the menu and the settings list.
    let label: String

    /// The six upstream combos, in menu order.
    static let all: [BuiltInHotkey] = [
        BuiltInHotkey(
            workflowID: "transcription",
            modifiers: KeyboardShortcut.fnMask | KeyboardShortcut.shiftMask,
            label: "fn + Shift"
        ),
        BuiltInHotkey(
            workflowID: "localTranscription",
            modifiers: KeyboardShortcut.fnMask | KeyboardShortcut.shiftMask | KeyboardShortcut.controlMask,
            label: "fn + Shift + Ctrl"
        ),
        BuiltInHotkey(
            workflowID: "textImprover",
            modifiers: KeyboardShortcut.fnMask | KeyboardShortcut.controlMask,
            label: "fn + Control"
        ),
        BuiltInHotkey(
            workflowID: "dampfAblassen",
            modifiers: KeyboardShortcut.fnMask | KeyboardShortcut.optionMask,
            label: "fn + Option"
        ),
        BuiltInHotkey(
            workflowID: "emojiText",
            modifiers: KeyboardShortcut.fnMask | KeyboardShortcut.commandMask,
            label: "fn + Cmd"
        ),
        BuiltInHotkey(
            workflowID: "promptText",
            modifiers: KeyboardShortcut.fnMask | KeyboardShortcut.shiftMask | KeyboardShortcut.commandMask,
            label: "fn + Shift + Cmd"
        ),
    ]

    /// The built-in combo belonging to a workflow, if it has one.
    static func hotkey(forWorkflowID workflowID: String) -> BuiltInHotkey? {
        all.first { $0.workflowID == workflowID }
    }

    /// Label of a workflow's built-in combo, if it has one.
    static func label(forWorkflowID workflowID: String) -> String? {
        hotkey(forWorkflowID: workflowID)?.label
    }

    /// Workflow ID whose custom shortcut claims this built-in combo, or nil
    /// when the combo is free. Matching is on the generic modifier set only.
    ///
    /// Ambiguity is resolved deterministically so the UI and the hotkey table
    /// never disagree: if the workflow that owns the built-in combo is among
    /// the claimants it wins (it is the least surprising answer — its own
    /// recorded shortcut simply replaces its built-in one), otherwise the
    /// alphabetically first workflow ID wins.
    static func claimant(of hotkey: BuiltInHotkey, in customShortcuts: [String: KeyboardShortcut]) -> String? {
        let claimants = customShortcuts
            .filter { $0.value.modifiers == hotkey.modifiers }
            .map(\.key)
        guard !claimants.isEmpty else { return nil }
        if claimants.contains(hotkey.workflowID) { return hotkey.workflowID }
        return claimants.sorted().first
    }

    /// The built-in combos that stay active next to the given custom
    /// shortcuts — everything without a claimant.
    static func active(customShortcuts: [String: KeyboardShortcut]) -> [BuiltInHotkey] {
        all.filter { claimant(of: $0, in: customShortcuts) == nil }
    }
}
