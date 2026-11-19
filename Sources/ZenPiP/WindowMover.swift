import AppKit

/// Moves a window through Accessibility on a background queue, so a busy browser never holds up
/// input. Only the newest position matters: older ones still waiting are skipped.
final class WindowMover {
    private let queue = DispatchQueue(label: "local.zenpip.mover", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (window: AXUIElement, point: CGPoint)?
    private var draining = false

    /// Called on the main thread when a window turns out to be gone (for example, the PiP was closed).
    var onWindowGone: ((AXUIElement) -> Void)?

    func move(_ window: AXUIElement, to point: CGPoint) {
        lock.lock()
        pending = (window, point)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            var point = job.point
            guard let value = AXValueCreate(.cgPoint, &point) else { continue }
            if AXUIElementSetAttributeValue(job.window, kAXPositionAttribute as CFString, value) == .invalidUIElement {
                let onWindowGone = onWindowGone
                DispatchQueue.main.async { onWindowGone?(job.window) }
            }
        }
    }
}
