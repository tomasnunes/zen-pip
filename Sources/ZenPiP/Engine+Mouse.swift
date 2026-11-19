import AppKit

/// Click-and-drag of a PiP window (mouse, or a trackpad click). The browser does the drag itself;
/// ZenPiP only steps in when the button comes up: let go while still moving and the window is
/// thrown to that side or corner; let go slowly and it stays, snapping onto a nearby edge and
/// sliding back if it was left partly off-screen. The pointer is left alone, since your hand is on it.
extension Engine {
    func mouseDown(at point: CGPoint) {
        pressed = nil
        interrupted = nil
        guard let w = WindowList.topmost(at: point), isCandidate(w) else { return }
        var frame = w.frame
        if let s = spring, target?.id == w.id {
            // Clicked (or grabbed) in flight: remember where it was going, in case this is just a click.
            interrupted = (w.id, s.dest)
            target?.pos = shown
            frame.origin = shown
            spring = nil
            endTimer()
        }
        pressed = (w.id, w.pid, frame)
    }

    func mouseUp(command: Bool, points: [(t: Double, p: CGPoint)], upTime: Double) {
        guard let p = pressed else {
            runPendingSpaceCheck()
            return
        }
        pressed = nil
        let stopped = interrupted?.id == p.id ? interrupted : nil
        interrupted = nil

        // How fast the pointer (and so the window) was moving when the button came up.
        var samples: [Physics.Sample] = []
        for i in points.indices.dropFirst() {
            let a = points[i - 1].p, b = points[i].p
            samples.append(.init(t: points[i].t, dx: b.x - a.x, dy: b.y - a.y))
        }
        let pointerVelocity = Physics.releaseVelocity(samples, endTime: upTime)

        // Give the window server a moment to report where the drag left the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            defer { if self.spring == nil { self.runPendingSpaceCheck() } }
            guard !self.gestureOurs, let frame = WindowList.frame(of: p.id) else { return }

            let dragged = hypot(frame.minX - p.frame.minX, frame.minY - p.frame.minY) >= 2
            if !dragged {
                // Just a click (play/pause and so on): a window that was flying carries on.
                if let stopped, self.target?.id == p.id {
                    self.shown = frame.origin
                    self.startSpring(to: stopped.dest, velocity: .zero, pointer: .stay)
                }
                return
            }
            if command { return }  // ⌘-drag is the browser's own snap-to-corner

            self.settings = Settings.load()
            if self.target?.id != p.id { self.finishSpring() }
            guard let pip = self.verify(id: p.id, pid: p.pid, frame: frame),
                  let area = Screens.area(for: frame), !self.fillsScreen(frame, area),
                  self.retarget(pip), let tg = self.target else { return }

            // If macOS didn't pass the drag's pointer movements through, use how far the window went
            // and how quickly instead: a quick flick of the window is a throw too.
            var v = pointerVelocity
            if samples.count < 2, let start = points.first?.t, upTime - start > 0, upTime - start < 400 {
                let ms = CGFloat(upTime - start)
                v = Physics.capped(CGVector(dx: (frame.minX - p.frame.minX) / ms, dy: (frame.minY - p.frame.minY) / ms),
                                   Physics.maxSpeed)
            }
            self.debug("Drag released: \(samples.count) pointer samples, \(String(format: "%.2f", hypot(v.dx, v.dy))) pt/ms")

            if hypot(v.dx, v.dy) >= Physics.flingSpeed {
                let dest = Physics.throwDestination(from: tg.pos, velocity: v, bounds: tg.bounds)
                self.debug(String(format: "Mouse throw to %.0f, %.0f", dest.x, dest.y))
                self.startSpring(to: dest, velocity: Physics.throwVelocity(v, at: tg.pos, bounds: tg.bounds), pointer: .stay)
            } else {
                let dest = Physics.restDestination(from: tg.pos, bounds: tg.bounds)
                if hypot(dest.x - tg.pos.x, dest.y - tg.pos.y) >= 0.5 {
                    self.startSpring(to: dest, velocity: .zero, pointer: .stay)
                }
            }
        }
    }
}
