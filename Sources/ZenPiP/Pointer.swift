import AppKit

/// Moves the mouse pointer. Posting a real "mouse moved" event (rather than warping it) lets the
/// PiP window notice the hover, and the pointer stays responsive straight away.
enum Pointer {
    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()
    private static var last: CGPoint?
    private static var previous: CGPoint?

    private static var current: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func forget() {
        last = nil
        previous = nil
    }

    /// Whether the user has moved the pointer since ZenPiP last placed it (allowing for ZenPiP's
    /// own previous move still being on its way).
    static var userMovedIt: Bool {
        guard let last else { return false }
        let now = current
        let awayFromLast = hypot(now.x - last.x, now.y - last.y) > 3
        let awayFromPrevious = previous.map { hypot(now.x - $0.x, now.y - $0.y) > 3 } ?? true
        return awayFromLast && awayFromPrevious
    }

    /// Moves the pointer, kept a few points inside the display so it never sets off a hot corner or the Dock.
    static func move(to p: CGPoint, within display: CGRect) {
        // Never while a button is held: that would turn a drag into a jump.
        if CGEventSource.buttonState(.hidSystemState, button: .left) { return }
        let inside = display.insetBy(dx: 4, dy: 4)
        let target = CGPoint(x: min(inside.maxX, max(inside.minX, p.x)).rounded(),
                             y: min(inside.maxY, max(inside.minY, p.y)).rounded())
        if target == last { return }
        previous = last
        last = target
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
