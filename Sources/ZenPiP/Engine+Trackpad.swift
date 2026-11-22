import AppKit

/// Two-finger swipes on a PiP window: it follows the fingers (and the pointer follows it); lifting
/// slowly sets it down, a flick throws it to the side or corner it was aimed at.
extension Engine {
    // macOS scroll phases (CGScrollPhase / CGMomentumScrollPhase).
    private enum Phase {
        static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4, cancelled: Int64 = 8, mayBegin: Int64 = 128
        static let momentumEnd: Int64 = 3
    }

    /// Returns true when the event belongs to a swipe on a PiP and must be swallowed.
    func handleScroll(_ e: CGEvent) -> Bool {
        let phase = e.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = e.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if phase == 0 && momentum == 0 { return false }  // a mouse wheel: leave it alone

        let now = CACurrentMediaTime() * 1000
        let stale = now - lastScrollTime > 300  // a swipe whose end we never saw
        lastScrollTime = now

        if momentum != 0 {
            // macOS's own coasting after a swipe. ZenPiP animates by itself, so drop it.
            guard momentumOurs else { return false }
            if momentum == Phase.momentumEnd { momentumOurs = false }
            return true
        }

        switch phase {
        case Phase.mayBegin, Phase.began:  // fingers touched, or started moving
            if phase == Phase.mayBegin || !gestureDecided || stale {
                momentumOurs = false
                gestureDecided = true
                tabSwipe = nil
                gestureOurs = beginTabSwipe(at: e.location) || beginGesture(e)
            }
            return gestureOurs
        case Phase.changed:
            if stale && !gestureDecided {
                gestureDecided = true
                tabSwipe = nil
                gestureOurs = beginTabSwipe(at: e.location) || beginGesture(e)
            }
            guard gestureOurs, let ns = NSEvent(cgEvent: e) else { return false }
            if tabSwipe != nil {
                followTabSwipe(fingerDelta(ns))
            } else {
                follow(fingerDelta(ns), at: ns.timestamp * 1000)
            }
            return true
        case Phase.ended, Phase.cancelled:
            let ours = gestureOurs
            gestureDecided = false
            gestureOurs = false
            if ours {
                if tabSwipe != nil {
                    tabSwipe = nil
                    runPendingSpaceCheck()
                } else {
                    release(at: (NSEvent(cgEvent: e)?.timestamp ?? ProcessInfo.processInfo.systemUptime) * 1000)
                }
                momentumOurs = phase == Phase.ended
            }
            return ours
        default:
            return gestureOurs
        }
    }

    /// Decides whether a new swipe is on a PiP window, and gets ready to move it.
    private func beginGesture(_ e: CGEvent) -> Bool {
        // ⌃, ⌘ and ⌥ + scroll keep their usual meaning (for example, accessibility zoom).
        if !e.flags.intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty { return false }
        settings = Settings.load()  // before looking, so the debug log can say why a swipe wasn't picked up
        guard var pip = findPip(at: e.location) else { return false }
        if let entry = stashed, entry.id == pip.id, entry.phase == .parked {
            unstash()  // a sliver of a stashed window: bring it back rather than push it around
            return false
        }
        if target?.id == pip.id, spring?.onArrive != nil || growTimer != nil {
            if stashed?.phase != .returning {
                finishSpring()  // on its way to being stashed: let it finish tucking away
                return false
            }
            finishSpring()  // coming back from the edge: jump to full size, then carry on as normal
            finishGrowing(runPending: false)
            if let tg = target { pip = Pip(id: pip.id, ax: pip.ax, frame: CGRect(origin: shown, size: tg.size)) }
        }
        caughtDest = nil

        if let s = spring, target?.id == pip.id {
            // Caught in flight: carry on from exactly where it's drawn.
            caughtDest = s.dest
            target?.pos = shown
            spring = nil
            endTimer()
        } else {
            finishSpring()
            // If ZenPiP moved this window a moment ago, its own position is fresher than macOS's.
            let recent = target?.id == pip.id && CACurrentMediaTime() - lastShownAt < 0.25 ? shown : nil
            guard retarget(pip) else { return false }
            if let recent {
                target?.pos = recent
                shown = recent
            }
        }

        guard let tg = target else { return false }
        moved = false
        gestureStart = tg.pos
        pointerOrigin = e.location
        pointerOffset = CGVector(dx: e.location.x - tg.pos.x, dy: e.location.y - tg.pos.y)
        Pointer.forget()
        samples.removeAll()
        debug("Swipe on PiP window \(pip.id) at \(pip.frame)")
        return true
    }

    /// How far the fingers moved, in the direction they moved (whatever the scroll direction setting).
    private func fingerDelta(_ ns: NSEvent) -> CGVector {
        var dx = ns.scrollingDeltaX, dy = ns.scrollingDeltaY
        if !ns.hasPreciseScrollingDeltas {
            dx *= 10
            dy *= 10
        }
        // With natural scrolling the deltas already follow the fingers; otherwise flip them.
        var sign: CGFloat = ns.isDirectionInvertedFromDevice ? 1 : -1
        if settings.invert { sign = -sign }
        return CGVector(dx: dx * sign, dy: dy * sign)
    }

    private func follow(_ d: CGVector, at t: Double) {
        guard var tg = target, d.dx != 0 || d.dy != 0 else { return }
        moved = true
        tg.pos.x += Physics.resist(tg.pos.x, d.dx, tg.bounds.minX, tg.bounds.maxX)
        tg.pos.y += Physics.resist(tg.pos.y, d.dy, tg.bounds.minY, tg.bounds.maxY)
        target = tg
        show(tg.pos)
        if settings.followPointer {
            Pointer.move(to: CGPoint(x: tg.pos.x + pointerOffset.dx, y: tg.pos.y + pointerOffset.dy), within: tg.display)
        }
        samples.append(.init(t: t, dx: d.dx, dy: d.dy))
        if samples.count > 40 { samples.removeFirst(samples.count - 40) }
    }

    /// The fingers lifted (or macOS cut the swipe short).
    func release(at t: Double) {
        defer {
            caughtDest = nil
            if spring == nil { runPendingSpaceCheck() }
        }
        guard let tg = target else { return }
        if !moved {
            // Fingers rested on it without moving: nothing to do, except let a caught window carry on.
            if let dest = caughtDest { startSpring(to: dest, velocity: .zero, pointer: .stay) }
            return
        }

        let v = Physics.releaseVelocity(samples, endTime: t)
        samples.removeAll()
        let isThrow = hypot(v.dx, v.dy) >= Physics.flingSpeed
        if let side = Stash.side(releasedAt: tg.pos, startedAt: gestureStart, velocity: v, isThrow: isThrow,
                                 pushedPast: Stash.pushPast, bounds: tg.bounds), canStash(side) {
            // Pushed or flicked past a side: tuck it away. The pointer goes back to what you were doing.
            if settings.followPointer, let origin = pointerOrigin { Pointer.move(to: origin, within: tg.display) }
            stash(side, velocity: v)
        } else if isThrow {
            // A throw: the video goes out of the way, and the pointer goes back to what you were doing.
            let dest = Physics.throwDestination(from: tg.pos, velocity: v, bounds: tg.bounds)
            debug(String(format: "Throw at %.2f, %.2f pt/ms to %.0f, %.0f", v.dx, v.dy, dest.x, dest.y))
            if settings.followPointer, let origin = pointerOrigin { Pointer.move(to: origin, within: tg.display) }
            startSpring(to: dest, velocity: Physics.throwVelocity(v, at: tg.pos, bounds: tg.bounds), pointer: .stay)
        } else {
            // Set down: it stays (snapping onto a nearby edge), and the pointer centres on it.
            let dest = Physics.restDestination(from: tg.pos, bounds: tg.bounds)
            debug(String(format: "Set down at %.0f, %.0f, resting at %.0f, %.0f", tg.pos.x, tg.pos.y, dest.x, dest.y))
            if settings.followPointer { Pointer.move(to: center(of: tg.pos), within: tg.display) }
            if hypot(dest.x - tg.pos.x, dest.y - tg.pos.y) >= 0.5 {
                startSpring(to: dest, velocity: .zero, pointer: .center)
            }
        }
    }

    /// The centre of the window being moved, if its top-left corner were at `origin`.
    func center(of origin: CGPoint) -> CGPoint {
        guard let tg = target else { return origin }
        return CGPoint(x: origin.x + tg.size.width / 2, y: origin.y + tg.size.height / 2)
    }
}
