import AppKit

/// One display, in global coordinates (origin at the top-left of the main display, y down).
struct ScreenArea {
    let frame: CGRect      // the whole display
    let visible: CGRect    // without the menu bar and the Dock
    let topInset: CGFloat  // menu bar or camera notch height
    let uuid: String?

    /// Where windows may go. In a full-screen space the Dock is hidden, so that's the full height;
    /// otherwise it's above the Dock. Never under the menu bar or the notch.
    func usable(fullScreen: Bool) -> CGRect {
        guard fullScreen else { return visible }
        let top = frame.minY + topInset
        return CGRect(x: frame.minX, y: top, width: frame.width, height: frame.maxY - top)
    }

    /// The allowed positions for a window of `size`, keeping `margin` from every edge.
    func bounds(for size: CGSize, fullScreen: Bool, margin: CGFloat) -> Bounds {
        let u = usable(fullScreen: fullScreen)
        let minX = u.minX + margin, minY = u.minY + margin
        return Bounds(minX: minX, minY: minY,
                      maxX: max(minX, u.maxX - size.width - margin),
                      maxY: max(minY, u.maxY - size.height - margin))
    }

    /// Where a PiP goes after switching spaces. One resting on (or below) the bottom edge of the old
    /// kind of space follows the bottom edge of the new one; anything else just stays on screen.
    func destinationAfterSpaceChange(_ window: CGRect, oldModes: [Bool], newMode: Bool, margin: CGFloat) -> CGPoint {
        let newBounds = bounds(for: window.size, fullScreen: newMode, margin: margin)
        let wasOnBottom = oldModes.contains {
            window.minY >= bounds(for: window.size, fullScreen: $0, margin: margin).maxY - 3
        }
        var dest = newBounds.clamp(window.origin)
        if wasOnBottom { dest.y = newBounds.maxY }
        return dest
    }
}

enum Screens {
    static func areas() -> [ScreenArea] {
        guard let main = NSScreen.screens.first else { return [] }
        let mainHeight = main.frame.maxY
        // AppKit measures from the bottom-left; window positions are measured from the top-left.
        let flip = { (r: CGRect) in CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { screen in
            let frame = flip(screen.frame)
            let visible = flip(screen.visibleFrame)
            let topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness, visible.minY - frame.minY)
            var uuid: String?
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               let id = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, id) as String?
            }
            return ScreenArea(frame: frame, visible: visible, topInset: topInset, uuid: uuid)
        }
    }

    /// The display showing most of a window (the one containing its centre, or the nearest).
    static func area(for window: CGRect) -> ScreenArea? {
        let all = areas()
        let centre = CGPoint(x: window.midX, y: window.midY)
        if let area = all.first(where: { $0.frame.contains(centre) }) { return area }
        return all.min { distance($0.frame, centre) < distance($1.frame, centre) }
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }
}

enum Spaces {
    private static let connection = PrivateAPI.mainConnection?() ?? 0

    /// Whether the space showing on a display is a full-screen app (or Split View).
    /// If macOS doesn't answer, it says no, which keeps the PiP above the Dock.
    static func isFullScreen(_ area: ScreenArea) -> Bool {
        guard connection != 0, let spaceType = PrivateAPI.spaceType else { return false }
        var space: UInt64 = 0
        if let uuid = area.uuid, let displaySpace = PrivateAPI.displaySpace {
            space = displaySpace(connection, uuid as CFString)
        }
        if space == 0, let activeSpace = PrivateAPI.activeSpace { space = activeSpace(connection) }
        return space != 0 && spaceType(connection, space) == PrivateAPI.fullScreenSpaceType
    }
}
