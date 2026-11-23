import AppKit

/// The spring that carries a window to where it's going, ticked 120 times a second while it moves.
extension Engine {
    func startSpring(to dest: CGPoint, velocity: CGVector, pointer: PointerMode,
                     arriveWhen: ((CGPoint) -> Bool)? = nil, onArrive: (() -> Void)? = nil) {
        guard var tg = target else { return }
        // Start from where the window is drawn. Only overshoot beyond the far side gets squeezed, so a
        // window that starts outside the bounds (pushed, dragged, or under the Dock) moves smoothly.
        tg.pos = shown
        tg.softBounds = tg.bounds.including(shown).including(dest)  // a stash goes past the edge on purpose
        target = tg
        let now = CACurrentMediaTime()
        spring = Spring(dest: dest, vel: velocity, pointer: pointer, started: now, onArrive: onArrive, arriveWhen: arriveWhen)
        lastTick = now
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0
            RunLoop.main.add(t, forMode: .common)
            timer = t
            animationActivity = ProcessInfo.processInfo.beginActivity(options: [.latencyCritical], reason: "PiP animation")
        }
    }

    /// Jumps a moving window straight to where it was heading.
    func finishSpring() {
        guard let s = spring, var tg = target else { return }
        tg.pos = s.dest
        target = tg
        show(s.dest)
        spring = nil
        endTimer()
        s.onArrive?()
    }

    func endTimer() {
        timer?.invalidate()
        timer = nil
        if let activity = animationActivity { ProcessInfo.processInfo.endActivity(activity) }
        animationActivity = nil
    }

    private func tick() {
        guard var tg = target, var s = spring else {
            endTimer()
            return
        }
        let now = CACurrentMediaTime()
        if (now - s.started) * 1000 > Physics.maxSpringMs {
            finishSpring()  // never animate forever, whatever the settings
            runPendingSpaceCheck()
            return
        }
        let dt = CGFloat(min(48, (now - lastTick) * 1000))
        lastTick = now

        let moving = Physics.springStep(pos: &tg.pos, vel: &s.vel, dest: s.dest, dt: dt)
        target = tg
        let drawn = Physics.soften(tg.pos, tg.softBounds)
        show(drawn)
        if let arrived = s.arriveWhen, arrived(drawn) {
            spring = nil
            endTimer()
            s.onArrive?()
            runPendingSpaceCheck()
            return
        }
        if case .center = s.pointer, settings.followPointer {
            if Pointer.userMovedIt {
                s.pointer = .stay  // you've moved on; stop pulling the pointer back
            } else {
                Pointer.move(to: center(of: drawn), within: tg.display)
            }
        }

        spring = moving ? s : nil
        if !moving {
            endTimer()
            s.onArrive?()
            runPendingSpaceCheck()
        }
    }
}
