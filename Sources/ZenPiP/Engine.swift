import AppKit

/// The gesture engine. It watches trackpad scrolls and mouse clicks system-wide, picks out the ones
/// aimed at a PiP window, and moves that window. Everything runs on the main thread, apart from the
/// actual window moves (see `WindowMover`).
///
/// The work is split across files by topic:
/// - Engine.swift: setup, the event tap, and finding PiP windows
/// - Engine+Trackpad.swift: two-finger swipes and flicks
/// - Engine+Mouse.swift: click-and-drag, click-and-throw
/// - Engine+Spaces.swift: following the bottom edge between full-screen spaces and desktops
/// - Engine+Stash.swift: tucking the window away at a side, with a tab to bring it back
/// - Engine+Animation.swift: the spring that carries a window to where it's going
final class Engine {
    /// A confirmed PiP window.
    struct Pip {
        let id: CGWindowID
        let ax: AXUIElement
        let frame: CGRect
    }

    /// The window being moved or animated.
    struct Target {
        let id: CGWindowID
        let ax: AXUIElement
        let size: CGSize
        let display: CGRect
        var pos: CGPoint        // model position; may be past an edge while bouncing
        var bounds: Bounds
        var softBounds: Bounds  // while animating, overshoot beyond these is squeezed
    }

    /// What the pointer does while a window springs into place.
    enum PointerMode { case stay, center }

    struct Spring {
        var dest: CGPoint
        var vel: CGVector
        var pointer: PointerMode
        let started: CFTimeInterval
        var onArrive: (() -> Void)?  // runs once the window gets there (not if it's caught first)
        var arriveWhen: ((CGPoint) -> Bool)?  // counts as arrived as soon as this is true
    }

    // Setup
    var tap: CFMachPort?
    let mover = WindowMover()
    var settings = Settings.load()
    var appNapActivity: NSObjectProtocol?

    // What we know about windows
    var isBrowserByPid: [pid_t: Bool] = [:]
    var pipByWindow: [CGWindowID: AXUIElement] = [:]     // confirmed PiP windows
    var notPipUntil: [CGWindowID: CFTimeInterval] = [:]  // recently checked windows that aren't

    // The window being moved
    var target: Target?
    var shown = CGPoint.zero              // where the window is actually drawn
    var lastShownAt: CFTimeInterval = 0
    var lastApplied = CGPoint(x: CGFloat.nan, y: CGFloat.nan)

    // Trackpad gesture
    var gestureDecided = false            // the current swipe has been checked for a PiP
    var gestureOurs = false               // …and it is on a PiP, so its events are swallowed
    var momentumOurs = false              // macOS's coasting after our swipe is swallowed too
    var moved = false                     // the fingers actually moved the window
    var caughtDest: CGPoint?              // where a window caught in flight was heading
    var lastScrollTime: Double = 0
    var samples: [Physics.Sample] = []
    var pointerOrigin: CGPoint?
    var pointerOffset = CGVector.zero
    var gestureStart = CGPoint.zero        // where the window was when the swipe began

    // Mouse
    var pressed: (id: CGWindowID, pid: pid_t, frame: CGRect)?  // a PiP the button went down on
    var interrupted: (id: CGWindowID, dest: CGPoint)?          // a flight stopped by a click
    var buttonDown = false
    var dragPoints: [(t: Double, p: CGPoint)] = []             // pointer positions while held

    // Spaces
    var settledMode: [String: Bool] = [:]  // full screen or not, per display, after the last check
    var modeBeforeSwitch: [String: Bool] = [:]  // the same, as it was when the latest switch began
    var pendingSpaceCheck = false
    var spaceMovesLeft = 0

    // Stashing
    var stashed: Stashed?
    let stashTab = StashTab()
    var stashWatch: Timer?
    var lastSlowStashCheck: CFTimeInterval = 0
    var parkGeneration = 0  // so only the latest park waits for macOS to place the window
    var parkFailures = 0    // parks undone straight away, with no space switch to explain it
    var lastParkFailure: CGRect?  // where macOS put the window back the last time
    var stashBlockedUntil: [StashSide: CFTimeInterval] = [:]
    var tabSwipe: TabSwipe?
    var lastSpaceChange: CFTimeInterval = 0
    var tabDragging = false
    var growTimer: Timer?
    var growTarget: CGRect?  // the full-size frame a returning window is growing into
    var fullSizes: [CGWindowID: CGSize] = [:]  // the size each window last came back to, so it doesn't drift
    var lastFullSize: CGSize?                  // for a PiP Zen reopened where a stashed one was
    var spaceFrames: [CGWindowID: (frame: CGRect, since: CFTimeInterval)] = [:]  // where each window is after a space switch, and since when
    var spaceLooksLeft = 0

    // Animation
    var spring: Spring?
    var timer: Timer?
    var animationActivity: NSObjectProtocol?
    var lastTick: CFTimeInterval = 0

    func debug(_ message: @autoclosure () -> String) {
        if settings.debug { Log.write(message()) }
    }

    // MARK: - Starting up

    func start() {
        // macOS "naps" background apps, which makes animations choppy. This keeps ZenPiP awake
        // without stopping the Mac from sleeping.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Moving Picture-in-Picture windows smoothly")
        // A busy browser must never hold up the trackpad for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AX.timeout)
        mover.onWindowGone = { [weak self] window in self?.windowGone(window) }
        observeSystem()

        if PrivateAPI.axGetWindow == nil { Log.write("Note: window lookup is unavailable; matching PiP windows by position") }
        if PrivateAPI.spaceType == nil { Log.write("Note: space detection is unavailable; full-screen spaces use the normal bottom edge") }

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            installTap()
        } else {
            Log.write("Waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility > ZenPiP)")
            let waiting = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.installTap()
            }
            waiting.tolerance = 1
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isBrowserByPid.removeAll()
            self?.pipByWindow.removeAll()
            self?.notPipUntil.removeAll()
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleSpaceCheck() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.scheduleSpaceCheck() }
        for area in Screens.areas() { settledMode[area.uuid ?? ""] = Spaces.isFullScreen(area) }
    }

    private func installTap() {
        let events: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<Engine>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("Could not start listening to the trackpad; retrying in 5 seconds")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.installTap() }
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // If the permission is taken away while the tap is live, input can stall. Quit instead and let
        // launchd start ZenPiP again, which then waits for permission.
        let watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard Self.stillTrusted() else {
                Log.write("Accessibility permission was removed; restarting")
                exit(1)
            }
            self?.rescueStrandedPip()
        }
        watchdog.tolerance = 1
        Log.write("Ready")
    }

    /// Whether ZenPiP still has Accessibility permission. `AXIsProcessTrusted()` keeps saying yes
    /// when ZenPiP is removed from the list (rather than switched off), so this also asks for a new
    /// event tap, which macOS refuses once the permission is gone. The test tap watches only
    /// other-button drags and is closed at once, so it never holds up input.
    private static func stillTrusted() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.otherMouseDragged.rawValue,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return false }
        CFMachPortInvalidate(probe)
        return true
    }

    // MARK: - The event tap

    /// Called for every scroll and left-button event on the system, so it has to be quick.
    /// Returning nil swallows the event; anything that isn't for a PiP passes straight through.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS paused the tap and events were missed, so a swipe or click in progress is over.
            if gestureOurs && tabSwipe == nil { release(at: ProcessInfo.processInfo.systemUptime * 1000) }
            gestureDecided = false
            gestureOurs = false
            momentumOurs = false
            tabSwipe = nil
            pressed = nil
            interrupted = nil
            buttonDown = false
            dragPoints = []
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .scrollWheel:
            if handleScroll(event) { return nil }
        case .leftMouseDown:
            // Only note it here; looking up the window happens after the click has gone through.
            let location = event.location
            buttonDown = true
            dragPoints = [(CACurrentMediaTime() * 1000, location)]
            DispatchQueue.main.async { self.mouseDown(at: location) }
        case .leftMouseDragged:
            if buttonDown {
                dragPoints.append((CACurrentMediaTime() * 1000, event.location))
                if dragPoints.count > 24 { dragPoints.removeFirst(dragPoints.count - 24) }
            }
        case .leftMouseUp:
            let command = event.flags.contains(.maskCommand)
            let upTime = CACurrentMediaTime() * 1000
            let points = dragPoints
            buttonDown = false
            dragPoints = []
            DispatchQueue.main.async { self.mouseUp(command: command, points: points, upTime: upTime) }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Finding PiP windows

    func isBrowser(_ pid: pid_t) -> Bool {
        if let known = isBrowserByPid[pid] { return known }
        let isBrowser = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(browserBundleIDs.contains) ?? false
        isBrowserByPid[pid] = isBrowser
        return isBrowser
    }

    /// A quick check before asking the browser anything: an always-on-top browser window of video size.
    func isCandidate(_ w: WindowInfo) -> Bool {
        w.layer > 0 && w.layer < 20 && isBrowser(w.pid) && w.frame.width >= 80 && w.frame.height >= 45
    }

    /// A PiP blown up to full screen is left alone.
    func fillsScreen(_ frame: CGRect, _ area: ScreenArea) -> Bool {
        frame.width >= area.visible.width * 0.9 && frame.height >= area.visible.height * 0.9
    }

    /// The PiP window under a point, if there is one and nothing else is in front of it.
    func findPip(at point: CGPoint) -> Pip? {
        guard let w = WindowList.topmost(at: point), isCandidate(w) else {
            if settings.debug, let pip = WindowList.onScreen().first(where: { isCandidate($0) && $0.frame.contains(point) }) {
                let cover = WindowList.topmost(at: point)
                debug("PiP window \(pip.id) is under the pointer but covered by \(cover?.owner ?? "nothing") (layer \(cover?.layer ?? 0))")
            }
            return nil
        }
        guard let pip = verify(id: w.id, pid: w.pid, frame: w.frame) else { return nil }
        if let area = Screens.area(for: w.frame), fillsScreen(w.frame, area) { return nil }
        return pip
    }

    /// Confirms a window is a video PiP by its title. Answers are remembered so repeat gestures never
    /// wait on the browser: PiP windows for good, other windows for a few seconds.
    func verify(id: CGWindowID, pid: pid_t, frame: CGRect) -> Pip? {
        if let ax = pipByWindow[id] { return Pip(id: id, ax: ax, frame: frame) }
        let now = CACurrentMediaTime()
        if let until = notPipUntil[id], until > now { return nil }

        let ax = AX.window(pid: pid, id: id, frame: frame)
        let title = ax.flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
        guard let ax, isPipTitle(title) else {
            debug("Window \(id) is not a PiP window (title: \"\(title)\", reachable: \(ax != nil))")
            if notPipUntil.count > 50 { notPipUntil = notPipUntil.filter { $0.value > now } }
            notPipUntil[id] = now + (ax == nil ? 0.5 : 3)  // a browser that didn't answer may just be busy
            return nil
        }
        if pipByWindow.count > 20 { pipByWindow.removeAll() }
        pipByWindow[id] = ax
        return Pip(id: id, ax: ax, frame: frame)
    }

    /// Makes a PiP the window being moved, with the bounds of the display and space it's on.
    /// `fullScreen` says which kind of space that is; by default macOS is asked.
    func retarget(_ pip: Pip, fullScreen: Bool? = nil) -> Bool {
        guard let area = Screens.area(for: pip.frame) else { return false }
        let fullScreen = fullScreen ?? Spaces.isFullScreen(area)
        let bounds = area.bounds(for: pip.frame.size, fullScreen: fullScreen, margin: settings.edgeMargin)
        lastApplied = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        target = Target(id: pip.id, ax: pip.ax, size: pip.frame.size, display: area.frame,
                        pos: pip.frame.origin, bounds: bounds, softBounds: bounds)
        shown = pip.frame.origin
        return true
    }

    /// The window being moved disappeared (closed, or the browser quit).
    func windowGone(_ window: AXUIElement) {
        // Forget its Accessibility element. If the window is in fact still there (Accessibility lost
        // track of it), a fresh one is looked up next time, and a stashed one left as a sliver is
        // tucked away again by `rescueStrandedPip`.
        for (id, ax) in pipByWindow where CFEqual(ax, window) {
            pipByWindow[id] = nil
            if WindowList.frame(of: id) == nil { fullSizes[id] = nil }
        }
        if let entry = stashed, CFEqual(entry.ax, window) { clearStash() }
        guard let tg = target, CFEqual(tg.ax, window) else { return }
        debug("PiP window \(tg.id) went away")
        // A swipe in progress stays swallowed (with nothing left to move), so it doesn't
        // suddenly scroll whatever was underneath.
        target = nil
        spring = nil
        endTimer()
        runPendingSpaceCheck()
    }

    /// Draws the window at `p`.
    func show(_ p: CGPoint) {
        guard let tg = target else { return }
        shown = p
        lastShownAt = CACurrentMediaTime()
        let rounded = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        if rounded == lastApplied { return }
        lastApplied = rounded
        mover.move(tg.ax, to: rounded)
    }
}
