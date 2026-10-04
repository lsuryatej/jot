import AppKit
import Foundation

// Issue #10, "Visual bug with pasted images": Down arrow and double-click
// "jump around weirdly" around a pasted image.
//
// A pasted image is a markdown line (`![320](Attachments/<uuid>.png)`)
// painted clear, with the image drawn over it. The line is given the image's
// height through the paragraph style's min/max line height. The reference is
// ~60 characters, wider than a narrow note, so it wrapped. Min/max line
// height applies to *every* line fragment of a paragraph, so each wrapped
// piece of invisible markdown got its own image-tall line: a blank, image-
// sized gap under the picture. Down arrow walked into that gap (the caret
// appeared far below the image), and double-clicking there selected a word
// of the hidden path and scrolled to it. These tests pin the layout that
// makes both behave: an image-only line is exactly one line fragment.

private func writeLayoutScratchImage(width: Int = 200, height: Int = 100) -> String {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jot-image-layout-\(UUID().uuidString)")
    let attachmentsDir = directory.appendingPathComponent("Attachments", isDirectory: true)
    try! FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()

    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let name = "\(UUID().uuidString).png"
    try! png.write(to: attachmentsDir.appendingPathComponent(name))

    setenv("JOT_NOTES_FILE", directory.appendingPathComponent("notes.json").path, 1)
    return "Attachments/\(name)"
}

/// Every line fragment rect covering `characterRange`, top to bottom.
private func lineFragments(for characterRange: NSRange, in view: ChecklistTextView) -> [NSRect] {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return [] }
    lm.ensureLayout(for: tc)
    let glyphs = lm.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
    var rects: [NSRect] = []
    lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in rects.append(rect) }
    return rects
}

func runImageLineLayoutTests() {
    // The exact shape `insertImage` writes: the reference on its own line,
    // with a real line of text above and below. 400pt wide (makeTextView's
    // frame) at 13pt monospaced is narrower than the ~60-char reference, the
    // same situation as the menu-bar panel in the issue's video.
    func fixture() -> (view: ChecklistTextView, markdown: NSRange, imageLine: NSRange, after: NSRange)? {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: 240)
        let text = "before line\n\(markdown)\nafter line"
        let view = makeTextView(text)
        let ns = text as NSString
        let markdownRange = ns.range(of: markdown)
        guard markdownRange.location != NSNotFound else {
            check(false, "sanity: the reference is in the note")
            return nil
        }
        return (
            view,
            markdownRange,
            ns.lineRange(for: markdownRange),
            ns.range(of: "after line")
        )
    }

    suite("issue #10: a pasted image's line is one line fragment, not one per wrapped piece of hidden markdown") {
        guard let (view, markdown, _, _) = fixture() else { return }
        let fragments = lineFragments(for: markdown, in: view)
        equal(fragments.count, 1, "the hidden reference does not wrap onto extra image-tall lines")

        let expectedHeight = 240 * (100.0 / 200.0) + 6
        if let first = fragments.first {
            check(abs(first.height - expectedHeight) < 1,
                  "that one line is as tall as the image (\(first.height) vs \(expectedHeight))")
        }
        let total = fragments.reduce(0) { $0 + $1.height }
        check(total < expectedHeight * 1.5,
              "no blank image-sized gap under the picture (image line totals \(total)pt)")
    }

    suite("issue #10: Down arrow steps text -> image line -> next text line") {
        guard let (view, _, imageLine, after) = fixture() else { return }
        view.setSelectedRange(NSRange(location: 3, length: 0))

        view.moveDown(nil)
        let first = view.selectedRange().location
        check(NSLocationInRange(first, imageLine),
              "first Down lands on the image line (caret at \(first), image line \(imageLine))")

        view.moveDown(nil)
        let second = view.selectedRange().location
        check(second >= after.location && second <= after.location + after.length,
              "second Down lands on the line after the image, not in a gap under it (caret at \(second), after-line \(after))")
    }

    suite("issue #10: Up arrow from below the image steps back onto it, then above it") {
        guard let (view, _, imageLine, after) = fixture() else { return }
        view.setSelectedRange(NSRange(location: after.location + 3, length: 0))

        view.moveUp(nil)
        let first = view.selectedRange().location
        check(NSLocationInRange(first, imageLine),
              "first Up lands on the image line (caret at \(first))")

        view.moveUp(nil)
        let second = view.selectedRange().location
        check(second < imageLine.location,
              "second Up lands on the line above the image (caret at \(second))")
    }

    suite("issue #10: double-clicking an image line selects the whole reference, not a word of its hidden path") {
        guard let (view, markdown, _, _) = fixture() else { return }
        // A point in the middle of the path, e.g. inside the UUID.
        let inside = NSRange(location: markdown.location + markdown.length / 2, length: 0)
        let selected = view.selectionRange(forProposedRange: inside, granularity: .selectByWord)
        equal(selected, markdown, "the word selection snaps to the full image reference")

        // The whole selection sits on one line, so selecting it cannot scroll
        // the view past the image to reach a far-off wrapped piece.
        equal(lineFragments(for: selected, in: view).count, 1, "and that selection spans a single line")
    }

    suite("issue #10: double-click on ordinary text next to an image is untouched") {
        guard let (view, _, _, after) = fixture() else { return }
        let proposed = NSRange(location: after.location + 1, length: 0)
        let selected = view.selectionRange(forProposedRange: proposed, granularity: .selectByWord)
        equal(selected, NSRange(location: after.location, length: 5), "a plain word still selects as a word")
    }

    suite("issue #10: a line of ordinary long text still wraps normally") {
        let long = String(repeating: "wrap me please ", count: 20)
        let view = makeTextView(long)
        let fragments = lineFragments(for: NSRange(location: 0, length: (long as NSString).length), in: view)
        check(fragments.count > 1, "text that is not an image reference keeps wrapping (\(fragments.count) lines)")
    }
}

// Maintainer hand-test on the image fix: "I'm able to go back to the line
// covered by the image and type into the name of the image, thus changing the
// intended effect altogether." The caret could sit anywhere inside the hidden
// `![320](Attachments/<uuid>.png)`, so typing `12345` produced
// `...41FB.p12345ng)`, the image broke and the raw markdown showed. A loaded
// reference now behaves like one attachment character: the caret sits before
// it or after it, never inside, and deleting it removes it whole.

/// Supplies an undo manager to a text view with no window, through the
/// delegate hook NSTextView consults first.
private final class AtomicUndoProvider: NSObject, NSTextViewDelegate {
    let manager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

func runImageAtomicReferenceTests() {
    func fixture(above: String = "before line") -> (view: ChecklistTextView, text: String, s: Int, e: Int)? {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: 240)
        let text = "\(above)\n\(markdown)\nafter line"
        let view = makeTextView(text)
        let range = (text as NSString).range(of: markdown)
        guard range.location != NSNotFound else {
            check(false, "sanity: the reference is in the note")
            return nil
        }
        return (view, text, range.location, NSMaxRange(range))
    }

    func caret(_ view: ChecklistTextView) -> Int { view.selectedRange().location }

    suite("image atomic: Right arrow from before the image jumps over the whole reference") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: s, length: 0))
        view.moveRight(nil)
        equal(view.selectedRange(), NSRange(location: e, length: 0), "one Right lands after the image")
        view.moveRight(nil)
        equal(caret(view), e + 1, "the next Right goes on to the following line")
    }

    suite("image atomic: Left arrow from after the image jumps back over it") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: e + 1, length: 0))
        view.moveLeft(nil)
        equal(caret(view), e, "Left from the next line stops just after the image")
        view.moveLeft(nil)
        equal(view.selectedRange(), NSRange(location: s, length: 0), "one more Left lands before the image")
    }

    suite("image atomic: Option-arrow word moves also treat the reference as one unit") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: s, length: 0))
        view.moveWordRight(nil)
        equal(caret(view), e, "Option-Right from before the image lands after it")
        view.moveWordLeft(nil)
        equal(caret(view), s, "Option-Left from after the image lands before it")
    }

    suite("image atomic: a caret placed inside the reference snaps to the nearer edge") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: s + 3, length: 0))
        equal(caret(view), s, "a caret under the left of the image goes before it")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: e - 3, length: 0))
        equal(caret(view), e, "a caret past the image's middle goes after it")
    }

    suite("image atomic: Down from the right half of the line above lands after the image, never inside") {
        guard let (view, _, s, e) = fixture(above: String(repeating: "x", count: 40)) else { return }
        // 40 characters fit on one line of the 400pt test view; column 35
        // sits well to the right of the 240pt image's middle.
        view.setSelectedRange(NSRange(location: 35, length: 0))
        view.moveDown(nil)
        equal(caret(view), e, "Down under the right half of the image lands after it (s=\(s))")

        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.moveDown(nil)
        equal(caret(view), s, "Down under the left half of the image lands before it")
    }

    suite("image atomic: Up from the line below never leaves the caret inside the reference") {
        guard let (view, text, s, e) = fixture() else { return }
        let after = (text as NSString).range(of: "after line")
        view.setSelectedRange(NSRange(location: after.location + 8, length: 0))
        view.moveUp(nil)
        let landed = caret(view)
        check(landed == s || landed == e, "Up lands on an edge of the reference (caret \(landed), s=\(s), e=\(e))")
    }

    suite("image atomic: clicking an image places the caret by which half was clicked") {
        guard let (view, _, s, e) = fixture() else { return }
        guard let placed = view.placedImages().first else {
            check(false, "the image is laid out")
            return
        }
        equal(view.caretLocation(forClickOn: placed, at: NSPoint(x: placed.rect.minX + 10, y: placed.rect.midY)), s,
              "the left half puts the caret before the image")
        equal(view.caretLocation(forClickOn: placed, at: NSPoint(x: placed.rect.maxX - 10, y: placed.rect.midY)), e,
              "the right half puts the caret after the image")
    }

    suite("image atomic: clicking the image line to the right of the image puts the caret after it") {
        guard let (view, _, _, e) = fixture() else { return }
        guard let placed = view.placedImages().first else {
            check(false, "the image is laid out")
            return
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let index = view.characterIndexForInsertion(at: NSPoint(x: placed.rect.maxX + 60, y: placed.rect.midY))
        view.setSelectedRange(NSRange(location: index, length: 0))
        equal(caret(view), e, "the empty space beside the image belongs to its end (hit index \(index))")
    }

    suite("image atomic: typing before the image goes on a new line above it") {
        guard let (view, text, s, _) = fixture() else { return }
        let markdown = (text as NSString).substring(with: NSRange(location: s, length: (text as NSString).range(of: "\nafter").location - s))
        view.setSelectedRange(NSRange(location: s, length: 0))
        view.insertText("12345", replacementRange: NSRange(location: NSNotFound, length: 0))
        equal(view.string, "before line\n12345\n\(markdown)\nafter line", "the reference is untouched, alone on its line")
        equal(view.selectedRange(), NSRange(location: s + 5, length: 0), "the caret follows the typed text")
        view.insertText("6", replacementRange: NSRange(location: NSNotFound, length: 0))
        equal(view.string, "before line\n123456\n\(markdown)\nafter line", "and typing carries on on that line")
        equal(Attachments.references(in: view.string).count, 1, "the reference still parses")
    }

    suite("image atomic: typing after the image goes on a new line below it") {
        guard let (view, text, s, e) = fixture() else { return }
        let markdown = (text as NSString).substring(with: NSRange(location: s, length: e - s))
        view.setSelectedRange(NSRange(location: e, length: 0))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        equal(view.string, "before line\n\(markdown)\nx\nafter line", "the typed text starts its own line")
        equal(caret(view), e + 2, "the caret follows it")
    }

    suite("image atomic: a paste before the image also keeps the image alone on its line") {
        guard let (view, text, s, e) = fixture() else { return }
        let markdown = (text as NSString).substring(with: NSRange(location: s, length: e - s))
        view.setSelectedRange(NSRange(location: s, length: 0))
        check(view.insertAtImageEdge("pasted"), "an insertion at the image's edge is handled")
        equal(view.string, "before line\npasted\n\(markdown)\nafter line", "pasted text lands on its own line")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        check(!view.insertAtImageEdge("plain"), "anywhere else inserts normally")
    }

    suite("image atomic: Return after the image opens a new line below it") {
        guard let (view, text, s, e) = fixture() else { return }
        let markdown = (text as NSString).substring(with: NSRange(location: s, length: e - s))
        view.setSelectedRange(NSRange(location: e, length: 0))
        view.insertNewline(nil)
        equal(view.string, "before line\n\(markdown)\n\nafter line", "one empty line below the image")
        equal(caret(view), e + 1, "the caret is on it")
    }

    suite("image atomic: Backspace after the image deletes the whole reference in one undo step") {
        guard let (view, text, s, e) = fixture() else { return }
        let provider = AtomicUndoProvider()
        view.delegate = provider
        view.allowsUndo = true
        view.setSelectedRange(NSRange(location: e, length: 0))
        provider.manager.beginUndoGrouping()
        view.deleteBackward(nil)
        provider.manager.endUndoGrouping()
        equal(view.string, "before line\n\nafter line", "the reference is gone, not one character of it")
        equal(view.selectedRange(), NSRange(location: s, length: 0), "the caret sits where the image was")
        provider.manager.undo()
        equal(view.string, text, "one undo brings the image back")
        check(!provider.manager.canUndo, "and that was the only step")
        view.delegate = nil
    }

    suite("image atomic: Forward-delete before the image deletes the whole reference") {
        guard let (view, _, s, _) = fixture() else { return }
        view.setSelectedRange(NSRange(location: s, length: 0))
        view.deleteForward(nil)
        equal(view.string, "before line\n\nafter line", "the whole reference goes")
        equal(caret(view), s, "the caret stays put")
    }

    suite("image atomic: Option-Backspace after the image deletes the whole reference") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: e, length: 0))
        view.deleteWordBackward(nil)
        equal(view.string, "before line\n\nafter line", "no fragment of the path is left behind")
        equal(caret(view), s, "the caret sits where the image was")
    }

    suite("image atomic: a selection that half-covers the reference grows to cover all of it") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: 3, length: s + 5 - 3))
        equal(view.selectedRange(), NSRange(location: 3, length: e - 3), "the end moves out to the image's end")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: s + 4, length: e + 3 - (s + 4)))
        equal(view.selectedRange(), NSRange(location: s, length: e + 3 - s), "the start moves back to the image's start")
    }

    suite("image atomic: Shift-arrows select the image as one unit, and deselect it the same way") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: s, length: 0))
        view.moveRightAndModifySelection(nil)
        equal(view.selectedRange(), NSRange(location: s, length: e - s), "Shift-Right selects the whole image")
        view.moveLeftAndModifySelection(nil)
        equal(view.selectedRange(), NSRange(location: s, length: 0), "Shift-Left deselects it whole")
    }

    suite("image atomic: typing over a selected image replaces all of it") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: s, length: e - s))
        view.insertText("gone", replacementRange: NSRange(location: NSNotFound, length: 0))
        equal(view.string, "before line\ngone\nafter line", "no half-reference survives")
    }

    suite("image atomic: a reference that does not load stays ordinary, editable text") {
        let broken = "![240](Attachments/does-not-exist-\(UUID().uuidString).png)"
        let text = "before line\n\(broken)\nafter line"
        let view = makeTextView(text)
        let range = (text as NSString).range(of: broken)
        view.setSelectedRange(NSRange(location: range.location + 3, length: 0))
        equal(caret(view), range.location + 3, "the caret may sit inside a broken reference to fix it")
        view.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        view.deleteBackward(nil)
        equal((view.string as NSString).length, (text as NSString).length - 1, "Backspace removes one character")
        view.setSelectedRange(NSRange(location: range.location, length: 0))
        view.moveRight(nil)
        equal(caret(view), range.location + 1, "Right moves one character")
    }
}

// Maintainer hand-test: "caret sometimes appears near image rather than near
// typing position." `drawInsertionPoint` moved the caret onto a baseline it
// looked up from `selectedRange()`, not from the rect AppKit asked it to draw.
// Two ways that went wrong, both near an image:
//
// - On the empty line under an image (where a paste leaves the caret) the
//   lookup clamped to the last character, the image line's newline, so the
//   caret was drawn up at the foot of the image.
// - AppKit erases a caret by redrawing the rect it passed in. A caret drawn
//   somewhere else, from a selection that had already moved on, was never
//   erased: a stale copy stayed behind beside the image.
//
// The caret is now derived from the rect it is given, and stays inside it.

/// AppKit's insertion rect for a caret at `index`, in view coordinates.
private func appKitCaretRect(at index: Int, in view: ChecklistTextView) -> NSRect? {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return nil }
    lm.ensureLayout(for: tc)
    let caret = NSRange(location: index, length: 0)
    var count = 0
    guard let rects = lm.rectArray(
        forCharacterRange: caret, withinSelectedCharacterRange: caret, in: tc, rectCount: &count
    ), count > 0 else { return nil }
    return rects[0].offsetBy(dx: view.textContainerInset.width, dy: view.textContainerInset.height)
}

func runImageCaretTests() {
    func fixture(_ text: (String) -> String) -> (view: ChecklistTextView, text: String, markdown: NSRange)? {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: 240)
        let text = text(markdown)
        let view = makeTextView("")
        view.lineHeightMultiple = 1.5
        view.textContainerInset = NSSize(width: 20, height: 12)
        view.string = text
        view.applyChecklistStyling()
        let range = (text as NSString).range(of: markdown)
        guard range.location != NSNotFound else {
            check(false, "sanity: the reference is in the note")
            return nil
        }
        return (view, text, range)
    }

    suite("image caret: on the empty line under a pasted image the caret draws on that line") {
        guard let (view, text, markdown) = fixture({ "before line\n\($0)\n" }) else { return }
        let end = (text as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        guard let box = appKitCaretRect(at: end, in: view), let placed = view.placedImages().first else {
            check(false, "the caret and the image are laid out")
            return
        }
        let drawn = view.caretRect(from: box)
        check(drawn.minY >= placed.rect.maxY,
              "the caret is below the image (\(drawn.minY) vs image bottom \(placed.rect.maxY)), not at its foot")
        check(drawn.minY >= box.minY - 0.5 && drawn.maxY <= box.maxY + 0.5,
              "and inside the rect AppKit asked for (\(drawn) in \(box))")
        _ = markdown
    }

    suite("image caret: every caret is drawn inside the rect AppKit passed, whatever the selection is now") {
        guard let (view, text, markdown) = fixture({ "above\n\($0)\nbelow\n" }) else { return }
        let length = (text as NSString).length
        let edges = [0, 3, markdown.location, NSMaxRange(markdown), NSMaxRange(markdown) + 1, length - 2, length]
        var escaped: [String] = []
        for drawnAt in edges {
            guard let box = appKitCaretRect(at: drawnAt, in: view) else { continue }
            // The selection has already moved somewhere else, the way it has
            // by the time AppKit erases the old caret.
            for selectedAt in edges where selectedAt != drawnAt {
                view.setSelectedRange(NSRange(location: selectedAt, length: 0))
                let drawn = view.caretRect(from: box)
                if drawn.minY < box.minY - 0.5 || drawn.maxY > box.maxY + 0.5 {
                    escaped.append("caret for \(drawnAt) with selection at \(selectedAt): \(drawn) outside \(box)")
                }
            }
        }
        check(escaped.isEmpty, "no caret is drawn where erasing its rect would miss it: \(escaped.prefix(3))")
    }

    suite("image caret: on a text line beside an image line the caret sits on that text's baseline") {
        guard let (view, text, _) = fixture({ "above\n\($0)\nbelow" }) else { return }
        let below = (text as NSString).range(of: "below")
        guard let box = appKitCaretRect(at: below.location + 2, in: view),
              let lm = view.layoutManager else { return }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let drawn = view.caretRect(from: box)
        let glyph = lm.glyphIndexForCharacter(at: below.location + 2)
        let baseline = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            + lm.location(forGlyphAt: glyph).y + view.textContainerInset.height
        check(abs(drawn.minY - (baseline - ceil(view.baseFont.ascender))) < 0.5,
              "the caret's top is one ascender above the line's baseline (\(drawn.minY) vs \(baseline))")
    }
}
