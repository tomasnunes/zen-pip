import AppKit

/// Stashing: tucking the PiP away off a side of the screen, with a tab to bring it back.
///
/// 1. **Away:** the window flies off the side. The moment it's nearly gone, the tab covers what macOS
///    keeps on screen (it never lets a window go fully off-screen). Behind the tab the window shrinks
///    and parks, and once macOS has placed it, the tab contracts into a compact handle.
/// 2. **Parked:** the handle can be dragged, or swiped with two fingers, up and down the edge; the
///    hidden window follows. The video keeps playing, so you still hear it. If macOS moves the window
///    (it does after some space switches), it's parked again once macOS has left it somewhere.
/// 3. **Back:** clicking the handle, or dragging or swiping it inwards, slides the small window out
///    from behind it to the edge, where it grows back to its full size.
extension Engine {
    struct Stashed {
        enum Phase { case parked, returning }
        let id: CGWindowID
        let ax: AXUIElement
        let side: StashSide
        let size: CGSize       // its full size, to come back to
        let display: CGRect
        var usable: CGRect     // changes between full-screen spaces and desktops
        let level: Int         // the PiP's window level, so the tab sits just above it
        let app: String?       // the browser's bundle path, to tell whether it's playing sound
        var y: CGFloat         // top of the parked window (changes when the tab is moved)
        var parked: CGRect?    // where macOS placed it (nil while it's being parked)
        var parkedAt: CFTimeInterval = 0
        var lastParked: CGRect?  // where it was last confirmed parked (kept while it's parked again)
        var seen: CGRect?      // where it was at the last check…
        var seenSince: CFTimeInterval = 0  // …and since when, to tell where macOS leaves it from motion
        var phase = Phase.parked
    }

    /// A two-finger swipe that started on the tab.
    struct TabSwipe {
        enum Axis { case vertical, inwards, done }
        var axis: Axis?
        var moved = CGVector.zero  // until the axis is decided
        var inwards: CGFloat = 0
        var pointer: CGPoint
        var tabY: CGFloat
    }

    // MARK: Away

    /// Whether stashing at `side` is possible for the window being moved.
    func canStash(_ side: StashSide) -> Bool {
        guard settings.stash, let tg = target else { return false }
        if side == .left && StageManager.isOn {
            debug("Not stashing at the left: Stage Manager pushes windows back out from that edge")
            return false
        }
        if let until = stashBlockedUntil[side], CACurrentMediaTime() < until { return false }
        let frame = CGRect(origin: tg.pos, size: tg.size)
        return !Stash.blockedByNeighbour(side, display: tg.display, displays: WindowList.displayFrames(), windowFrame: frame)
    }

    /// Sends the window being moved off `side` of the screen.
    func stash(_ side: StashSide, velocity: CGVector) {
        if let entry = stashed, entry.id == target?.id, entry.phase == .parked { return }  // already tucked away
        if let other = stashed, other.id != target?.id { restore(other) }  // one stashed window at a time
        guard let tg = target, let area = Screens.area(for: CGRect(origin: tg.pos, size: tg.size)) else { return }
        let usable = area.usable(fullScreen: Spaces.isFullScreen(area))
        // Zen rounds each size it's given a little, so coming back to the size it was asked for last
        // time stops it shrinking a point every time.
        var full = tg.size
        if let last = fullSizes[tg.id], abs(last.width - full.width) <= 4, abs(last.height - full.height) <= 4 { full = last }
        let small = Stash.parkedSize(for: full)
        let window = WindowList.onScreen().first { $0.id == tg.id }
        let level = window?.layer ?? Int(CGWindowLevelForKey(.floatingWindow))
        let app = window.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleURL?.path }
        let entry = Stashed(id: tg.id, ax: tg.ax, side: side, size: full, display: tg.display, usable: usable, level: level,
                            app: app, y: Stash.clampY(tg.pos.y + tg.size.height / 2 - small.height / 2, height: small.height, usable: usable))
        debug("Stashing PiP window \(tg.id) to the \(side)")
        parkFailures = 0
        lastParkFailure = nil
        fullSizes[tg.id] = full  // so it comes back to this size even if Zen reopens it before then
        lastFullSize = full

        var v = Physics.capped(velocity, Physics.throwSpeed)
        v.dx = side == .right ? max(v.dx, 1) : min(v.dx, -1)  // always heading off the edge, briskly
        let width = tg.size.width, display = tg.display
        startSpring(to: Stash.position(side, size: tg.size, y: tg.pos.y, display: display), velocity: v, pointer: .stay,
                    arriveWhen: { Stash.reachedEdge(side, at: $0, width: width, display: display) }) { [weak self] in
            self?.stashed = entry
            self?.cover()
        }
    }

    /// The window has reached the edge: cover it, then shrink and park it behind the cover.
    private func cover(model: CGRect? = nil) {
        guard let entry = stashed else { return }
        // Cover where macOS reports the window, where ZenPiP last put it, and where it's about to
        // park, so nothing shows at any point.
        let model = model ?? CGRect(origin: shown, size: entry.size)
        let reported = WindowList.frame(of: entry.id) ?? model
        let cover = [reported, model, parkingFrame(entry)]
            .map { Stash.tabFrame(entry.side, covering: $0, display: entry.display) }
            .reduce(CGRect.null) { $0.union($1) }
        tabDragging = false
        stashTab.onBringBack = { [weak self] in self?.unstash() }
        stashTab.onMove = { [weak self] dy in self?.moveStash(by: dy) }
        stashTab.onDragging = { [weak self] dragging in self?.tabDragging = dragging }
        updatePlaying(entry)
        stashTab.show(entry.side, at: cover, above: entry.level, fresh: true)
        park(contract: true)
    }

    /// Where a stashed window is asked to park.
    private func parkingFrame(_ entry: Stashed) -> CGRect {
        let small = Stash.parkedSize(for: entry.size)
        return CGRect(origin: Stash.parkedPosition(entry.side, size: small, y: entry.y, display: entry.display), size: small)
    }

    /// Shrinks the stashed window and parks it against the edge, behind the tab. With `contract`, the
    /// tab then contracts from covering the whole window into the handle.
    /// `resize: false` when it's already the parked size (macOS only moved it), so it's a single,
    /// quicker move.
    private func park(contract: Bool, resize: Bool = true) {
        guard var entry = stashed else { return }
        entry.parked = nil  // checks wait until macOS has placed it again
        entry.seen = nil
        stashed = entry
        parkGeneration += 1
        let spot = parkingFrame(entry)
        // In order, after any move still on its way from the flight.
        mover.sequence(entry.ax, resize ? [.size(spot.size), .position(spot.origin)] : [.position(spot.origin)])
        let now = CACurrentMediaTime()
        settle(generation: parkGeneration, contract: contract, issued: now, since: now, last: nil)
        watchStash()
    }

    /// Waits for macOS to leave the window where it was put (small, a sliver on screen, at the right
    /// height, and still), then fits the tab to what's showing. While the window is off every display
    /// (on a space that isn't showing, or sliding with one) it waits for it to come back; a window
    /// that doesn't stay parked (it's put back on screen) is parked again.
    private func settle(generation: Int, contract: Bool, issued: CFTimeInterval, since: CFTimeInterval, last: CGRect?) {
        let delay = CACurrentMediaTime() - issued > 3 ? 0.5 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.parkGeneration, var entry = self.stashed, entry.phase == .parked else { return }
            let now = CACurrentMediaTime()
            // Mid-switch between spaces every window is reported somewhere it won't stay (or not at
            // all): start over after.
            if self.spaceSwitchUnderway() {
                return self.settle(generation: generation, contract: contract, issued: issued, since: now, last: nil)
            }
            guard let frame = self.frame(of: entry) else { return self.closed(entry) }
            let still = last.map { Stash.sameFrame($0, frame) } ?? false
            let parked = still && Stash.isParked(frame, side: entry.side, y: entry.y, display: entry.display)
            let small = Stash.parkedSize(for: entry.size)
            // Zen may keep it a little bigger than asked; after a moment, any parked size (as short as
            // Zen allows, or as narrow) will do, but never a window that didn't shrink.
            if parked && (abs(frame.height - small.height) < 4 || (now - since > 1 && Stash.looksParked(frame.size))) {
                entry.parked = frame
                entry.lastParked = frame
                entry.parkedAt = now
                self.stashed = entry
                self.debug("Parked PiP window \(entry.id) at \(frame); \(Int(Stash.showing(frame, on: entry.display))) pt left on screen")
                let handle = Stash.tabFrame(entry.side, covering: frame, display: entry.display)
                if contract { self.stashTab.animate(to: handle, duration: 0.28) } else { self.stashTab.move(to: handle) }
                return
            }
            // Off every display: on a space that isn't showing, or sliding with one. Wait for it to come back.
            guard WindowList.displayFrames().contains(where: { $0.intersects(frame) }) else {
                return self.settle(generation: generation, contract: contract, issued: issued, since: now, last: nil)
            }
            let waited = now - since
            if waited < 1 || (!still && waited < 3) {
                return self.settle(generation: generation, contract: contract, issued: issued, since: since, last: frame)
            }
            self.debug("PiP window \(entry.id) didn't stay parked: it's at \(frame)")
            let counts = now - issued < 3  // like checkStash: only an undo found within 3 s of the park counts
            if !(counts && self.parkUndone(entry, at: frame, since: issued, parked: entry.lastParked ?? self.parkingFrame(entry))) {
                self.park(contract: contract)
            }
        }
    }

    /// macOS undid a park that started at `since`, putting the window at `frame`. It counts towards
    /// giving up only when no space switch explains it and the window was put back in the same place
    /// as last time (as Stage Manager or a window manager does; the slides of a space switch don't).
    /// Returns whether it gave up.
    /// macOS putting it back flush against the edge (after space switches, and sometimes when you
    /// switch tabs) never counts: that's normal, and it's simply parked again.
    private func parkUndone(_ entry: Stashed, at frame: CGRect, since: CFTimeInterval, parked: CGRect) -> Bool {
        let stageManager = entry.side == .left && StageManager.isOn  // switched on since it was stashed
        if !stageManager {
            guard lastSpaceChange < since - 3,
                  !Stash.isPutBack(frame, parked: parked, side: entry.side, display: entry.display) else { return false }
            let again = lastParkFailure.map { Stash.sameFrame($0, frame) } ?? false
            parkFailures = again ? parkFailures + 1 : 1
            lastParkFailure = frame
            guard parkFailures >= 3 else { return false }
        }
        debug("macOS won't let PiP window \(entry.id) stay at the \(entry.side) edge; bringing it back, and not stashing there for 10 minutes")
        stashBlockedUntil[entry.side] = CACurrentMediaTime() + 600
        parkFailures = 0
        lastParkFailure = nil
        // Bring it back with the usual slide, unless something else is moving: then straight to the
        // edge, so whatever window that gesture or animation is moving stays the one it moves.
        if gestureOurs || pressed != nil || spring != nil || growTimer != nil { restore(entry) } else { unstash(from: frame) }
        return true
    }

    /// Where the stashed window is, or nil once it's been closed. (The window list can come back
    /// empty for a moment, so Accessibility has to agree before it counts as closed.)
    private func frame(of entry: Stashed) -> CGRect? {
        WindowList.frame(of: entry.id) ?? AX.frame(of: entry.ax)
    }

    private func closed(_ entry: Stashed) {
        debug("Stashed PiP window \(entry.id) was closed")
        lastFullSize = entry.size
        fullSizes[entry.id] = nil
        clearStash()
        // Zen may reopen it at once, as a sliver where it was: tuck that away without waiting for the
        // regular look every 2 s.
        for delay in [0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.rescueStrandedPip() }
        }
    }

    // MARK: Parked

    /// Moves the stashed window (and its tab) up or down the edge.
    func moveStash(by dy: CGFloat) {
        guard var entry = stashed, entry.phase == .parked, let parked = entry.parked else { return }
        let y = Stash.clampY(entry.y + dy, height: parked.height, usable: entry.usable)
        guard abs(y - entry.y) >= 0.5 else { return }
        let moved = CGRect(x: parked.minX, y: y, width: parked.width, height: parked.height)
        // Not along to where another display sits next to this edge: the hidden part would show there.
        guard !WindowList.displayFrames().contains(where: { $0 != entry.display && $0.intersects(moved) }) else { return }
        entry.y = y
        entry.parked = moved
        entry.lastParked = moved
        stashed = entry
        mover.move(entry.ax, to: CGPoint(x: parked.minX, y: y.rounded()))
        stashTab.move(to: Stash.tabFrame(entry.side, covering: moved, display: entry.display))
    }

    /// The usable area changes between full-screen spaces and desktops (where the Dock is), so after a
    /// space switch the tab and the hidden window are kept clear of the Dock. While the switch is
    /// still going, it tries again a moment later.
    func refitStash(tries: Int = 4) {
        guard var entry = stashed, entry.phase == .parked, let area = Screens.area(for: entry.display) else { return }
        if spaceSwitchUnderway() {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refitStash(tries: tries - 1) }
            }
            return
        }
        entry.usable = area.usable(fullScreen: Spaces.isFullScreen(area))
        if entry.parked == nil {
            // Still being parked: park it clear of the Dock too. (If it lands at the old height first,
            // settle sees it isn't where it belongs and parks it again.)
            entry.y = Stash.clampY(entry.y, height: Stash.parkedSize(for: entry.size).height, usable: entry.usable)
        }
        stashed = entry
        moveStash(by: 0)
    }

    /// Starts handling a two-finger swipe if it began on the tab. The whole swipe is ZenPiP's, so
    /// none of it scrolls the page underneath.
    func beginTabSwipe(at point: CGPoint) -> Bool {
        guard let entry = stashed, entry.phase == .parked, stashTab.isVisible, stashTab.frame.contains(point),
              WindowList.topmost(at: point)?.id == stashTab.windowNumber else { return false }  // not under a menu, say
        tabSwipe = TabSwipe(pointer: point, tabY: stashTab.frame.minY)
        return true
    }

    /// Up and down moves the tab (and the pointer with it, unless the pointer is set not to follow);
    /// inwards brings the window back.
    func followTabSwipe(_ delta: CGVector) {
        guard var swipe = tabSwipe, let entry = stashed else { return }
        var d = delta
        if swipe.axis == nil {
            // A slow swipe comes in small steps: decide on the movement so far, then apply all of it.
            swipe.moved.dx += delta.dx
            swipe.moved.dy += delta.dy
            d = swipe.moved
            guard hypot(d.dx, d.dy) >= 1.5 else {
                tabSwipe = swipe
                return
            }
            let inwards = entry.side == .right ? -d.dx : d.dx
            swipe.axis = inwards > abs(d.dy) ? .inwards : .vertical
        }
        switch swipe.axis {
        case .inwards:
            swipe.inwards += entry.side == .right ? -d.dx : d.dx
            if swipe.inwards > Stash.pullOut {
                swipe.axis = .done
                unstash()
            }
        case .vertical:
            moveStash(by: d.dy)
            if settings.followPointer {
                Pointer.move(to: CGPoint(x: swipe.pointer.x, y: swipe.pointer.y + stashTab.frame.minY - swipe.tabY), within: entry.display)
            }
        default:
            break
        }
        tabSwipe = swipe
    }

    /// Checks the parked window 20 times a second. macOS (and the browser) can put it back on screen
    /// at any moment: after space switches, and sometimes just from switching tabs. Looking this often
    /// tucks it away again before it's more than a glimpse. (Asking where one window is costs next to
    /// nothing; the heavier checks run only twice a second.)
    func watchStash() {
        guard stashed?.phase == .parked, stashWatch?.isValid != true else { return }
        let watch = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkStash() }
        watch.tolerance = 0.01
        RunLoop.main.add(watch, forMode: .common)
        stashWatch = watch
    }

    /// While parked: drop the tab if the window was closed, keep the tab showing (grey while the video
    /// is paused), and park the window again if macOS or the browser moved or resized it (see
    /// `Stash.check`).
    func checkStash() {
        if tabDragging && !CGEventSource.buttonState(.hidSystemState, button: .left) { tabDragging = false }  // a lost mouse-up
        guard var entry = stashed, entry.phase == .parked, !tabDragging else { return }
        guard let frame = frame(of: entry) else {
            if !spaceSwitchUnderway() { closed(entry) }  // mid-switch it may just not be reported
            return
        }
        if let area = Screens.area(for: frame), fillsScreen(frame, area) {
            debug("Stashed PiP window \(entry.id) went full screen; leaving it be")
            return clearStash()
        }
        let now = CACurrentMediaTime()
        let slowCheck = now - lastSlowStashCheck >= 0.5  // the tab's look, and that it's showing
        if slowCheck {
            lastSlowStashCheck = now
            updatePlaying(entry)
        }
        let displays = WindowList.displayFrames()
        let parked = entry.parked
        if !displays.contains(entry.display)
            || displays.contains(where: { d in d != entry.display && parked.map(d.intersects) == true }) {
            debug("The displays changed around stashed PiP window \(entry.id); putting it back")
            return restore(entry)
        }
        guard let parked else { return }  // being parked right now
        if !(entry.seen.map { Stash.sameFrame($0, frame) } ?? false) {
            entry.seen = frame
            entry.seenSince = now
        }
        stashed = entry

        switch Stash.check(frame, parked: parked, side: entry.side, display: entry.display, displays: displays,
                           still: now - entry.seenSince) {
        case .fine:
            if now - entry.parkedAt > 3 {  // it stayed put
                parkFailures = 0
                lastParkFailure = nil
            }
            if slowCheck { keepTabShowing(entry, covering: parked) }
        case .moving:
            break  // wait until macOS leaves it somewhere
        case .away:
            break  // on a space that isn't showing; it's checked again when it's back
        case .parkAgain:
            if spaceSwitchUnderway() { return }  // every window is reported somewhere it won't stay
            // Moved again straight after being parked may mean something keeps undoing it.
            if now - entry.parkedAt < 3, parkUndone(entry, at: frame, since: entry.parkedAt, parked: parked) { return }
            debug("Stashed PiP window \(entry.id) was moved to \(frame); parking it again")
            let resized = abs(frame.width - parked.width) > 3 || abs(frame.height - parked.height) > 3
            park(contract: false, resize: resized)
        }
    }

    /// Makes sure the tab is really on screen, in front of the window it covers: macOS can hide it
    /// (Stage Manager hides a window along with its stage), and the PiP can end up above it.
    private func keepTabShowing(_ entry: Stashed, covering parked: CGRect) {
        let windows = WindowList.onScreen()  // front to back
        let tab = stashTab.windowNumber.flatMap { number in windows.firstIndex { $0.id == number } }
        let pip = windows.firstIndex { $0.id == entry.id }
        let behind = tab != nil && pip != nil && pip! < tab!
        guard tab == nil || behind || !stashTab.isVisible else { return }
        let why = behind ? "behind it" : stashTab.isOnActiveSpace ? "not showing" : "not on this space"
        debug("The tab for stashed PiP window \(entry.id) was \(why); showing a new one")
        let level = max(entry.level, pip.map { windows[$0].layer } ?? 0)
        stashTab.show(entry.side, at: Stash.tabFrame(entry.side, covering: parked, display: entry.display), above: level,
                      fresh: !behind)
    }

    /// Whether macOS is sliding between spaces right now (or holding a swipe halfway). It then reports
    /// every window somewhere else, even ZenPiP's own tab, which only ZenPiP ever moves; so a tab
    /// reported away from where ZenPiP put it means a switch is under way. (Before the first stash
    /// there's no tab to tell by, and this says no.)
    private func spaceSwitchUnderway() -> Bool {
        guard let number = stashTab.windowNumber, let reported = WindowList.frame(of: number) else { return false }
        return abs(reported.minX - stashTab.frame.minX) > 2 || abs(reported.minY - stashTab.frame.minY) > 2
    }

    /// Glass showing the video's colours while the browser plays sound; grey while it's quiet.
    private func updatePlaying(_ entry: Stashed) {
        let playing = entry.app.flatMap { Audio.isPlaying(appAt: $0) } ?? true
        if playing != stashTab.playing { debug("Stashed PiP window \(entry.id) is \(playing ? "playing" : "paused")") }
        stashTab.setPlaying(playing)
    }

    // MARK: Back

    /// Brings the stashed window back: it slides out small from behind the tab, then grows.
    /// `start` is where the window is, when that's known better than from where it was parked.
    func unstash(from start: CGRect? = nil) {
        guard var entry = stashed, entry.phase == .parked else { return }
        let from: CGRect
        if let start {
            from = start
        } else if let parked = entry.parked {
            // If macOS has just put it back on screen, it comes out from there.
            let now = frame(of: entry)
            let moved = now.map { f in WindowList.displayFrames().contains { $0.intersects(f) }
                                       && Stash.isDisplaced(f, from: parked, display: entry.display) } ?? false
            from = moved ? now! : parked
        } else {
            from = parkingFrame(entry)  // still on its way there, and moves are applied in order
        }
        entry.phase = .returning
        stashed = entry
        stopWatchingStash()
        stashTab.hide()
        debug("Bringing PiP window \(entry.id) back")
        finishSpring()
        settings = Settings.load()
        if let area = Screens.area(for: entry.display) {
            entry.usable = area.usable(fullScreen: Spaces.isFullScreen(area))
            stashed = entry
        }
        guard retarget(Pip(id: entry.id, ax: entry.ax, frame: from)), let tg = target else { return clearStash() }
        let dest = CGPoint(x: entry.side == .right ? tg.bounds.maxX : tg.bounds.minX,
                           y: min(tg.bounds.maxY, max(tg.bounds.minY, from.minY)))
        startSpring(to: dest, velocity: CGVector(dx: entry.side == .right ? -1.5 : 1.5, dy: 0), pointer: .stay,
                    onArrive: { [weak self] in self?.grow(entry) })
    }

    /// The full-size frame a window coming back from the edge grows into, from its small frame:
    /// against the same edge, keeping its middle level.
    private func grownFrame(from small: CGRect, _ entry: Stashed) -> CGRect {
        let x = entry.side == .right ? small.maxX - entry.size.width : small.minX
        return CGRect(origin: CGPoint(x: x, y: fullY(small.midY - entry.size.height / 2, entry)), size: entry.size)
    }

    /// A full-size window's top, kept within the usable area by the usual edge margin (so one that
    /// rested on the bottom edge comes back onto it).
    private func fullY(_ y: CGFloat, _ entry: Stashed) -> CGFloat {
        let margin = settings.edgeMargin
        return min(max(entry.usable.minY + margin, entry.usable.maxY - entry.size.height - margin), max(entry.usable.minY + margin, y))
    }

    /// Grows the window back to its full size against the edge, keeping its middle level.
    private func grow(_ entry: Stashed) {
        guard let tg = target, tg.id == entry.id else { return finishGrowing() }
        let from = CGRect(origin: shown, size: tg.size)
        let to = grownFrame(from: from, entry)
        growTarget = to
        let started = CACurrentMediaTime()
        growTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let k = min(1, (CACurrentMediaTime() - started) / 0.2)
            let e = 1 - pow(1 - k, 3)  // ease out
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(e) }
            let r = CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                           width: mix(from.width, to.width), height: mix(from.height, to.height))
            self?.mover.sequence(entry.ax, [.size(r.size), .position(r.origin)])
            if k >= 1 {
                timer.invalidate()
                self?.finishGrowing(at: to, entry: entry)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        growTimer = timer
    }

    /// Ends a grow-back (also when a click or swipe interrupts it), leaving the window at full size.
    /// `runPending: false` when a gesture is about to take over (a space check run now could pick up
    /// another window before the gesture claims this one; it runs when the gesture ends).
    func finishGrowing(at frame: CGRect? = nil, entry: Stashed? = nil, runPending: Bool = true) {
        growTimer?.invalidate()
        growTimer = nil
        let grown = frame ?? growTarget
        growTarget = nil
        guard let entry = entry ?? stashed, entry.phase == .returning else { return }
        let ours = target == nil || target?.id == entry.id
        let final = grown ?? grownFrame(from: ours ? CGRect(origin: shown, size: target?.size ?? .zero)
                                                   : self.frame(of: entry) ?? parkingFrame(entry), entry)
        mover.sequence(entry.ax, [.size(entry.size), .position(final.origin)])
        if stashed?.id == entry.id { stashed = nil }
        // Only take over if no other window has been picked up in the meantime.
        if ours { _ = retarget(Pip(id: entry.id, ax: entry.ax, frame: final)) }
        fullSizes[entry.id] = entry.size
        lastFullSize = entry.size
        checkSize(entry, until: CACurrentMediaTime() + 0.8)
        if runPending { runPendingSpaceCheck() }
    }

    /// Zen fixes up each size it's given a moment later, so after the many sizes of a grow-back an
    /// older one can land last, leaving the window a little smaller than it was. In the moment right
    /// after it comes back (when those late sizes land), check, and put it right, keeping it against
    /// any edge it's on. Never while the mouse button is down: that may be you resizing it.
    private func checkSize(_ entry: Stashed, until: CFTimeInterval, fixes: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, CACurrentMediaTime() < until, self.stashed?.id != entry.id else { return }  // stashed again
            // Not listed for a moment (as during a space switch): look again.
            guard let frame = WindowList.frame(of: entry.id) else { return self.checkSize(entry, until: until, fixes: fixes) }
            guard let area = Screens.area(for: frame), !self.fillsScreen(frame, area) else { return }  // full screen
            let busy = self.gestureOurs || self.growTimer != nil || (self.spring != nil && self.target?.id == entry.id)
                || self.pressed != nil || CGEventSource.buttonState(.hidSystemState, button: .left)
            let wrong = abs(frame.width - entry.size.width) > 3 || abs(frame.height - entry.size.height) > 3
            if busy || !wrong { return self.checkSize(entry, until: until, fixes: fixes) }
            guard fixes < 2 else { return }
            let fullScreen = Spaces.isFullScreen(area)
            let before = area.bounds(for: frame.size, fullScreen: fullScreen, margin: self.settings.edgeMargin)
            let after = area.bounds(for: entry.size, fullScreen: fullScreen, margin: self.settings.edgeMargin)
            var origin = after.clamp(frame.origin)
            if frame.minX >= before.maxX - 2 { origin.x = after.maxX }  // keep it against the right or bottom edge
            if frame.minY >= before.maxY - 2 { origin.y = after.maxY }
            self.debug("PiP window \(entry.id) came back at \(frame.size) instead of \(entry.size); putting that right")
            self.mover.sequence(entry.ax, [.size(entry.size), .position(origin)])
            if self.target?.id == entry.id { _ = self.retarget(Pip(id: entry.id, ax: entry.ax, frame: CGRect(origin: origin, size: entry.size))) }
            self.checkSize(entry, until: until, fixes: fixes + 1)
        }
    }

    // MARK: Stranded

    /// Looks for a PiP left as a sliver at a side with no tab, and tucks it away properly. That
    /// happens when Zen reopens a PiP where a stashed one was, or a PiP leaving full screen goes
    /// back to where it was before. A window has to be found there twice, a moment apart, so one
    /// sliding past with a space switch isn't caught.
    func rescueStrandedPip(confirming seen: (id: CGWindowID, frame: CGRect)? = nil) {
        guard stashed?.phase != .returning, spring == nil, growTimer == nil, !gestureOurs, pressed == nil,
              !CGEventSource.buttonState(.hidSystemState, button: .left) else { return }
        settings = Settings.load()  // stashing may have been switched off since the last gesture
        guard settings.stash else { return }
        let displays = WindowList.displayFrames()
        if spaceSwitchUnderway() { return }  // every window is reported somewhere it won't stay
        for w in WindowList.onScreen() where isCandidate(w) && w.id != stashed?.id {
            guard let area = Screens.area(for: w.frame),
                  let side = Stash.strandedSide(w.frame, display: area.frame, displays: displays) else { continue }
            if side == .left && StageManager.isOn { continue }  // Stage Manager pushes it back out anyway
            guard let pip = verify(id: w.id, pid: w.pid, frame: w.frame) else { continue }  // not a PiP
            guard let seen, seen.id == w.id, Stash.sameFrame(seen.frame, w.frame) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.rescueStrandedPip(confirming: (w.id, w.frame))
                }
                return
            }
            // Its full size: what it had (if it was only pushed off), or, if it's still the parked size
            // (as short as Zen allows, or as narrow for a tall video), what it came back to last time.
            let usable = area.usable(fullScreen: Spaces.isFullScreen(area))
            var full = pip.frame.size
            if Stash.looksParked(full) {
                full = Stash.fullSize(forParked: full, width: fullSizes[pip.id]?.width ?? lastFullSize?.width,
                                      usable: usable, margin: settings.edgeMargin)
            }
            let blocked = stashBlockedUntil[side].map { CACurrentMediaTime() < $0 } ?? false
            if blocked || stashed != nil {
                // Stashing at that side keeps being undone, or another PiP is already stashed (one at a
                // time): put it fully back on screen at the edge instead.
                let margin = settings.edgeMargin
                let x = side == .right ? usable.maxX - full.width - margin : usable.minX + margin
                let y = min(max(usable.minY + margin, usable.maxY - full.height - margin),
                            max(usable.minY + margin, pip.frame.midY - full.height / 2))
                debug("PiP window \(pip.id) was left at the \(side) edge and can't be stashed now; putting it back on screen")
                mover.sequence(pip.ax, [.size(full), .position(CGPoint(x: x, y: y))])
                // Zen may land the small size late, as after a grow: put that right too.
                checkSize(Stashed(id: pip.id, ax: pip.ax, side: side, size: full, display: area.frame, usable: usable,
                                  level: w.layer, app: nil, y: y), until: CACurrentMediaTime() + 0.8)
                return
            }
            guard retarget(pip) else { return }
            let small = Stash.parkedSize(for: full)
            debug("PiP window \(pip.id) was left at the \(side) edge without its tab, at \(pip.frame); tucking it away")
            stashed = Stashed(id: pip.id, ax: pip.ax, side: side, size: full, display: area.frame, usable: usable, level: w.layer,
                              app: NSRunningApplication(processIdentifier: w.pid)?.bundleURL?.path,
                              y: Stash.clampY(pip.frame.midY - small.height / 2, height: small.height, usable: usable))
            parkFailures = 0
            lastParkFailure = nil
            cover(model: pip.frame)
            return
        }
    }

    /// Puts a stashed window straight back at its edge, without animating (when another is stashed,
    /// or the displays changed).
    private func restore(_ entry: Stashed) {
        clearStash()
        let x = entry.side == .right ? entry.usable.maxX - entry.size.width - settings.edgeMargin
                                     : entry.usable.minX + settings.edgeMargin
        let y = fullY(entry.y + Stash.parkedSize(for: entry.size).height / 2 - entry.size.height / 2, entry)
        mover.sequence(entry.ax, [.size(entry.size), .position(CGPoint(x: x, y: y))])
        checkSize(entry, until: CACurrentMediaTime() + 0.8)  // Zen may land an older size late, as after a grow
    }

    /// When ZenPiP is stopped (uninstalled, or replaced by a new build), a tucked-away window is put
    /// back first, since nothing would be left to bring it back.
    func restoreBeforeQuitting() {
        guard let entry = stashed else { return }
        restore(entry)
        mover.finish()
    }

    func clearStash() {
        stashed = nil
        growTimer?.invalidate()
        growTimer = nil
        growTarget = nil
        tabDragging = false
        stopWatchingStash()
        stashTab.hide()
    }

    private func stopWatchingStash() {
        stashWatch?.invalidate()
        stashWatch = nil
    }
}
