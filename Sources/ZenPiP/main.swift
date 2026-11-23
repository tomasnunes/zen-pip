// ZenPiP: Arc-style trackpad and mouse gestures for Zen's Picture-in-Picture window.
// See README.md for what it does and docs/how-it-works.md for how.

import AppKit

if CommandLine.arguments.contains("--selftest") {
    _ = NSApplication.shared  // needed for screen information
    exit(SelfTest.run())
}

// Only one copy may run: two would both try to move the window.
let me = NSRunningApplication.current
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me }) {
    Log.write("Already running; exiting")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, no menu bar
let engine = Engine()
engine.start()

// Stopped by launchd (uninstalled, or replaced by a new build): put a tucked-away PiP back first.
signal(SIGTERM, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
stop.setEventHandler {
    engine.restoreBeforeQuitting()
    exit(0)
}
stop.resume()

app.run()
