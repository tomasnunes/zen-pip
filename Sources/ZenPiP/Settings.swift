import CoreGraphics
import Foundation

/// User settings, read from `defaults` whenever a gesture lands on a PiP window, so changes apply
/// straight away:
///
///     defaults write local.zenpip <key> <value>      # change a setting
///     defaults delete local.zenpip <key>             # back to the default
///
/// The property names match the keys. See the README for the full list.
struct Settings {
    static let domain = "local.zenpip"

    var edgeMargin: CGFloat = 12   // gap kept from the screen edges, in points
    var followPointer = true       // move the pointer along with the window
    var stash = true               // tuck the window away when pushed or flicked past a side
    var invert = false             // flip the direction if the window moves against your fingers
    var debug = false              // log every gesture

    /// Reads the settings. This also applies the movement tunables (flingSpeed and so on) to `Physics`.
    static func load() -> Settings {
        let d = Bundle.main.bundleIdentifier == domain ? .standard : (UserDefaults(suiteName: domain) ?? .standard)
        var s = Settings()
        if d.object(forKey: "edgeMargin") != nil { s.edgeMargin = CGFloat(min(200, max(0, d.double(forKey: "edgeMargin")))) }
        if d.object(forKey: "followPointer") != nil { s.followPointer = d.bool(forKey: "followPointer") }
        if d.object(forKey: "stash") != nil { s.stash = d.bool(forKey: "stash") }
        s.invert = d.bool(forKey: "invert")
        s.debug = d.bool(forKey: "debug")

        // Start from the defaults every time, so a deleted key really goes back to normal, and keep
        // each value in a range where the spring still behaves.
        Physics.resetTuning()
        func tune(_ key: String, _ range: ClosedRange<CGFloat>, _ apply: (CGFloat) -> Void) {
            guard d.object(forKey: key) != nil else { return }
            apply(min(range.upperBound, max(range.lowerBound, CGFloat(d.double(forKey: key)))))
        }
        tune("flingSpeed", 0.05...5) { Physics.flingSpeed = $0 }
        tune("cornerShare", 0.1...0.7) { Physics.cornerShare = $0 }
        tune("throwCarryMs", 0...1000) { Physics.throwCarryMs = $0 }
        tune("magnet", 0...200) { Physics.magnet = $0 }
        tune("springSpeed", 0.004...0.05) { Physics.springSpeed = $0 }
        tune("springDamping", 0.3...1.5) { Physics.springDamping = $0 }
        tune("throwSpeed", 0.5...8) { Physics.throwSpeed = $0 }
        return s
    }
}
