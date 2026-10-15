import AppKit
import Foundation
import SwiftUI

// Issue #12, item 2: a mouse's Back/Forward side buttons switch notes.
//
// The headless suite pins the editor's half against a bare scroll view. What
// only the real panel can show is the whole route: which view AppKit's hit
// test picks inside the hosted ContentView, and that a press over the header,
// where SwiftUI draws without any NSView of its own, still climbs the
// responder chain to the panel instead of vanishing.
//
// Each press is handed to the view the hit test picks, which is the first
// thing `NSWindow.sendEvent` does with an other-button press, so none of this
// depends on which window happens to be key.

@MainActor
private func makeNavigationPanel() -> (panel: FloatingPanel, notes: NotesManager, directory: URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jot-ui-tests-\(UUID().uuidString)")
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"), allowsLegacyMigration: false)
    store.save([Note(text: "Alpha"), Note(text: "Beta"), Note(text: "Gamma")])
    let notes = NotesManager(store: store, saveDebounce: 0)
    let settings = SettingsManager(defaults: UserDefaults(suiteName: "uitest-\(UUID().uuidString)")!)
    settings.showsHeader = true
    notes.currentIndex = 1

    let panel = FloatingPanel(rootView: ContentView(notesManager: notes, settings: settings))
    panel.setFrame(NSRect(x: 160, y: 160, width: 400, height: 420), display: false)
    panel.contentView?.layoutSubtreeIfNeeded()
    pump(0.3)
    panel.contentView?.layoutSubtreeIfNeeded()
    return (panel, notes, directory)
}

@MainActor
private func pressSideButton(_ button: Int64, in panel: FloatingPanel, at point: NSPoint) -> NSView? {
    guard let base = NSEvent.mouseEvent(
        with: .otherMouseDown,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: panel.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ), let cg = base.cgEvent else { return nil }
    cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
    guard let event = NSEvent(cgEvent: cg),
          let target = panel.contentView?.hitTest(point) else { return nil }
    target.otherMouseDown(with: event)
    pump(0.1)
    return target
}

func runMouseNavigationTests() {
    MainActor.assumeIsolated {
        suite("Back/Forward over the note text switch notes through the swipe path") {
            let (panel, notes, directory) = makeNavigationPanel()
            defer {
                panel.orderOut(nil)
                try? FileManager.default.removeItem(at: directory)
            }
            let editorPoint = NSPoint(x: 200, y: 180)

            let target = pressSideButton(3, in: panel, at: editorPoint)
            check(target is ChecklistTextView, "the hit test lands on the text view itself")
            equal(notes.currentIndex, 0, "Back goes to the previous note")

            _ = pressSideButton(4, in: panel, at: editorPoint)
            equal(notes.currentIndex, 1, "Forward comes back")

            _ = pressSideButton(2, in: panel, at: editorPoint)
            equal(notes.currentIndex, 1, "a middle click switches nothing")
        }

        suite("Back/Forward over the header post the Cmd-Option-arrow requests") {
            let (panel, _, directory) = makeNavigationPanel()
            defer {
                panel.orderOut(nil)
                try? FileManager.default.removeItem(at: directory)
            }
            var posted: [Notification.Name] = []
            let tokens = [Notification.Name.jotRequestNextNote, .jotRequestPreviousNote].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { posted.append($0.name) }
            }
            defer { tokens.forEach(NotificationCenter.default.removeObserver) }

            // Inside the header strip, clear of its controls' centres.
            let headerPoint = NSPoint(x: 200, y: (panel.contentView?.bounds.height ?? 420) - 18)

            _ = pressSideButton(4, in: panel, at: headerPoint)
            _ = pressSideButton(3, in: panel, at: headerPoint)
            equal(posted, [.jotRequestNextNote, .jotRequestPreviousNote],
                  "both reach the panel, which asks for exactly what the keyboard shortcut asks for")

            panel.apply(mode: .edge)
            posted = []
            _ = pressSideButton(4, in: panel, at: headerPoint)
            equal(posted, [], "docked to an edge every note is already a card, so nothing is asked for")
        }
    }
}
