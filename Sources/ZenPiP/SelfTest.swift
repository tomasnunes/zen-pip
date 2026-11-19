import AppKit

/// `ZenPiP --selftest` checks the movement maths and window rules without touching any windows.
/// The numbers describe an example 1440 × 900 display with a 25 pt menu bar, a 70 pt Dock, and a
/// 480 × 270 PiP window.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failures += 1 }
        }
        Physics.resetTuning()

        let area = ScreenArea(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                              visible: CGRect(x: 0, y: 25, width: 1440, height: 805), topInset: 25, uuid: nil)
        let size = CGSize(width: 480, height: 270)
        let b = area.bounds(for: size, fullScreen: false, margin: 12)
        let mid = CGPoint(x: 480, y: 300)

        print("Following a finger")
        check("a move inside the screen is unchanged", Physics.resist(mid.x, 40, b.minX, b.maxX) == 40)
        let crossing = Physics.resist(b.maxX - 10, 40, b.minX, b.maxX)
        check("a move across an edge is partly resisted", crossing > 10 && crossing < 40, "\(crossing)")
        var pushed = b.maxX
        for _ in 0..<500 { pushed += Physics.resist(pushed, 10, b.minX, b.maxX) }
        check("pushing never goes further than the overshoot limit", pushed - b.maxX <= Physics.maxOvershoot)
        check("moving back in from outside is not resisted", Physics.resist(b.maxX + 40, -20, b.minX, b.maxX) == -20)
        let steady = (0..<10).map { Physics.Sample(t: Double($0) * 10, dx: 5, dy: 0) }
        check("the release speed of a steady swipe", abs(Physics.releaseVelocity(steady, endTime: 95).dx - 0.5) < 0.01)
        check("resting before letting go means no throw", Physics.releaseVelocity(steady, endTime: 200) == .zero)

        print("Where a window ends up")
        let right = Physics.throwDestination(from: mid, velocity: CGVector(dx: 1.5, dy: 0.2), bounds: b)
        check("a flick to the right goes all the way to the right side", right.x == b.maxX && b.contains(right), "\(right)")
        let gentle = Physics.throwDestination(from: mid, velocity: CGVector(dx: 0.5, dy: 0), bounds: b)
        check("even a gentle flick reaches the side", gentle.x == b.maxX)
        let corner = Physics.throwDestination(from: mid, velocity: CGVector(dx: -1.2, dy: 1.0), bounds: b)
        check("a diagonal flick goes to the corner", corner == CGPoint(x: b.minX, y: b.maxY), "\(corner)")
        let up = Physics.throwDestination(from: CGPoint(x: b.maxX - 10, y: 400), velocity: CGVector(dx: 0.1, dy: -2), bounds: b)
        check("a flick up along the right side stays on the right side", up == CGPoint(x: b.maxX, y: b.minY), "\(up)")
        let outward = Physics.throwVelocity(CGVector(dx: 2, dy: 1), at: CGPoint(x: b.maxX + 30, y: 300), bounds: b)
        check("a flick further out from past an edge doesn't push it further", outward.dx == 0 && outward.dy > 0)
        let nearEdge = Physics.restDestination(from: CGPoint(x: b.maxX - 20, y: 300), bounds: b)
        check("set down near an edge, it snaps onto it", nearEdge == CGPoint(x: b.maxX, y: 300), "\(nearEdge)")
        check("set down in the open, it stays put", Physics.restDestination(from: mid, bounds: b) == mid)

        print("The spring")
        var pos = mid, vel = CGVector(dx: 3, dy: 2.5), elapsed: CGFloat = 0, furthest = CGPoint.zero
        let dest = Physics.throwDestination(from: pos, velocity: vel, bounds: b)
        vel = Physics.throwVelocity(vel, at: pos, bounds: b)
        while Physics.springStep(pos: &pos, vel: &vel, dest: dest, dt: 8) && elapsed < 3000 {
            elapsed += 8
            let drawn = Physics.soften(pos, b)
            furthest = CGPoint(x: max(furthest.x, drawn.x), y: max(furthest.y, drawn.y))
        }
        check("a throw settles exactly in the corner", pos == dest && dest == CGPoint(x: b.maxX, y: b.maxY), "\(pos)")
        check("it settles in under a second", elapsed < 900, "\(Int(elapsed)) ms")
        check("it springs a little past the edge first", furthest.x > b.maxX + 3 || furthest.y > b.maxY + 3,
              "past by \(Int(furthest.x - b.maxX)), \(Int(furthest.y - b.maxY)) pt")
        check("the bounce stays within the overshoot limit",
              furthest.x - b.maxX < Physics.maxOvershoot && furthest.y - b.maxY < Physics.maxOvershoot)

        var under = CGPoint(x: mid.x, y: b.maxY + 80), underVel = CGVector.zero, previous = under, biggestStep: CGFloat = 0
        let soft = b.including(under)
        check("a spring starts exactly where the window is drawn", Physics.soften(under, soft) == under)
        while Physics.springStep(pos: &under, vel: &underVel, dest: CGPoint(x: mid.x, y: b.maxY), dt: 8) {
            let drawn = Physics.soften(under, soft)
            biggestStep = max(biggestStep, abs(drawn.y - previous.y))
            previous = drawn
        }
        check("a window under the Dock slides up without jumping", biggestStep < 15 && under.y == b.maxY,
              String(format: "largest step %.1f pt", biggestStep))

        Physics.springSpeed = 0.05  // the stiffest and bounciest values the settings allow
        Physics.springDamping = 0.3
        var fast = mid, fastVel = CGVector(dx: 8, dy: 0), frames = 0
        while Physics.springStep(pos: &fast, vel: &fastVel, dest: CGPoint(x: b.maxX, y: mid.y), dt: 8) && frames < 2000 { frames += 1 }
        check("even extreme spring settings settle", frames < 2000 && fast.x == b.maxX, "\(frames) frames")
        Physics.resetTuning()

        print("Switching spaces")
        let desktopBottom = b.maxY
        let fullBottom = area.bounds(for: size, fullScreen: true, margin: 12).maxY
        let onDesktopBottom = CGRect(origin: CGPoint(x: b.maxX, y: desktopBottom), size: size)
        check("resting on the bottom, it follows the bottom into a full-screen space",
              area.destinationAfterSpaceChange(onDesktopBottom, oldModes: [false], newMode: true, margin: 12).y == fullBottom)
        let onFullBottom = CGRect(origin: CGPoint(x: b.maxX, y: fullBottom), size: size)
        check("and back up above the Dock",
              area.destinationAfterSpaceChange(onFullBottom, oldModes: [true], newMode: false, margin: 12).y == desktopBottom)
        let untouched = CGRect(origin: CGPoint(x: 1440 - 480, y: 900 - 270), size: size)  // where Zen first opens a PiP
        check("a PiP Zen opened flush in the corner counts as on the bottom",
              area.destinationAfterSpaceChange(untouched, oldModes: [false], newMode: true, margin: 12).y == fullBottom)
        let floating = CGRect(origin: mid, size: size)
        check("a PiP in the middle stays put",
              area.destinationAfterSpaceChange(floating, oldModes: [true], newMode: false, margin: 12) == mid)
        check("nothing moves when the kind of space doesn't change",
              area.destinationAfterSpaceChange(onFullBottom, oldModes: [true], newMode: true, margin: 12) == onFullBottom.origin)

        print("Seeing through overlays to the PiP")
        let display = area.frame
        let screenshotTool = WindowInfo(id: 1, pid: 1, frame: display, layer: 2147483628, owner: "Screenshot tool", alpha: 1)
        check("a full-screen layer from a screenshot tool is seen through", WindowList.isSeeThroughOverlay(screenshotTool, displays: [display]))
        let dock = WindowInfo(id: 2, pid: 2, frame: display, layer: 20, owner: "Dock", alpha: 1)
        check("so is the Dock's full-screen layer", WindowList.isSeeThroughOverlay(dock, displays: [display]))
        let pip = WindowInfo(id: 3, pid: 3, frame: CGRect(origin: mid, size: size), layer: 3, owner: "Zen", alpha: 1)
        check("a PiP window is not", !WindowList.isSeeThroughOverlay(pip, displays: [display]))
        let fullScreenApp = WindowInfo(id: 4, pid: 4, frame: display, layer: 0, owner: "Zen", alpha: 1)
        check("nor is a full-screen app window", !WindowList.isSeeThroughOverlay(fullScreenApp, displays: [display]))
        let menu = WindowInfo(id: 5, pid: 5, frame: CGRect(x: 500, y: 320, width: 220, height: 300), layer: 101, owner: "Zen", alpha: 1)
        check("nor a menu open over the PiP", !WindowList.isSeeThroughOverlay(menu, displays: [display]))

        print("Window titles")
        check("Zen's English PiP title is recognised", isPipTitle("Picture-in-Picture"))
        check("Chrome's PiP title is recognised", isPipTitle("Picture in picture"))
        check("a title with a non-breaking space is recognised (Polish)", isPipTitle("Obraz w\u{00A0}obrazie"))
        check("a web page title is not", !isPipTitle("Some video - YouTube"))

        print("This Mac")
        check("the window and space functions were found", PrivateAPI.axGetWindow != nil && PrivateAPI.spaceType != nil)
        check("found the displays", !Screens.areas().isEmpty)

        print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
