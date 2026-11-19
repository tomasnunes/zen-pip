import AppKit

/// The bottom limit depends on the space: in a full-screen app the Dock is hidden, so a PiP can go
/// all the way down; on a normal desktop it stays above the Dock. When you switch between them, a
/// PiP resting on the bottom edge follows it, and one that would now sit under the Dock moves up.
extension Engine {
    func scheduleSpaceCheck() {
        spaceMovesLeft = 4  // enough for a couple of PiP windows, and stops one that won't move from looping
        // Once the switch has settled, and again in case the first look was mid-animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.checkSpaces() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.checkSpaces() }
    }

    func runPendingSpaceCheck() {
        if pendingSpaceCheck { checkSpaces() }
    }

    /// Moves PiP windows to suit the space now showing, one window at a time; the check runs again
    /// when each one comes to rest.
    private func checkSpaces() {
        let busy = gestureOurs || spring != nil || pressed != nil
            || CGEventSource.buttonState(.hidSystemState, button: .left)
        if busy {
            pendingSpaceCheck = true  // don't fight the user; try again when things are at rest
            return
        }
        pendingSpaceCheck = false
        settings = Settings.load()

        var nowFullScreen: [String: Bool] = [:]
        for area in Screens.areas() { nowFullScreen[area.uuid ?? ""] = Spaces.isFullScreen(area) }

        if spaceMovesLeft > 0 {
            for w in WindowList.onScreen() where isCandidate(w) {
                guard let area = Screens.area(for: w.frame), !fillsScreen(w.frame, area) else { continue }
                let key = area.uuid ?? ""
                let fullScreen = nowFullScreen[key] ?? false
                let before = settledMode[key].map { [$0] } ?? [true, false]
                let dest = area.destinationAfterSpaceChange(w.frame, oldModes: before, newMode: fullScreen, margin: settings.edgeMargin)
                guard hypot(dest.x - w.frame.minX, dest.y - w.frame.minY) >= 2,  // ignore a point of rounding
                      let pip = verify(id: w.id, pid: w.pid, frame: w.frame) else { continue }

                debug("Space changed (full screen: \(fullScreen)); moving PiP window \(w.id) to \(dest)")
                spaceMovesLeft -= 1
                finishSpring()
                guard retarget(pip, fullScreen: fullScreen) else { continue }
                startSpring(to: dest, velocity: .zero, pointer: .stay)
                pendingSpaceCheck = true  // look at the next window once this one has arrived
                return
            }
        }
        settledMode = nowFullScreen  // every window is where it belongs for this space
    }
}
