import AppKit
import SwiftUI

/// Floating review hints ("Prüfen vor dem Senden") shown after a Blitztext
/// Mail reply was pasted. Non-activating: Mail keeps focus and the cursor
/// stays in the reply. Stays until closed or until the next run starts.
@MainActor
final class MailReplyHintsPanelController {
    static let contentWidth: CGFloat = 360
    private static let shadowInset: CGFloat = 20
    private static let edgeInset: CGFloat = 16

    private var panel: MailReplyHintsPanel?
    private var windowWatch: MailReplyWindowWatch?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Screen rect of the dictation pill's capsule (visible or not: then its
    /// last position). Set by the app delegate; nil falls back to the screen corner.
    var pillCapsuleRect: (@MainActor () -> NSRect?)?

    /// Replaces any panel still open. Centred directly above the dictation
    /// pill (below it if there is no room above), else top-right of the screen
    /// holding Mail's reply window (`screen`), else of the main screen.
    func present(hints: [MailReplyHint], window: MailReplyWindowRef?, screen: NSScreen?) {
        dismiss()
        guard !hints.isEmpty else { return }

        let view = MailReplyHintsView(hints: hints, onClose: { [weak self] in self?.dismiss() })
        let hosting = FirstMouseHostingView(rootView: view.padding(Self.shadowInset))
        let size = hosting.fittingSize

        let panel = MailReplyHintsPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // shadow is rendered by SwiftUI
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting

        if let capsule = pillCapsuleRect?() {
            let pillScreen = Self.screen(containing: capsule) ?? screen ?? NSScreen.main ?? NSScreen.screens.first
            let visible = pillScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            // The hosting view has a shadow margin around the card; place the card itself.
            let card = HintsPanelPlacement.contentRect(
                contentSize: CGSize(
                    width: size.width - 2 * Self.shadowInset,
                    height: size.height - 2 * Self.shadowInset
                ),
                capsule: capsule,
                visible: visible
            )
            panel.setFrameOrigin(NSPoint(x: card.minX - Self.shadowInset, y: card.minY - Self.shadowInset))
        } else {
            let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - Self.edgeInset + Self.shadowInset,
                y: visible.maxY - size.height - Self.edgeInset + Self.shadowInset
            ))
        }

        self.panel = panel
        // Sent or discarded reply window: nothing left to review, so close.
        if let window {
            let watch = MailReplyWindowWatch(ref: window, onGone: { [weak self] in self?.dismiss() })
            windowWatch = watch
            watch.start()
        }
        // Never makeKey / activate: Mail must stay the active app.
        panel.orderFrontRegardless()
    }

    /// The screen the capsule is on: the one containing its centre, else the
    /// one it overlaps most.
    private static func screen(containing rect: NSRect) -> NSScreen? {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(centre) }) { return hit }
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(rect).width * lhs.frame.intersection(rect).height
                < rhs.frame.intersection(rect).width * rhs.frame.intersection(rect).height
        }
    }

    func dismiss() {
        windowWatch?.stop()
        windowWatch = nil
        guard let panel else { return }
        self.panel = nil
        panel.close()
    }
}

private final class MailReplyHintsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the close button react to the first click although the panel is
/// never key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Presentation

extension MailReplyHint.Kind {
    var label: String {
        switch self {
        case .widerspruch: return "Widerspruch"
        case .schonBeantwortet: return "Schon beantwortet"
        case .offen: return "Offen"
        }
    }

    var color: Color {
        switch self {
        case .widerspruch: return Color(red: 1.0, green: 0.62, blue: 0.25)
        case .schonBeantwortet: return Color(red: 0.4, green: 0.65, blue: 1.0)
        case .offen: return Color(red: 0.78, green: 0.74, blue: 0.5)
        }
    }
}

private struct MailReplyHintsView: View {
    let hints: [MailReplyHint]
    let onClose: () -> Void

    private static let background = Color(red: 0.14, green: 0.14, blue: 0.16)
    private static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Prüfen vor dem Senden (\(hints.count))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Schließen")
            }

            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                VStack(alignment: .leading, spacing: 3) {
                    Text(hint.kind.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hint.kind.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(hint.kind.color.opacity(0.16)))
                    Text(hint.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
            }
        }
        .padding(14)
        .frame(width: MailReplyHintsPanelController.contentWidth)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Self.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
    }
}
