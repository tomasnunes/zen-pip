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
        check("one that shows up after the new space was recorded still follows the bottom it was on",
              area.destinationAfterSpaceChange(onDesktopBottom, oldModes: [false, true], newMode: true, margin: 12).y == fullBottom)
        let floating = CGRect(origin: mid, size: size)
        check("a PiP in the middle stays put",
              area.destinationAfterSpaceChange(floating, oldModes: [true], newMode: false, margin: 12) == mid)
        check("nothing moves when the kind of space doesn't change",
              area.destinationAfterSpaceChange(onFullBottom, oldModes: [true], newMode: true, margin: 12) == onFullBottom.origin)

        print("Stashing at a side")
        let edgeRight = CGPoint(x: b.maxX, y: 300), v0 = CGVector.zero
        check("pushed well past the right edge, it stashes right",
              Stash.side(releasedAt: CGPoint(x: b.maxX + 40, y: 300), startedAt: edgeRight, velocity: v0, isThrow: false,
                         pushedPast: Stash.pushPast, bounds: b) == .right)
        check("pushed only a little past, it doesn't",
              Stash.side(releasedAt: CGPoint(x: b.maxX + 20, y: 300), startedAt: edgeRight, velocity: v0, isThrow: false,
                         pushedPast: Stash.pushPast, bounds: b) == nil)
        check("flicked again towards the side it's resting on, it stashes",
              Stash.side(releasedAt: edgeRight, startedAt: edgeRight, velocity: CGVector(dx: 2, dy: 0.3), isThrow: true,
                         pushedPast: Stash.pushPast, bounds: b) == .right)
        check("flicked towards a side from the middle, it only goes to the edge",
              Stash.side(releasedAt: mid, startedAt: mid, velocity: CGVector(dx: 2, dy: 0), isThrow: true,
                         pushedPast: Stash.pushPast, bounds: b) == nil)
        check("flicked down along the side it's on, it doesn't stash",
              Stash.side(releasedAt: edgeRight, startedAt: edgeRight, velocity: CGVector(dx: 0.3, dy: 2), isThrow: true,
                         pushedPast: Stash.pushPast, bounds: b) == nil)
        let leftEdge = CGPoint(x: b.minX, y: 300)
        check("and the same on the left",
              Stash.side(releasedAt: leftEdge, startedAt: leftEdge, velocity: CGVector(dx: -2, dy: 0), isThrow: true,
                         pushedPast: Stash.pushPast, bounds: b) == .left)
        check("flicked diagonally from the side it's on, it goes to the corner instead",
              Stash.side(releasedAt: edgeRight, startedAt: edgeRight, velocity: CGVector(dx: 1.5, dy: 1.5), isThrow: true,
                         pushedPast: Stash.pushPast, bounds: b) == nil)
        let parked = Stash.position(.right, size: size, y: 300, display: area.frame)
        check("a stashed window is fully off the screen", parked.x >= area.frame.maxX, "\(parked)")
        let small = Stash.parkedSize(for: size)
        check("parked, it shrinks to Zen's smallest height and keeps its shape",
              small.height == Stash.parkedHeight && abs(small.width / small.height - size.width / size.height) < 0.02, "\(small)")
        let tall = Stash.parkedSize(for: CGSize(width: 270, height: 480))
        let wideBack = Stash.fullSize(forParked: small, width: nil, usable: CGRect(x: 0, y: 25, width: 1920, height: 1080), margin: 12)
        check("brought back with no size to go on, a wide video gets Zen's default size: \(wideBack)",
              abs(wideBack.width - 640) <= 1 && abs(wideBack.height - 360) <= 1)
        let portraitBack = Stash.fullSize(forParked: tall, width: nil, usable: area.visible, margin: 12)
        check("brought back with no size to go on, a tall video fits on screen: \(portraitBack)",
              portraitBack.height <= area.visible.height - 24 && abs(portraitBack.width / portraitBack.height - tall.width / tall.height) < 0.02)
        check("a parked window is recognised by its size, wide or tall, and a normal one isn't",
              Stash.looksParked(small) && Stash.looksParked(tall) && !Stash.looksParked(size))
        check("but never below the smallest size Zen allows", tall.width >= 120 && tall.height >= 80, "\(tall)")
        let strip = CGRect(x: 1400, y: 300, width: small.width, height: small.height)  // macOS left 40 pt showing
        let cover = Stash.tabFrame(.right, covering: strip, display: area.frame)
        check("the tab covers the strip macOS leaves on screen, and is no wider",
              cover.contains(strip.intersection(area.frame)) && cover.maxX == area.frame.maxX && cover.width <= 41, "\(cover)")
        check("its rounded ends sit above and below the strip",
              cover.minY <= strip.minY - Stash.cornerRadius && cover.maxY >= strip.maxY + Stash.cornerRadius)
        let y = Stash.clampY(900, height: small.height, usable: area.visible)
        check("and stays clear of the Dock", y + small.height <= area.visible.maxY - 8, "\(y)")
        check("flying off the right, it's covered once nearly gone",
              Stash.reachedEdge(.right, at: CGPoint(x: 1440 - 50, y: 300), width: 480, display: area.frame)
              && !Stash.reachedEdge(.right, at: CGPoint(x: 1440 - 200, y: 300), width: 480, display: area.frame))
        check("and off the left",
              Stash.reachedEdge(.left, at: CGPoint(x: -430, y: 300), width: 480, display: area.frame)
              && !Stash.reachedEdge(.left, at: CGPoint(x: -100, y: 300), width: 480, display: area.frame))
        let asked = Stash.parkedPosition(.right, size: small, y: 300, display: area.frame)
        check("parked, it's asked to leave only a sliver on screen", area.frame.maxX - asked.x == Stash.parkShowing)
        let askedLeft = Stash.parkedPosition(.left, size: small, y: 300, display: area.frame)
        check("on either side", askedLeft.x + small.width - area.frame.minX == Stash.parkShowing)
        let parkedFrame = CGRect(x: 1400, y: 300, width: 142, height: 80)
        check("a point of rounding doesn't count as moved",
              !Stash.isDisplaced(CGRect(x: 1401, y: 300, width: 141, height: 79), from: parkedFrame, display: area.frame))
        check("showing a few points more than the tab covers does",
              Stash.isDisplaced(CGRect(x: 1394, y: 300, width: 142, height: 80), from: parkedFrame, display: area.frame))
        let fitted = Stash.tabWidth(covering: Stash.showing(parkedFrame, on: area.frame))
        check("even a single point more than the tab covers does, but what it still covers doesn't",
              Stash.isDisplaced(CGRect(x: area.frame.maxX - fitted - 1, y: 300, width: 142, height: 80), from: parkedFrame, display: area.frame)
              && !Stash.isDisplaced(CGRect(x: area.frame.maxX - fitted, y: 300, width: 142, height: 80), from: parkedFrame, display: area.frame))
        check("a tall window that never shrank isn't taken for a parked one",
              !Stash.looksParked(CGSize(width: 155, height: 276)) && Stash.looksParked(Stash.parkedSize(for: CGSize(width: 155, height: 276))))
        check("pulled back on screen does",
              Stash.isDisplaced(CGRect(x: 1250, y: 300, width: 142, height: 80), from: parkedFrame, display: area.frame))
        check("and so does being resized",
              Stash.isDisplaced(CGRect(x: 1400, y: 300, width: 480, height: 270), from: parkedFrame, display: area.frame))
        let sliver = CGRect(x: 1419, y: 300, width: 142, height: 80)
        check("a sliver at the edge counts as parked", Stash.isParked(sliver, side: .right, y: 300, display: area.frame)
              && Stash.isParked(CGRect(x: -121, y: 300, width: 142, height: 80), side: .left, y: 300, display: area.frame))
        check("put back fully on screen, it isn't",
              !Stash.isParked(CGRect(x: 1298, y: 300, width: 142, height: 80), side: .right, y: 300, display: area.frame))
        check("nor is it off the display altogether, or at the wrong height",
              !Stash.isParked(CGRect(x: -1871, y: 300, width: 142, height: 80), side: .right, y: 300, display: area.frame)
              && !Stash.isParked(sliver, side: .right, y: 360, display: area.frame))
        let displays = [area.frame]
        check("a parked window left alone is fine",
              Stash.check(sliver, parked: sliver, side: .right, display: area.frame, displays: displays, still: 5) == .fine)
        check("one sliding with a space switch, off every display, is waited for",
              Stash.check(CGRect(x: -1871, y: 300, width: 142, height: 80), parked: sliver, side: .right, display: area.frame,
                          displays: displays, still: 1) == .away)
        let rescued = CGRect(x: 1250, y: 300, width: 142, height: 80)
        check("one passing across the screen is waited for",
              Stash.check(CGRect(x: 1200, y: 300, width: 142, height: 80), parked: sliver, side: .right, display: area.frame,
                          displays: displays, still: 0.05) == .moving)
        check("one macOS has left back on screen is parked again",
              Stash.check(rescued, parked: sliver, side: .right, display: area.frame, displays: displays, still: Stash.stillFor) == .parkAgain)
        let flushRight = CGRect(x: 1440 - 142, y: 300, width: 142, height: 80)
        check("macOS putting it back flush against the edge is recognised as that",
              Stash.isPutBack(flushRight, parked: sliver, side: .right, display: area.frame)
              && !Stash.isPutBack(rescued, parked: sliver, side: .right, display: area.frame))
        check("and one put back flush against the edge is parked again straight away",
              Stash.check(flushRight, parked: sliver, side: .right, display: area.frame, displays: displays, still: 0) == .parkAgain)
        check("a PiP left as a sliver at a side, with no tab, is noticed",
              Stash.strandedSide(sliver, display: area.frame, displays: displays) == .right
              && Stash.strandedSide(CGRect(x: -121, y: 300, width: 142, height: 80), display: area.frame, displays: displays) == .left)
        let below = ScreenArea(frame: CGRect(x: 1440, y: 900, width: 1920, height: 1080),
                               visible: CGRect(x: 1440, y: 900, width: 1920, height: 1080), topInset: 0, uuid: "below")
        let wideParked = CGRect(x: 1419, y: 802, width: 188, height: 80)  // nearer the display below, but not on it
        check("a tucked-away window belongs to the display it's still partly on, not the nearest one",
              Screens.area(for: wideParked, in: [area, below])?.uuid == nil)
        check("but not one on screen, or partly on a display next door",
              Stash.strandedSide(rescued, display: area.frame, displays: displays) == nil
              && Stash.strandedSide(sliver, display: area.frame,
                                    displays: displays + [CGRect(x: 1440, y: 0, width: 1920, height: 1080)]) == nil)
        let rightDisplay = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let window = CGRect(origin: CGPoint(x: b.maxX, y: 300), size: size)
        check("it won't stash towards a display next door",
              Stash.blockedByNeighbour(.right, display: area.frame, displays: [area.frame, rightDisplay], windowFrame: window)
              && !Stash.blockedByNeighbour(.left, display: area.frame, displays: [area.frame, rightDisplay], windowFrame: window))

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
