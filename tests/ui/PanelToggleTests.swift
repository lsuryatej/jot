import AppKit
import Foundation
import SwiftUI

// Issue #8: the menu bar icon and the global hot key needed two presses.
//
// The toggle used to ask only `panel.isVisible`. That conflates "on screen"
// with "in front and taking keystrokes", and the two come apart constantly:
// Floating mode never steals focus, Menu Bar mode is an ordinary window that
// ends up behind whatever the user clicked next, and any mode loses the
// keyboard the moment the user goes back to work. In that state the first
// press took the hide branch on a note that was already buried, which reads as
// nothing happening, and the second press showed it.
//
// The headless suite structurally cannot see this: it has no window server, so
// no window is ever key and `isVisible` and `isKeyWindow` cannot disagree.
// Hence a real panel here, put into exactly the state the report describes.

@MainActor
private func makeHostedPanel() -> (panel: FloatingPanel, fixtures: (settings: SettingsManager, notes: NotesManager, directory: URL)) {
    let fixtures = makeSettingsFixtures()
    let panel = FloatingPanel(rootView: ContentView(notesManager: fixtures.notes, settings: fixtures.settings))
    panel.setFrame(NSRect(x: 120, y: 120, width: 400, height: 420), display: false)
    return (panel, fixtures)
}

/// A second window in this process, used to take key status away from the
/// panel without leaving it. Clicking into another app would do the same thing
/// to the panel, and is what the report describes, but a test cannot rely on
/// another app being there to click.
@MainActor
private func makeFocusThief() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 600, y: 120, width: 240, height: 180),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = "focus thief"
    return window
}

func runPanelToggleTests() {
    MainActor.assumeIsolated {
        suite("the toggle decision itself") {
            equal(AppDelegate.toggleAction(isVisible: false, isFocused: false), .show,
                  "hidden: show it")
            equal(AppDelegate.toggleAction(isVisible: true, isFocused: true), .hide,
                  "visible and focused: the deliberate dismiss still hides")
            equal(AppDelegate.toggleAction(isVisible: true, isFocused: false), .show,
                  "visible but not focused: bring it forward, do not hide it (issue #8)")
            // Not reachable through `isInterfaceFocused`, which requires
            // visibility, but pinned so the rule stays a conjunction rather
            // than quietly becoming "focused implies hide".
            equal(AppDelegate.toggleAction(isVisible: false, isFocused: true), .show,
                  "not on screen: show, whatever focus claims")
        }

        suite("a real panel that is visible but has lost the keyboard") {
            let (panel, fixtures) = makeHostedPanel()
            let thief = makeFocusThief()
            defer {
                panel.orderOut(nil)
                thief.close()
                try? FileManager.default.removeItem(at: fixtures.directory)
            }

            bringUpAndWaitUntilKey(panel)
            check(panel.isVisible, "panel is on screen")
            check(panel.isKeyWindow, "panel holds the keyboard right after being shown")
            equal(AppDelegate.toggleAction(isVisible: panel.isVisible, isFocused: panel.isVisible && panel.isKeyWindow),
                  .hide,
                  "pressing the hot key on the note you are typing in dismisses it")

            bringUpAndWaitUntilKey(thief)
            check(panel.isVisible, "panel is still on screen after something else took focus")
            check(!panel.isKeyWindow, "panel no longer holds the keyboard")
            // The regression guard, stated in the terms of the old rule: this
            // is precisely the state in which `isVisible` alone said "hide".
            equal(AppDelegate.toggleAction(isVisible: panel.isVisible, isFocused: panel.isVisible && panel.isKeyWindow),
                  .show,
                  "the first press brings the buried note forward instead of hiding it")
        }
    }
}
