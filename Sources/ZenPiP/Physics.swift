import CoreGraphics

// All positions are a window's top-left corner in global screen coordinates (points, y down).
// All speeds are in points per millisecond. Nothing in this file touches the system,
// so it is covered by the self-test.

/// The allowed positions for a window's top-left corner on one display.
struct Bounds: Equatable {
    var minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat

    func contains(_ p: CGPoint) -> Bool {
        p.x >= minX - 0.5 && p.x <= maxX + 0.5 && p.y >= minY - 0.5 && p.y <= maxY + 0.5
    }

    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(maxX, max(minX, p.x)), y: min(maxY, max(minY, p.y)))
    }

    /// The same bounds stretched to include `p`, so a window that starts outside them isn't squeezed.
    func including(_ p: CGPoint) -> Bounds {
        Bounds(minX: min(minX, p.x), minY: min(minY, p.y), maxX: max(maxX, p.x), maxY: max(maxY, p.y))
    }
}

enum Physics {
    // Tunable through settings (see Settings.swift); the names match the setting keys.
    static var flingSpeed: CGFloat = 0.45     // releases slower than this are a placement, not a throw
    static var cornerShare: CGFloat = 0.38    // a throw heads for each side it is aimed at this much (both = corner)
    static var throwCarryMs: CGFloat = 250    // how far a throw carries along a side it isn't aimed at
    static var magnet: CGFloat = 28           // a window set down this close to an edge snaps onto it
    static var springSpeed: CGFloat = 0.015   // spring stiffness, in radians per ms
    static var springDamping: CGFloat = 0.7   // below 1 the window overshoots the edge a little, then settles
    static var throwSpeed: CGFloat = 4        // top starting speed of a throw, which limits the bounce

    // Fixed.
    static let maxSpeed: CGFloat = 8          // fastest a finger or mouse release is taken to be
    static let rubber: CGFloat = 0.35         // resistance when pushed past an edge
    static let maxOvershoot: CGFloat = 70     // furthest a window goes past an edge, pushed or bouncing
    static let velocityWindowMs: Double = 80  // how much of the end of a swipe sets its speed
    static let pauseMs: Double = 50           // resting this long before letting go cancels a throw
    static let maxSpringMs: Double = 2500     // a spring still moving after this is finished off

    static func resetTuning() {
        flingSpeed = 0.45
        cornerShare = 0.38
        throwCarryMs = 250
        magnet = 28
        springSpeed = 0.015
        springDamping = 0.7
        throwSpeed = 4
    }

    /// One movement step: when it happened (ms) and how far it moved.
    struct Sample { let t: Double; let dx: CGFloat; let dy: CGFloat }

    // MARK: Following a finger

    /// How far a move of `d` from `p` really goes, with rubber-band resistance outside `lo...hi`.
    static func resist(_ p: CGFloat, _ d: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        if d < 0 && p + d < lo {
            let inside = min(0, lo - p)  // the part of the move that stays inside
            let over = max(0, lo - p)    // how far past the edge it already is
            return inside + (d - inside) * rubber * max(0, 1 - over / maxOvershoot)
        }
        if d > 0 && p + d > hi {
            let inside = max(0, hi - p)
            let over = max(0, p - hi)
            return inside + (d - inside) * rubber * max(0, 1 - over / maxOvershoot)
        }
        return d
    }

    /// Speed at the moment of letting go, from the last few movement steps.
    static func releaseVelocity(_ samples: [Sample], endTime: Double) -> CGVector {
        guard let last = samples.last else { return .zero }
        if endTime - last.t > pauseMs { return .zero }  // it had stopped before being let go
        let recent = samples.filter { last.t - $0.t <= velocityWindowMs }
        var vx: CGFloat, vy: CGFloat
        if recent.count < 2 {
            vx = last.dx / 12
            vy = last.dy / 12
        } else {
            let span = CGFloat(max(8, last.t - recent[0].t))
            vx = recent.dropFirst().reduce(0) { $0 + $1.dx } / span
            vy = recent.dropFirst().reduce(0) { $0 + $1.dy } / span
        }
        return capped(CGVector(dx: vx, dy: vy), maxSpeed)
    }

    static func capped(_ v: CGVector, _ limit: CGFloat) -> CGVector {
        let speed = hypot(v.dx, v.dy)
        return speed > limit ? CGVector(dx: v.dx * limit / speed, dy: v.dy * limit / speed) : v
    }

    // MARK: Where a window ends up

    /// Snaps onto an edge when within `magnet` of it.
    static func magnetize(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        if v - lo <= magnet && v - lo <= hi - v { return lo }
        if hi - v <= magnet { return hi }
        return v
    }

    /// Where a throw ends up: on every side it is aimed at, so a diagonal throw reaches a corner.
    static func throwDestination(from p: CGPoint, velocity v: CGVector, bounds b: Bounds) -> CGPoint {
        let speed = max(hypot(v.dx, v.dy), 0.0001)
        var d = b.clamp(CGPoint(x: p.x + v.dx * throwCarryMs, y: p.y + v.dy * throwCarryMs))
        let aimX = abs(v.dx) >= cornerShare * speed
        let aimY = abs(v.dy) >= cornerShare * speed
        d.x = aimX ? (v.dx > 0 ? b.maxX : b.minX) : magnetize(d.x, b.minX, b.maxX)
        d.y = aimY ? (v.dy > 0 ? b.maxY : b.minY) : magnetize(d.y, b.minY, b.maxY)
        return d
    }

    /// The starting speed of a throw. A throw further outwards from beyond an edge is ignored on that axis.
    static func throwVelocity(_ v: CGVector, at p: CGPoint, bounds b: Bounds) -> CGVector {
        var v = capped(v, throwSpeed)
        if (p.x > b.maxX && v.dx > 0) || (p.x < b.minX && v.dx < 0) { v.dx = 0 }
        if (p.y > b.maxY && v.dy > 0) || (p.y < b.minY && v.dy < 0) { v.dy = 0 }
        return v
    }

    /// Where a window set down without a throw rests: on screen, snapped onto a nearby edge.
    static func restDestination(from p: CGPoint, bounds b: Bounds) -> CGPoint {
        let c = b.clamp(p)
        return CGPoint(x: magnetize(c.x, b.minX, b.maxX), y: magnetize(c.y, b.minY, b.maxY))
    }

    // MARK: The spring

    /// Advances the spring carrying a window to `dest` by `dt` ms. Returns false once it has settled.
    static func springStep(pos: inout CGPoint, vel: inout CGVector, dest: CGPoint, dt: CGFloat) -> Bool {
        let k = springSpeed * springSpeed
        let c = 2 * springDamping * springSpeed
        var remaining = dt
        while remaining > 0 {  // small fixed steps keep the integration stable
            let h = min(4, remaining)
            remaining -= h
            vel.dx += (-k * (pos.x - dest.x) - c * vel.dx) * h
            vel.dy += (-k * (pos.y - dest.y) - c * vel.dy) * h
            pos.x += vel.dx * h
            pos.y += vel.dy * h
        }
        let settled = abs(pos.x - dest.x) < 0.5 && abs(pos.y - dest.y) < 0.5 && hypot(vel.dx, vel.dy) < 0.01
        if settled {
            pos = dest
            vel = .zero
        }
        return !settled
    }

    /// Where a spring position is drawn: overshoot past an edge is squeezed to stay under `maxOvershoot`.
    static func soften(_ p: CGPoint, _ b: Bounds) -> CGPoint {
        CGPoint(x: soften(p.x, b.minX, b.maxX), y: soften(p.y, b.minY, b.maxY))
    }

    static func soften(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        let m = maxOvershoot
        if v > hi { return hi + m * (1 - exp(-(v - hi) / m)) }
        if v < lo { return lo - m * (1 - exp(-(lo - v) / m)) }
        return v
    }
}
