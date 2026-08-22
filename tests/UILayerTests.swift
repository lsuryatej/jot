import AppKit
import Foundation

// Real ChecklistTextView instances, exercised directly — no XCTest, no Xcode
// project, no running NSApplication. Layout, geometry, and event dispatch all
// work headlessly; only actual window-server interaction (real clicks, real
// screen rendering) is out of reach here, and none of what's tested needs it.
//
// This exists because every bug found by hand this project — font growth,
// caret position, paste dispatch, checklist click precision — lived in this
// exact layer, which until now had zero automated coverage. Pure-logic tests
// elsewhere could not have caught any of them.

private func makeTextView(_ text: String = "") -> ChecklistTextView {
    // Deliberately never attached to a real NSWindow: constructing one hangs
    // indefinitely in a plain command-line process with no window server
    // session, which this swiftc-only test binary is. handleSpecialClick(at:)
    // exists specifically so click behaviour is testable without one.
    let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    view.baseFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.textStorage?.delegate = view
    view.string = text
    view.applyChecklistStyling()
    return view
}

/// The on-screen rect of a character range, in the text view's own coordinate
/// space — the same transform `mouseDown` and the math/image renderers use
/// internally (glyph rect + textContainerInset).
private func viewRect(for range: NSRange, in view: ChecklistTextView) -> NSRect? {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return nil }
    lm.ensureLayout(for: tc)
    var rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
    rect.origin.x += view.textContainerInset.width
    rect.origin.y += view.textContainerInset.height
    return rect
}

/// `point` is in the text view's own (flipped) coordinate space, matching
/// `viewRect(for:in:)`. Calls the coordinate-independent hit-test method
/// directly rather than routing a synthesized event through the real
/// `mouseDown`, since that requires a real window (see `makeTextView`).
private func click(at point: NSPoint, on view: ChecklistTextView) {
    view.handleSpecialClick(at: point)
}

private func keyEquivalent(_ view: ChecklistTextView, chars: String, modifiers: NSEvent.ModifierFlags) -> Bool {
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: 0
    )!
    return view.performKeyEquivalent(with: event)
}

func runUILayerTests() {

    // MARK: - Cmd+L dispatch (the bug class: paste/shortcut dispatch)

    suite("Cmd+L toggles the checklist via performKeyEquivalent") {
        let view = makeTextView("- [ ] task")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        let handled = keyEquivalent(view, chars: "l", modifiers: .command)
        check(handled, "Cmd+L reports itself as handled, so AppKit does not also beep or insert 'l'")
        equal(view.string, "- [x] task", "the line actually toggled")
    }

    suite("Cmd+L with no command modifier does nothing") {
        let view = makeTextView("- [ ] task")
        let handled = keyEquivalent(view, chars: "l", modifiers: [])
        check(!handled, "plain 'l' is not a shortcut and must fall through to normal typing")
        equal(view.string, "- [ ] task", "text unchanged")
    }

    suite("Cmd+N posts the new-note notification rather than inserting 'n'") {
        let view = makeTextView("existing")
        var fired = false
        let token = NotificationCenter.default.addObserver(forName: .jotRequestNewNote, object: nil, queue: nil) { _ in
            fired = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let handled = keyEquivalent(view, chars: "n", modifiers: .command)
        check(handled, "Cmd+N reports itself as handled")
        check(fired, "the notification actually posted")
        equal(view.string, "existing", "text is untouched — 'n' must never land in the note")
    }

    suite("Shift-Cmd-V is claimed even with nothing on the clipboard") {
        // Regression guard for a shortcut silently falling through to normal
        // paste when there is no image to extract text from.
        let view = makeTextView("existing")
        let handled = keyEquivalent(view, chars: "V", modifiers: [.command, .shift])
        check(handled, "the app's own shortcut claims the event rather than falling through")
    }

    // MARK: - Checkbox click precision (the bug class: click misses the box)

    suite("clicking the checkbox toggles it") {
        let view = makeTextView("- [ ] buy milk")
        guard let item = Checklist.item(in: view.string) else {
            check(false, "fixture note should parse as a checklist item")
            return
        }
        let markerRect = viewRect(for: item.markerRange, in: view)!
        let center = NSPoint(x: markerRect.midX, y: markerRect.midY)

        click(at: center, on: view)
        equal(view.string, "- [x] buy milk", "click on the box toggled it")
    }

    suite("clicking the checkbox again unchecks it") {
        let view = makeTextView("- [x] buy milk")
        let item = Checklist.item(in: view.string)!
        let markerRect = viewRect(for: item.markerRange, in: view)!
        click(at: NSPoint(x: markerRect.midX, y: markerRect.midY), on: view)
        equal(view.string, "- [ ] buy milk", "toggled back")
    }

    suite("clicking body text on a checklist line does not toggle it") {
        let view = makeTextView("- [ ] buy milk")
        let ns = view.string as NSString
        let bodyRange = NSRange(location: ns.length - 2, length: 1) // inside "milk"
        let bodyRect = viewRect(for: bodyRange, in: view)!
        click(at: NSPoint(x: bodyRect.midX, y: bodyRect.midY), on: view)
        equal(view.string, "- [ ] buy milk", "clicking the text, not the box, just places the caret")
    }

    suite("clicking a plain line with no checkbox does not crash or mutate it") {
        let view = makeTextView("just a note, no checklist here")
        click(at: NSPoint(x: 20, y: 7), on: view)
        equal(view.string, "just a note, no checklist here", "unchanged")
    }

    // MARK: - Caret geometry (the bug class: caret drawn like a superscript)

    suite("caret rect is anchored to text height, not the full line box") {
        let view = makeTextView("hello")
        // A line box much taller than the text — the exact shape of the bug:
        // extra leading is not distributed evenly, so centering in the box
        // floated the caret above the glyphs instead of sitting on them.
        let tallLineBox = NSRect(x: 5, y: 0, width: 2, height: 40)
        let caret = view.caretRect(from: tallLineBox)

        let expectedHeight = ceil(view.baseFont.ascender - view.baseFont.descender)
        equal(caret.height, expectedHeight, "caret height matches the text, not the 40pt box")
        check(caret.height < tallLineBox.height, "caret is shorter than an inflated line box")
    }

    suite("caret rect passes through unchanged when the box is already text-sized") {
        let view = makeTextView("hi")
        let textHeight = ceil(view.baseFont.ascender - view.baseFont.descender)
        let normalBox = NSRect(x: 0, y: 0, width: 2, height: textHeight)
        let caret = view.caretRect(from: normalBox)
        equal(caret, normalBox, "no adjustment needed when the box is already the right size")
    }

    // MARK: - Image click hit-testing (the bug class: images not rendered/found where expected)

    suite("an image reference is found by placedImages at a real screen rect") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jot-ui-img-\(UUID().uuidString)")
        let attachDir = dir.appendingPathComponent("Attachments")
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        // A tiny real PNG (1x1), since NSImage needs to actually decode it.
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try? onePixelPNG.write(to: attachDir.appendingPathComponent("a.png"))

        setenv("JOT_NOTES_FILE", dir.appendingPathComponent("notes.json").path, 1)
        defer { unsetenv("JOT_NOTES_FILE") }

        let view = makeTextView("before\n![120](Attachments/a.png)\nafter")
        view.layoutSubtreeIfNeeded()
        let placed = view.placedImages()

        equal(placed.count, 1, "exactly one image reference found")
        if let first = placed.first {
            check(first.rect.width > 0 && first.rect.height > 0, "the placed rect has real, positive size")
        }
    }

    suite("no image references means an empty placement list, not a crash") {
        let view = makeTextView("nothing but text here")
        equal(view.placedImages().count, 0, "no images, no placements")
    }
}
