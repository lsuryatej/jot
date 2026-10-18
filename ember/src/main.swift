import AppKit

// An AppKit entry point, as in Jot: a menu bar app has no window for a
// SwiftUI `App` scene to own. Process startup runs on the main thread, so
// `assumeIsolated` states that fact rather than making this async.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
