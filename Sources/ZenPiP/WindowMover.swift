import AppKit

/// Moves windows through Accessibility on a background queue, so a busy browser never holds up
/// input. Each window's changes are applied in the order they were asked for (changes to different
/// windows may overtake each other), and of several moves for a window still waiting, only the
/// newest is applied.
final class WindowMover {
    enum Step {
        case position(CGPoint)
        case size(CGSize)
    }

    private enum Change {
        case move(CGPoint)
        case steps([Step])
    }

    private let queue = DispatchQueue(label: "local.zenpip.mover", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [(window: AXUIElement, change: Change)] = []
    private var draining = false

    /// Called on the main thread when a window turns out to be gone (for example, the PiP was closed).
    var onWindowGone: ((AXUIElement) -> Void)?

    func move(_ window: AXUIElement, to point: CGPoint) {
        lock.lock()
        // A move still waiting behind a resize has to stay behind it, so only a trailing move is replaced.
        if let i = pending.lastIndex(where: { CFEqual($0.window, window) }), case .move = pending[i].change {
            pending[i].change = .move(point)
        } else {
            pending.append((window, .move(point)))
        }
        startDraining()
    }

    /// Applies several changes to one window in order (for example resize, then move), after any
    /// changes already on their way. Waiting moves for that window are dropped, since this moves it;
    /// waiting resizes are dropped too when this also resizes it.
    func sequence(_ window: AXUIElement, _ steps: [Step]) {
        let resizes = steps.contains { if case .size = $0 { return true } else { return false } }
        lock.lock()
        pending.removeAll { job in
            guard CFEqual(job.window, window) else { return false }
            if case .move = job.change { return true }
            return resizes
        }
        pending.append((window, .steps(steps)))
        startDraining()
    }

    /// Waits until every change asked for so far has been applied.
    func finish() {
        queue.sync {}
    }

    /// Call with the lock held; releases it.
    private func startDraining() {
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                draining = false
                lock.unlock()
                return
            }
            let job = pending.removeFirst()
            lock.unlock()

            switch job.change {
            case .move(let point):
                var p = point
                guard let value = AXValueCreate(.cgPoint, &p) else { continue }
                if AXUIElementSetAttributeValue(job.window, kAXPositionAttribute as CFString, value) == .invalidUIElement {
                    let onWindowGone = onWindowGone
                    DispatchQueue.main.async { onWindowGone?(job.window) }
                }
            case .steps(let steps):
                for step in steps {
                    switch step {
                    case .position(let p): AX.setPosition(job.window, CGPoint(x: p.x.rounded(), y: p.y.rounded()))
                    case .size(let s): AX.setSize(job.window, CGSize(width: s.width.rounded(), height: s.height.rounded()))
                    }
                }
            }
        }
    }
}
