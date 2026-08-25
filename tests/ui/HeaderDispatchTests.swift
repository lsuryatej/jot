import AppKit
import Foundation

// The header's Checklist and Highlight buttons used to dispatch through
// `NSApp.sendAction(_:to: nil, from: nil)`, which walks the key window's
// responder chain. A rapid second click corrupted text instead of unwrapping
// it, and the fault was in how the click reached the view rather than in the
// toggle logic — which round-trips fine under direct calls, as
// tests/HighlightTests.swift already shows. That made the bug invisible to the
// headless suite: it has no key window and therefore no responder chain.
//
// The buttons now post `jotRequestToggleChecklistFromHeader` /
// `jotRequestToggleHighlightFromHeader`, which `ChecklistTextView` observes
// itself via `enableHeaderToggleButtons()`. This exercises that path with the
// view installed as the first responder of a real key window, which is the
// condition the old dispatch depended on and the old suite could not create.

@MainActor
private func makeHostedTextView(_ text: String) -> (window: NSWindow, view: ChecklistTextView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    view.baseFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.textStorage?.delegate = view
    view.string = text
    view.applyChecklistStyling()
    view.enableHeaderToggleButtons()

    window.contentView = view
    window.center()
    bringUpAndWaitUntilKey(window)
    window.makeFirstResponder(view)
    pump(0.2)
    return (window, view)
}

func runHeaderDispatchTests() {
    MainActor.assumeIsolated {
        suite("checklist toggle round-trips through the header notification in a key window") {
            let original = "buy milk\nwalk the dog"
            let (window, view) = makeHostedTextView(original)
            defer { window.close() }

            check(window.isKeyWindow, "text view's window is key")
            check(window.firstResponder === view, "text view is the first responder, so the old responder-chain dispatch would have reached it")

            view.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
            NotificationCenter.default.post(name: .jotRequestToggleChecklistFromHeader, object: nil)
            pump(0.1)
            let unchecked = "- [ ] buy milk\n- [ ] walk the dog"
            equal(view.string, unchecked, "first toggle turns both lines into checklist items")

            // Once lines are items, the toggle flips their checked state rather
            // than removing them, so the round trip is two more presses, not
            // one. Whatever selection the first toggle left behind is used as
            // is, which is the shape the header-button bug took in real use.
            NotificationCenter.default.post(name: .jotRequestToggleChecklistFromHeader, object: nil)
            pump(0.1)
            equal(view.string, "- [x] buy milk\n- [x] walk the dog", "second toggle checks both items")

            NotificationCenter.default.post(name: .jotRequestToggleChecklistFromHeader, object: nil)
            pump(0.1)
            equal(view.string, unchecked, "third toggle lands back exactly where the first one left it")
            check(!view.string.contains("- [ ] - ["), "no doubled checklist markers")
            check(view.string.contains("buy milk") && view.string.contains("walk the dog"),
                  "the note's own words survive the round trip intact")
        }

        suite("highlight toggle round-trips through the header notification in a key window") {
            let original = "ship the thing today"
            let (window, view) = makeHostedTextView(original)
            defer { window.close() }

            check(window.isKeyWindow, "text view's window is key")

            // "thing" — the shape the real bug took: wrap, then click again
            // using whatever selection the first toggle left behind.
            let target = (original as NSString).range(of: "thing")
            view.setSelectedRange(target)
            NotificationCenter.default.post(name: .jotRequestToggleHighlightFromHeader, object: nil)
            pump(0.1)
            equal(view.string, "ship the ==thing== today", "first toggle wraps the selection")

            NotificationCenter.default.post(name: .jotRequestToggleHighlightFromHeader, object: nil)
            pump(0.1)
            equal(view.string, original, "second toggle unwraps rather than nesting")
            check(!view.string.contains("="), "no stray highlight markers left behind")

            // A third and fourth pass, to be sure the round trip is stable
            // rather than accidentally balanced once.
            NotificationCenter.default.post(name: .jotRequestToggleHighlightFromHeader, object: nil)
            pump(0.1)
            NotificationCenter.default.post(name: .jotRequestToggleHighlightFromHeader, object: nil)
            pump(0.1)
            equal(view.string, original, "a second wrap/unwrap pair also lands back on the original")
        }
    }
}
