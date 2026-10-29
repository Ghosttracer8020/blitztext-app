import AppKit
import SwiftUI

/// Small floating input for the typed Blitztext Mail variant (like Gmail's
/// "Help me write"). Unlike the pill it needs keyboard focus, so it is a
/// key-capable panel that activates Blitztext (an LSUIElement app).
@MainActor
final class MailReplyInputPanelController: NSObject, NSWindowDelegate {
    static let contentWidth: CGFloat = 460
    private static let shadowInset: CGFloat = 20
    private static let topInset: CGFloat = 80

    private var panel: MailReplyInputPanel?
    private var onSubmit: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the panel; any panel still open is dismissed without a callback.
    func present(
        title: String,
        screen: NSScreen?,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()
        self.onSubmit = onSubmit
        self.onCancel = onCancel

        let view = MailReplyInputView(
            title: title,
            onSubmit: { [weak self] text in self?.submit(text) },
            onCancel: { [weak self] in self?.cancel() }
        )
        let hosting = NSHostingView(rootView: view.padding(Self.shadowInset))
        let size = hosting.fittingSize

        let panel = MailReplyInputPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // NSPanel hides on app deactivation by default; that would order the
        // panel out without closing it, losing the typed text and the cancel.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // shadow is rendered by SwiftUI
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.delegate = self

        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - Self.topInset + Self.shadowInset
        ))

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel without calling submit or cancel.
    func dismiss() {
        onSubmit = nil
        onCancel = nil
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.close()
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func submit(_ text: String) {
        guard MailReplyTypedInput.canSubmit(text), let handler = onSubmit else { return }
        dismiss()
        handler(MailReplyTypedInput.trimmed(text))
    }

    private func cancel() {
        let handler = onCancel
        dismiss()
        handler?()
    }

    func windowWillClose(_ notification: Notification) {
        // Closed by other means than submit/cancel/dismiss.
        guard panel != nil else { return }
        cancel()
    }
}

private final class MailReplyInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

private struct MailReplyInputView: View {
    let title: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""

    private static let background = Color(red: 0.14, green: 0.14, blue: 0.16)
    private static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Abbrechen")
            }

            ZStack(alignment: .topLeading) {
                MailReplyTextView(text: $text, onSubmit: { onSubmit(text) }, onCancel: onCancel)
                if text.isEmpty {
                    Text(MailReplyTypedInput.placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.07))
            )

            Text(MailReplyTypedInput.hint)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(14)
        .frame(width: MailReplyInputPanelController.contentWidth)
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

/// Multi-line text view: Enter submits, Shift+Enter inserts a newline, Esc
/// cancels (see `MailReplyInputKey`).
private struct MailReplyTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = KeyAwareTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? KeyAwareTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MailReplyTextView
        init(_ parent: MailReplyTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class KeyAwareTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let action = MailReplyInputKey.action(
            keyCode: event.keyCode,
            shiftHeld: event.modifierFlags.contains(.shift),
            hasMarkedText: hasMarkedText()
        )
        switch action {
        case .submit: onSubmit?()
        case .insertNewline: insertNewline(nil)
        case .cancel: onCancel?()
        case .passThrough: super.keyDown(with: event)
        }
    }
}
