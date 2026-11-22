import AppKit

/// The bottom limit depends on the space: in a full-screen app the Dock is hidden, so a PiP can go
/// all the way down; on a normal desktop it stays above the Dock. When you switch between them, a
/// PiP resting on the bottom edge follows it, and one that would now sit under the Dock moves up.
extension Engine {
    func scheduleSpaceCheck() {
        lastSpaceChange = CACurrentMediaTime()
        modeBeforeSwitch = settledMode
        parkFailures = 0
        spaceMovesLeft = 4  // enough for a couple of PiP windows, and stops one that won't move from looping
        spaceLooksLeft = 12
        spaceFrames = [:]
        // A first note of where the windows are, so a window already at rest can be moved at the
        // first look.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.noteSpaceFrames() }
        // Once the switch has settled, and again in case the first look was mid-animation.
        for delay in [0.3, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refitStash()
                self?.checkSpaces()
            }
        }
    }

    private func noteSpaceFrames() {
        let now = CACurrentMediaTime()
        for w in WindowList.onScreen() where isCandidate(w) && spaceFrames[w.id] == nil { spaceFrames[w.id] = (w.frame, now) }
    }

    func runPendingSpaceCheck() {
        if pendingSpaceCheck { checkSpaces() }
    }

    /// Moves PiP windows to suit the space now showing, one window at a time; the check runs again
    /// when each one comes to rest.
    private func checkSpaces() {
        let busy = gestureOurs || spring != nil || pressed != nil || growTimer != nil || stashed?.phase == .returning
            || CGEventSource.buttonState(.hidSystemState, button: .left)
        if busy {
            pendingSpaceCheck = true  // don't fight the user; try again when things are at rest
            spaceFrames = [:]  // and look afresh then
            return
        }
        pendingSpaceCheck = false
        settings = Settings.load()
        rescueStrandedPip()

        var nowFullScreen: [String: Bool] = [:]
        for area in Screens.areas() { nowFullScreen[area.uuid ?? ""] = Spaces.isFullScreen(area) }
        let displays = WindowList.displayFrames()

        let windows = WindowList.onScreen()
        // A window is at rest only if looks in a row find it at the same frame: one this look doesn't
        // get as far as checking (missing from the list, sliding, skipped) starts again next time.
        var stillSince: [CGWindowID: (frame: CGRect, since: CFTimeInterval)] = [:]
        defer { spaceFrames = stillSince }
        // A window mostly off its display (or a known PiP missing from the window list for now) is
        // still on its way, so not where it will end up.
        var sliding = pipByWindow.keys.contains { id in id != stashed?.id && !windows.contains { $0.id == id } && WindowList.frame(of: id) != nil }
        if spaceMovesLeft > 0 {
            for w in windows where isCandidate(w) && w.id != stashed?.id {
                guard let area = Screens.area(for: w.frame), !fillsScreen(w.frame, area) else { continue }
                // Mostly off the display: it's sliding with the switch (or on another space) and isn't
                // where it will end up, so it's left alone.
                let visible = w.frame.intersection(area.frame)
                if visible.isNull || visible.width * visible.height < w.frame.width * w.frame.height / 2 {
                    sliding = true
                    continue
                }
                // A sliver left at a side is tucked away properly instead (see `rescueStrandedPip`).
                if settings.stash, Stash.strandedSide(w.frame, display: area.frame, displays: displays) != nil { continue }
                let key = area.uuid ?? ""
                let fullScreen = nowFullScreen[key] ?? false
                // Resting on the bottom edge of the space before this switch, or of this one if an
                // earlier look already moved it there (or it shows up only after that look).
                let known = Set([modeBeforeSwitch[key], settledMode[key]].compactMap { $0 })
                let before = known.isEmpty ? [true, false] : Array(known)
                let dest = area.destinationAfterSpaceChange(w.frame, oldModes: before, newMode: fullScreen, margin: settings.edgeMargin)
                guard hypot(dest.x - w.frame.minX, dest.y - w.frame.minY) >= 2 else { continue }  // ignore a point of rounding
                // Only a window at rest: one leaving full screen, or sliding with the switch, is
                // still being moved by macOS, and moving it then can leave it at an in-between size.
                let now = CACurrentMediaTime()
                let seen = spaceFrames[w.id].flatMap { Stash.sameFrame($0.frame, w.frame) ? $0 : nil }
                stillSince[w.id] = seen ?? (w.frame, now)
                guard let seen, now - seen.since >= 0.2 else {
                    if spaceLooksLeft > 0 {
                        spaceLooksLeft -= 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.checkSpaces() }
                    } else {
                        settledMode = nowFullScreen  // it never came to rest; start afresh next time
                    }
                    return
                }
                guard let pip = verify(id: w.id, pid: w.pid, frame: w.frame) else { continue }

                debug("Space changed (full screen: \(fullScreen)); moving PiP window \(w.id) to \(dest)")
                spaceMovesLeft -= 1
                finishSpring()
                guard retarget(pip, fullScreen: fullScreen) else { continue }
                startSpring(to: dest, velocity: .zero, pointer: .stay)
                pendingSpaceCheck = true  // look at the next window once this one has arrived
                return
            }
        }
        if sliding && spaceLooksLeft > 0 {  // look again once it has landed, before calling this space settled
            spaceLooksLeft -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.checkSpaces() }
            return
        }
        settledMode = nowFullScreen  // every window is where it belongs for this space
    }
}
