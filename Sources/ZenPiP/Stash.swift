import AppKit

// Tucking the PiP away at a side of the screen, like macOS's own Picture-in-Picture: the window
// slides off the edge (and keeps playing, so you still hear it), leaving a small tab with an arrow.
//
// macOS never lets an app move another app's window completely off-screen: a sliver always stays
// visible. So ZenPiP covers that sliver with a tab of its own, at the moment the window reaches the
// edge. Behind the tab the window shrinks and parks, and the tab contracts into a slim handle.

enum StashSide { case left, right }

/// The rules for stashing. Pure, so the self-test covers them.
enum Stash {
    static let pushPast: CGFloat = 35        // a swipe that leaves the window this far past a side edge stashes it
    static let dragOffScreen: CGFloat = 0.3  // a mouse drag that leaves this much of the window off a side stashes it
    static let parkedHeight: CGFloat = 80    // the window's height while stashed (the smallest Zen allows)
    static let minTabWidth: CGFloat = 16
    static let parkShowing: CGFloat = 21     // asked to leave this much on screen when parked (macOS may insist on more)
    static let maxShowing: CGFloat = 44      // more than this showing means it isn't parked (macOS may insist on about 40)
    static let coverAt: CGFloat = 64         // the tab covers the window once this little of it is left on screen
    static let pullOut: CGFloat = 24         // dragging or swiping the tab this far inwards brings the window back
    static let cornerRadius: CGFloat = 10
    static let edgeGap: CGFloat = 8          // kept between the tab and the menu bar or Dock

    /// Whether a release should stash the window, and at which side.
    /// - `pos`: where the window was let go; `start`: where it was when the gesture began.
    /// - `pushedPast`: how far past the side bound counts as pushing it away.
    static func side(releasedAt pos: CGPoint, startedAt start: CGPoint, velocity v: CGVector,
                     isThrow: Bool, pushedPast: CGFloat, bounds b: Bounds) -> StashSide? {
        if pos.x > b.maxX + pushedPast { return .right }
        if pos.x < b.minX - pushedPast { return .left }
        // Flicking it again towards the side it was already resting on.
        guard isThrow, abs(v.dx) >= 0.8 * hypot(v.dx, v.dy) else { return nil }
        if v.dx > 0 && start.x >= b.maxX - 2 { return .right }
        if v.dx < 0 && start.x <= b.minX + 2 { return .left }
        return nil
    }

    /// Where a stashed window heads: just past the side of the display (macOS stops it a little short).
    static func position(_ side: StashSide, size: CGSize, y: CGFloat, display: CGRect) -> CGPoint {
        CGPoint(x: side == .right ? display.maxX + 1 : display.minX - size.width - 1, y: y)
    }

    /// Where a parked window is asked to go: with just `parkShowing` points left on screen. (Asking for
    /// it to go fully off-screen makes macOS pull it back to about 40 points; asking for a little to
    /// stay may be accepted as it is. The tab is sized to whatever macOS actually allows.)
    static func parkedPosition(_ side: StashSide, size: CGSize, y: CGFloat, display: CGRect) -> CGPoint {
        CGPoint(x: side == .right ? display.maxX - parkShowing : display.minX - size.width + parkShowing, y: y)
    }

    /// Whether a window flying off `side` is nearly gone, so it's time to cover it.
    static func reachedEdge(_ side: StashSide, at p: CGPoint, width: CGFloat, display: CGRect) -> Bool {
        side == .right ? p.x >= display.maxX - coverAt : p.x + width <= display.minX + coverAt
    }

    /// The size a window shrinks to while stashed: as short as Zen allows, keeping the video's shape
    /// (Zen's smallest PiP is 120 × 80 points).
    static func parkedSize(for size: CGSize) -> CGSize {
        let aspect = size.width / max(size.height, 1)
        var h = parkedHeight, w = (h * aspect).rounded()
        if w < 120 { w = 120; h = (w / aspect).rounded() }
        if h < 80 { h = 80; w = (h * aspect).rounded() }
        return CGSize(width: min(w, size.width), height: min(h, size.height))
    }

    /// Whether a window is still the size it was parked at: as short as Zen allows, or, for a tall
    /// video, as narrow. (Its real size has to come from somewhere else then.)
    static func looksParked(_ size: CGSize) -> Bool {
        size.height < parkedHeight + 12 || size.width < 124
    }

    /// The size to bring back a window found still at its parked size: `width` wide if that's known
    /// (what it came back to last time), otherwise Zen's default for a large video (a third of the
    /// width for a wide one, a quarter of the height for a tall one), keeping its shape and always
    /// fitting on screen.
    static func fullSize(forParked parked: CGSize, width: CGFloat?, usable: CGRect, margin: CGFloat) -> CGSize {
        let aspect = parked.width / max(parked.height, 1)
        let zenDefault = aspect >= 1 ? usable.width / 3 : usable.height / 4 * aspect
        var w = max(120, width ?? zenDefault)  // Zen's narrowest PiP is 120 pt
        w = min(w, usable.width - 2 * margin, (usable.height - 2 * margin) * aspect)
        return CGSize(width: w.rounded(), height: (w / aspect).rounded())
    }

    /// Keeps a parked window's top within the usable area, leaving room for the tab's rounded ends
    /// clear of the menu bar and the Dock.
    static func clampY(_ y: CGFloat, height: CGFloat, usable: CGRect) -> CGFloat {
        let room = edgeGap + cornerRadius
        return min(usable.maxY - height - room, max(usable.minY + room, y))
    }

    /// The tab covers exactly the strip of the window macOS keeps on screen, and reaches a little above
    /// and below it, so its rounded inside corners never show the window's own edges.
    static func tabFrame(_ side: StashSide, covering window: CGRect, display: CGRect) -> CGRect {
        let width = tabWidth(covering: showing(window, on: display))
        let x = side == .right ? display.maxX - width : display.minX
        return CGRect(x: x, y: window.minY - cornerRadius, width: width, height: window.height + 2 * cornerRadius).integral
    }

    /// How wide the tab is to cover `showing` points of window, with a point to spare.
    static func tabWidth(covering showing: CGFloat) -> CGFloat {
        max(minTabWidth, showing + 1).rounded(.up)
    }

    /// How long a moved window has to stay put before it's parked again. While switching spaces, macOS
    /// slides windows around (and reports them far off-screen) before it leaves them somewhere; only
    /// where it leaves them counts.
    static let stillFor: CFTimeInterval = 0.2

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
    }

    /// How much of a window's width is on the display.
    static func showing(_ frame: CGRect, on display: CGRect) -> CGFloat {
        let visible = frame.intersection(display)
        return visible.isNull ? 0 : visible.width
    }

    /// Whether a window is parked at `side`: just a sliver of it on screen, at the parked height.
    static func isParked(_ frame: CGRect, side: StashSide, y: CGFloat, display: CGRect) -> Bool {
        let past = side == .right ? frame.maxX > display.maxX : frame.minX < display.minX
        return past && abs(frame.minY - y) < 4 && (1...maxShowing).contains(showing(frame, on: display))
    }

    /// Whether a parked window has really been moved: resized, shifted up or down, or showing more of
    /// itself than the tab fitted to it covers. Rounding wobble (a point here or there) doesn't count.
    static func isDisplaced(_ frame: CGRect, from parked: CGRect, display: CGRect) -> Bool {
        let resized = abs(frame.width - parked.width) > 3 || abs(frame.height - parked.height) > 3
        let shifted = abs(frame.minY - parked.minY) > 4
        let now = showing(frame, on: display), before = showing(parked, on: display)
        return resized || shifted || now > tabWidth(covering: before) || (now == 0 && before > 0)
    }

    /// The side a window has been left stuck at, with just a sliver showing and nothing else to hold
    /// it there (no display next door that it's partly on).
    static func strandedSide(_ frame: CGRect, display: CGRect, displays: [CGRect]) -> StashSide? {
        guard (1...maxShowing).contains(showing(frame, on: display)), frame.minY < display.maxY, frame.maxY > display.minY,
              !displays.contains(where: { $0 != display && $0.intersects(frame) }) else { return nil }
        if frame.maxX > display.maxX { return .right }
        if frame.minX < display.minX { return .left }
        return nil
    }

    enum Check: Equatable { case fine, away, moving, parkAgain }

    /// What to do about a parked window found at `frame`, which has been there for `still` seconds.
    /// - `away`: it's off every display, on a space that isn't showing or sliding with one. Wait.
    /// - `moving`: it's been moved and hasn't stopped yet. Wait until macOS leaves it somewhere.
    /// - `parkAgain`: macOS has left it somewhere else, such as back on screen.
    /// A window macOS has put back on screen in one go (as it does at the end of some space
    /// switches) lands flush against the edge, at the same height and size, so it's parked again
    /// straight away rather than after waiting to see that it has stopped.
    static func check(_ frame: CGRect, parked: CGRect, side: StashSide, display: CGRect, displays: [CGRect],
                      still: CFTimeInterval) -> Check {
        guard isDisplaced(frame, from: parked, display: display) else { return .fine }
        guard displays.contains(where: { $0.intersects(frame) }) else { return .away }
        return isPutBack(frame, parked: parked, side: side, display: display) || still >= stillFor ? .parkAgain : .moving
    }

    /// Whether macOS has put a parked window back on screen in one go: flush against the edge it was
    /// parked at, at the same height and size.
    static func isPutBack(_ frame: CGRect, parked: CGRect, side: StashSide, display: CGRect) -> Bool {
        let flush = side == .right ? abs(frame.maxX - display.maxX) <= 2 : abs(frame.minX - display.minX) <= 2
        let sameSize = abs(frame.width - parked.width) <= 3 && abs(frame.height - parked.height) <= 3
        return flush && display.contains(frame) && sameSize && abs(frame.minY - parked.minY) <= 4
    }

    /// Whether stashing at `side` would just move the window onto another display next door.
    static func blockedByNeighbour(_ side: StashSide, display: CGRect, displays: [CGRect], windowFrame: CGRect) -> Bool {
        let parked = CGRect(origin: position(side, size: windowFrame.size, y: windowFrame.minY, display: display),
                            size: windowFrame.size)
        return displays.contains { $0 != display && $0.intersects(parked) }
    }
}

/// The tab shown at the screen edge while a PiP is stashed: a slim glass handle with an arrow.
/// Clicking it, or dragging it inwards, brings the window back; dragging it up and down moves it
/// along the edge. (Two-finger swipes on it are handled by the engine, so none leak to the page.)
final class StashTab {
    var onBringBack: (() -> Void)?
    var onMove: ((CGFloat) -> Void)?       // vertical movement, in points (down is positive)
    var onDragging: ((Bool) -> Void)?
    private var panel: NSPanel?
    private var generation = 0             // so a fade-out that's still running can't hide a newer tab
    private(set) var frame = CGRect.zero   // global coordinates, origin top-left of the main display
    private(set) var playing = true        // glass showing the video's colours; grey while it's paused

    var isVisible: Bool { panel?.isVisible == true && (panel?.alphaValue ?? 0) > 0.5 }

    /// Its window number, to find it in the window list.
    var windowNumber: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    /// Whether macOS has it on the space showing now.
    var isOnActiveSpace: Bool { panel?.isOnActiveSpace == true }

    /// Shows the tab at `frame` straight away (it has to hide the window the moment it reaches the
    /// edge), just above `windowLevel`, the level of the window it covers.
    ///
    /// `fresh` replaces the tab's window with a new one. A window that has been shown for a while can
    /// end up kept to one space (Stage Manager, it seems, ties it to a stage), and then it can't be
    /// brought back on another space; a new window starts out on every space again.
    func show(_ side: StashSide, at frame: CGRect, above windowLevel: Int, fresh: Bool = false) {
        generation += 1
        if fresh, let old = panel {
            old.orderOut(nil)
            panel = nil
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.frame = frame
        panel.level = NSWindow.Level(rawValue: max(windowLevel, Int(CGWindowLevelForKey(.floatingWindow))) + 1)
        panel.setFrame(cocoaRect(frame), display: true)
        let view = TabView(side: side, size: frame.size)
        view.onBringBack = { [weak self] in self?.onBringBack?() }
        view.onMove = { [weak self] dy in self?.onMove?(dy) }
        view.onDragging = { [weak self] dragging in self?.onDragging?(dragging) }
        view.setPlaying(playing, animated: false)
        panel.contentView = view
        NSAnimationContext.runAnimationGroup { context in  // cancels any fade still running
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        CATransaction.flush()  // on screen now, before the window behind it changes
    }

    /// Animates the tab to a new frame (contracting into a handle).
    func animate(to frame: CGRect, duration: TimeInterval) {
        guard let panel else { return }
        self.frame = frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(cocoaRect(frame), display: true)
        }, completionHandler: { panel.invalidateShadow() })
    }

    /// Moves the tab instantly (while it's dragged along the edge, or refitted to the window),
    /// replacing any animation still running.
    func move(to frame: CGRect) {
        guard let panel else { return }
        self.frame = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(cocoaRect(frame), display: true)
        }
        panel.setFrame(cocoaRect(frame), display: true)
        panel.invalidateShadow()
    }

    /// Shows the video's colours through the glass while it plays, and plain grey while it's paused.
    func setPlaying(_ playing: Bool) {
        guard playing != self.playing else { return }
        self.playing = playing
        (panel?.contentView as? TabView)?.setPlaying(playing, animated: true)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        let hiding = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.generation == hiding { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Like the PiP window, it shows on every space, including full-screen ones, and with every
        // app's windows (otherwise Stage Manager hides it along with the stage it first showed in).
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false  // ZenPiP lets go of old tab windows itself
        return panel
    }

    /// Converts a top-left-origin global rect to AppKit's bottom-left-origin screen coordinates.
    private func cocoaRect(_ r: CGRect) -> NSRect {
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// The handle itself: frosted glass over the strip of video behind it, so it shimmers softly as the
/// video plays (like Safari's), rounded on the inside edge, with a thin chevron pointing back in.
/// While the video is paused, the glass turns plain dark grey.
private final class TabView: NSView {
    var onBringBack: (() -> Void)?
    var onMove: ((CGFloat) -> Void)?
    var onDragging: ((Bool) -> Void)?

    private let side: StashSide
    private let tint = NSView()
    private let paused = NSView()
    private var dragStart: NSPoint?
    private var lastDrag: NSPoint?
    private var axis: Axis?
    private enum Axis { case vertical, inwards }

    init(side: StashSide, size: CGSize) {
        self.side = side
        super.init(frame: NSRect(origin: .zero, size: size))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = Stash.cornerRadius
        layer?.maskedCorners = side == .right
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        let glass = NSVisualEffectView(frame: bounds)
        glass.material = .menu
        glass.blendingMode = .behindWindow  // blurs whatever is behind: the hidden video
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        paused.frame = bounds
        paused.autoresizingMask = [.width, .height]
        paused.wantsLayer = true
        paused.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.92).cgColor
        paused.alphaValue = 0
        glass.addSubview(paused)

        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        glass.addSubview(tint)

        // Inside the glass, in a vibrant label colour, so macOS renders it frosted like Safari's arrow.
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: side == .right ? "chevron.compact.left" : "chevron.compact.right",
                                accessibilityDescription: "Show Picture-in-Picture")
            ?? NSImage(systemSymbolName: side == .right ? "chevron.left" : "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold, scale: .large)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.frame = bounds
        chevron.autoresizingMask = [.width, .height]
        glass.addSubview(chevron)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setPlaying(_ playing: Bool, animated: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.35 : 0
            paused.animator().alphaValue = playing ? 0 : 1
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        lastDrag = dragStart
        axis = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let last = lastDrag else { return }
        let now = NSEvent.mouseLocation
        let dx = side == .right ? start.x - now.x : now.x - start.x  // inwards is positive
        let dy = now.y - start.y
        if axis == nil, hypot(dx, dy) > 4 {
            // Decide once which way this drag goes, so a vertical drag never pops the window out.
            axis = dx > abs(dy) ? .inwards : .vertical
            if axis == .vertical { onDragging?(true) }
        }
        switch axis {
        case .inwards where dx > Stash.pullOut:
            dragStart = nil
            onBringBack?()
        case .vertical:
            onMove?(last.y - now.y)  // AppKit's y goes up; ours goes down
        default:
            break
        }
        lastDrag = now
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil && axis == nil { onBringBack?() }  // a click
        if axis == .vertical { onDragging?(false) }
        dragStart = nil
        axis = nil
    }

    override func mouseEntered(with event: NSEvent) { tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor }
    override func mouseExited(with event: NSEvent) { tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor }
}
