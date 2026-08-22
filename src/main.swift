import AppKit

// An AppKit entry point rather than a SwiftUI `App`.
//
// The previous `@main struct StickyNotesApp: App` needed a Scene, and the
// `Settings { EmptyView() }` placeholder standing in for one materialised as a
// blank 900x450 window that had to be hidden on launch. Owning NSApplication
// directly removes the cause instead of papering over it, and is what lets the
// activation policy change at runtime for Dock mode.
//
// Process startup runs on the main thread, so `assumeIsolated` documents that
// fact to the compiler rather than making this `async` for no reason.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
