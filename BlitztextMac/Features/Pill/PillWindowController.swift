import AppKit
import SwiftUI

/// Floating, non-activating panel hosting the pill indicator. Visible while
/// a workflow is active (recording/processing/result), hidden when idle.
/// Draggable; the position is persisted across launches.
@MainActor
final class PillWindowController: NSObject {
    private static let positionKey = "PillWindowPosition"
    private let pillWidth: CGFloat = PillIndicatorView.outerWidth
    private let pillHeight: CGFloat = PillIndicatorView.outerHeight

    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func update(for status: MenuBarStatus) {
        if status == .idle {
            panel?.orderOut(nil)
            return
        }

        let panel = ensurePanel()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: PillIndicatorView(appState: appState))

        let panel = NSPanel(
            contentRect: initialFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // shadow is rendered by SwiftUI
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMove),
            name: NSWindow.didMoveNotification,
            object: panel
        )

        self.panel = panel
        return panel
    }

    private func initialFrame() -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            let point = NSPointFromString(saved)
            if point != .zero {
                return NSRect(x: point.x, y: point.y, width: pillWidth, height: pillHeight)
            }
        }

        // Default: top center of the main screen
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 24
        return NSRect(
            x: visible.midX - pillWidth / 2,
            y: visible.maxY - pillHeight - inset,
            width: pillWidth,
            height: pillHeight
        )
    }

    @objc private func handleMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        UserDefaults.standard.set(
            NSStringFromPoint(panel.frame.origin),
            forKey: Self.positionKey
        )
    }
}
