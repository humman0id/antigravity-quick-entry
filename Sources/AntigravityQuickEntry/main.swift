import AppKit

// Explicit entry point so `swift run` and the bundled `.app` both launch cleanly
// as an accessory (menu-bar-only) macOS application.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
