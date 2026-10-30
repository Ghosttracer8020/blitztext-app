import ApplicationServices
import AppKit

/// Pure decision: has Mail's reply window gone away (sent or discarded)?
/// Only definite answers count as gone; timeouts and other AX errors stay
/// "unknown" so a busy Mail never dismisses the hints by accident.
enum ReplyWindowPresence {
    static func isGone(appRunning: Bool, roleResult: AXError, inWindowList: Bool?) -> Bool {
        if !appRunning { return true }
        if roleResult == .invalidUIElement { return true }
        if inWindowList == false { return true }
        return false
    }

    /// One blocking-capable probe (short AX timeout). Call off the main thread.
    nonisolated static func probe(_ ref: MailReplyWindowRef) -> Bool {
        let running = NSRunningApplication(processIdentifier: ref.pid).map { !$0.isTerminated } ?? false
        guard running else { return true }

        AXUIElementSetMessagingTimeout(ref.element, 0.25)
        var role: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(ref.element, kAXRoleAttribute as CFString, &role)

        var inList: Bool?
        let app = AXUIElementCreateApplication(ref.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            inList = list.contains { CFEqual($0, ref.element) }
        }
        return isGone(appRunning: running, roleResult: roleResult, inWindowList: inList)
    }
}

/// Watches one reply window: AXObserver for its destruction plus a 1 s
/// polling safety net. Calls `onGone` once on the main actor.
@MainActor
final class MailReplyWindowWatch {
    private let ref: MailReplyWindowRef
    private var onGone: (@MainActor () -> Void)?
    private var observer: AXObserver?
    private var timer: Timer?
    private var probing = false

    init(ref: MailReplyWindowRef, onGone: @escaping @MainActor () -> Void) {
        self.ref = ref
        self.onGone = onGone
    }

    func start() {
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<MailReplyWindowWatch>.fromOpaque(refcon).takeUnretainedValue()
            // Delivered on the main run loop (source added there).
            MainActor.assumeIsolated { watch.fire() }
        }
        var created: AXObserver?
        if AXObserverCreate(ref.pid, callback, &created) == .success, let created {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            if AXObserverAddNotification(created, ref.element, kAXUIElementDestroyedNotification as CFString, refcon) == .success {
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
                observer = created
            }
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        onGone = nil
        timer?.invalidate()
        timer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            AXObserverRemoveNotification(observer, ref.element, kAXUIElementDestroyedNotification as CFString)
        }
        observer = nil
    }

    private func poll() {
        guard !probing, onGone != nil else { return }
        probing = true
        let ref = self.ref
        Task { [weak self] in
            let gone = await Task.detached(priority: .utility) { ReplyWindowPresence.probe(ref) }.value
            guard let self else { return }
            self.probing = false
            if gone { self.fire() }
        }
    }

    private func fire() {
        guard let handler = onGone else { return }
        onGone = nil
        handler()
    }
}
