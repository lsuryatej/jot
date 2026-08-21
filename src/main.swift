import AppKit

// An AppKit entry point rather than a SwiftUI `App`.
//
// The previous `@main struct StickyNotesApp: App` needed a Scene, and the
// `Settings { EmptyView() }` placeholder standing in for one materialised as a
// blank 900x450 window that had to be hidden on launch. Owning NSApplication
// directly removes the cause instead of papering over it, and is what lets the
// activation policy change at runtime for Dock mode.

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
