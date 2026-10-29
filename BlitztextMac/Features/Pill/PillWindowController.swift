import AppKit
import SwiftUI

/// Floating, non-activating panel hosting the pill indicator. Visible while
/// a workflow is active (recording/processing/result), hidden when idle.
/// Draggable; the position is persisted across launches.
@MainActor
final class PillWindowController: NSObject {
    private static let legacyPositionKey = "PillWindowPosition"
    /// The window grew from 110x60 to 120x80 with the same capsule centre
    /// height; positions saved under this key belong to the new frame.
    private static let positionKey = "PillWindowPositionV2"
    private static let fadeOutDuration: TimeInterval = 0.15
    private let pillWidth: CGFloat = PillIndicatorView.outerWidth
    private let pillHeight: CGFloat = PillIndicatorView.outerHeight

    private var panel: NSPanel?
    private let appState: AppState
    private let presentation = PillPresentation()
    private var hideTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func update(for status: MenuBarStatus) {
        if status == .idle {
            guard let panel, panel.isVisible else { return }
            showTask?.cancel()
            showTask = nil
            presentation.isExiting = true
            presentation.isVisible = false
            hideTask?.cancel()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.fadeOutDuration + 0.02))
                guard !Task.isCancelled, let self else { return }
                self.panel?.orderOut(nil)
            }
            return
        }

        hideTask?.cancel()
        hideTask = nil
        let panel = ensurePanel()
        if !panel.isVisible {
            presentation.isExiting = false
            presentation.isVisible = false
            panel.orderFrontRegardless()
            // Give SwiftUI a display cycle to commit the hidden first frame,
            // otherwise both states land in one transaction and nothing animates.
            showTask?.cancel()
            showTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, let self else { return }
                self.presentation.isVisible = true
            }
        } else {
            // Panel still visible (possibly mid fade-out): show again at once.
            showTask?.cancel()
            showTask = nil
            presentation.isVisible = true
        }
    }

    /// Screen rect of the capsule: where it is now, or where it will appear
    /// (saved position / default) while the pill is hidden.
    func capsuleScreenRect() -> NSRect {
        PillGeometry.capsuleRect(inWindowFrame: panel?.frame ?? initialFrame())
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = PillHostingView(rootView: PillIndicatorView(appState: appState, presentation: presentation))

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
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Self.positionKey) {
            let point = NSPointFromString(saved)
            if point != .zero {
                return NSRect(x: point.x, y: point.y, width: pillWidth, height: pillHeight)
            }
        } else if let legacy = defaults.string(forKey: Self.legacyPositionKey) {
            // Old window was 110x60: keep the capsule where it was (same centre).
            let point = NSPointFromString(legacy)
            if point != .zero {
                let origin = NSPoint(x: point.x - (pillWidth - 110) / 2, y: point.y)
                defaults.set(NSStringFromPoint(origin), forKey: Self.positionKey)
                return NSRect(x: origin.x, y: origin.y, width: pillWidth, height: pillHeight)
            }
        }

        // Default: top center of the main screen
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 24
        return NSRect(
            x: visible.midX - pillWidth / 2,
            // Capsule centre sits 30 pt above the window bottom, as in the old 60 pt window.
            y: visible.maxY - 60 - inset,
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

/// Hosting view that only claims mouse events over the capsule. The window is
/// larger than the capsule (bubble and shadow room); without this the
/// transparent area would swallow clicks and drags meant for other windows.
final class PillHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate space.
        let local = convert(point, from: superview)
        let x = (bounds.width - PillLayout.pillWidth) / 2
        let y = isFlipped
            ? bounds.height - PillLayout.pillBottomInset - PillLayout.pillHeight
            : PillLayout.pillBottomInset
        let capsule = NSRect(x: x, y: y, width: PillLayout.pillWidth, height: PillLayout.pillHeight)
        return capsule.contains(local) ? super.hitTest(point) : nil
    }
}
