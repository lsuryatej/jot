import AppKit
import Foundation
import SwiftUI

// Issue #11: Cmd+. closed the note.
//
// Nothing in this codebase binds that chord. It is AppKit's second binding for
// `cancelOperation:`, and NSPanel answers that selector by closing itself, so
// a chord people hit by accident (it is Cancel in half the apps on the
// machine) took the window away. Recoverable from the menu bar icon, but
// surprising and documented nowhere.
//
// Escape arrives at the same selector, so these tests pin both: the chord is
// neutralised, and Escape keeps doing whatever it did before. Only a real key
// window can show this, because the chord is resolved by AppKit's own key
// handling rather than by any code here that could be called directly.

@MainActor
private func makePanelUnderTest() -> (panel: FloatingPanel, fixtures: (settings: SettingsManager, notes: NotesManager, directory: URL)) {
    let fixtures = makeSettingsFixtures()
    let panel = FloatingPanel(rootView: ContentView(notesManager: fixtures.notes, settings: fixtures.settings))
    panel.setFrame(NSRect(x: 160, y: 160, width: 400, height: 420), display: false)
    return (panel, fixtures)
}

/// Sends a real key-down through `NSApp.sendEvent`, so the chord is dispatched
/// by the same AppKit machinery that turns it into `cancelOperation:` for a
/// human.
@MainActor
private func sendKey(
    _ window: NSWindow,
    characters: String,
    charactersIgnoringModifiers: String? = nil,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = []
) {
    reassertKey(window)
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
        isARepeat: false,
        keyCode: keyCode
    ) else { return }
    NSApplication.shared.sendEvent(event)
    pump(0.2)
}

func runPanelCancelTests() {
    MainActor.assumeIsolated {
        suite("Cmd+period is recognised without consulting the responder chain") {
            let chord = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: ".",
                charactersIgnoringModifiers: ".",
                isARepeat: false,
                keyCode: 47
            )
            let escape = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
            let plainPeriod = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: ".",
                charactersIgnoringModifiers: ".",
                isARepeat: false,
                keyCode: 47
            )

            check(FloatingPanel.isCommandPeriod(chord), "Cmd+period")
            check(!FloatingPanel.isCommandPeriod(escape), "Escape is not the chord")
            check(!FloatingPanel.isCommandPeriod(plainPeriod), "a bare period is not the chord")
            check(!FloatingPanel.isCommandPeriod(nil), "no event at all is not the chord")
        }

        suite("Cmd+period does not take the note away") {
            let (panel, fixtures) = makePanelUnderTest()
            defer {
                panel.orderOut(nil)
                try? FileManager.default.removeItem(at: fixtures.directory)
            }

            bringUpAndWaitUntilKey(panel)
            panel.focusEditor()
            pump(0.1)
            check(panel.isVisible, "panel is on screen before the chord")

            sendKey(panel, characters: ".", keyCode: 47, modifiers: .command)
            check(panel.isVisible, "the panel survives Cmd+period with the editor focused (issue #11)")

            // With the panel itself as first responder there is no text view in
            // the way, which is the bare path to NSPanel's own cancelOperation.
            panel.makeFirstResponder(panel)
            pump(0.1)
            sendKey(panel, characters: ".", keyCode: 47, modifiers: .command)
            check(panel.isVisible, "the panel survives Cmd+period with no text view in the responder chain")
        }

        // Measured, not assumed: with the editor focused and no search overlay
        // up, Escape today reaches NSPanel's cancelOperation and dismisses the
        // note, same as the chord did. That is the shipped behaviour, so the
        // fix has to leave it alone, and this is the check that says so.
        // (Escape is claimed earlier than this wherever it already means
        // something: GlobalSearchView takes it with `.onExitCommand` to close
        // the search overlay, and the hot-key recorder in PreferencesView
        // takes it to abandon a recording.)
        suite("Escape keeps the behaviour it already had") {
            let (panel, fixtures) = makePanelUnderTest()
            defer {
                panel.orderOut(nil)
                try? FileManager.default.removeItem(at: fixtures.directory)
            }

            bringUpAndWaitUntilKey(panel)
            panel.focusEditor()
            pump(0.1)
            let textView = FloatingPanel.firstTextView(in: panel.contentView!)
            check(textView != nil, "the editor is there to answer Escape")
            check(panel.firstResponder === textView, "the editor is first responder, as it is after every show")

            sendKey(panel, characters: "\u{1b}", keyCode: 53)
            check(!panel.isVisible, "Escape still dismisses the note, exactly as before the Cmd+period fix")
        }
    }
}
