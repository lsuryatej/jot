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

    // The reference is one image-wide glyph followed by zero-width ones, so
    // every position inside it is drawn at the image's trailing edge, and
    // snapping by where it is drawn sends it there. Clicks, which land by
    // half, are covered further down.
    suite("image atomic: a caret placed inside the reference snaps to the edge it is drawn at") {
        guard let (view, _, s, e) = fixture() else { return }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: s + 3, length: 0))
        equal(caret(view), e, "a caret inside the reference goes after the image")
        check(caret(view) != s + 3, "and never stays inside (s=\(s))")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: e - 3, length: 0))
        equal(caret(view), e, "near the end too")
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

// Maintainer-approved: "caret after an image sits beside the image." The
// hidden markdown was clipped to one line, but its glyphs still spanned the
// whole column, so the caret after an image drew at the right edge of the
// note. The reference's glyphs now take exactly the image's drawn width: one
// carries the width, the rest take none.
func runImageGlyphWidthTests() {
    func fixture(width: CGFloat = 240, text: (String) -> String = { "before line\n\($0)\nafter line" })
        -> (view: ChecklistTextView, markdown: NSRange)? {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: width)
        let full = text(markdown)
        let view = makeTextView(full)
        let range = (full as NSString).range(of: markdown)
        guard range.location != NSNotFound else {
            check(false, "sanity: the reference is in the note")
            return nil
        }
        return (view, range)
    }

    suite("image glyphs: the hidden reference is exactly as wide as the image") {
        guard let (view, markdown) = fixture(), let lm = view.layoutManager, let tc = view.textContainer,
              let placed = view.placedImages().first else { return }
        lm.ensureLayout(for: tc)
        let glyphs = lm.glyphRange(forCharacterRange: markdown, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        check(abs(rect.width - placed.rect.width) < 0.5,
              "the reference's glyphs span \(rect.width)pt, the image \(placed.rect.width)pt")
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        check(used.width < placed.rect.width + 20,
              "the image line is no wider than the image (\(used.width)pt used)")
    }

    suite("image glyphs: the caret after an image sits at its trailing edge, the caret before at its leading edge") {
        guard let (view, markdown) = fixture(), let placed = view.placedImages().first,
              let after = appKitCaretRect(at: NSMaxRange(markdown), in: view),
              let before = appKitCaretRect(at: markdown.location, in: view) else {
            check(false, "the image and its carets are laid out")
            return
        }
        check(abs(after.minX - placed.rect.maxX) < 1, "after: x \(after.minX) at the image's right edge \(placed.rect.maxX)")
        check(abs(before.minX - placed.rect.minX) < 1, "before: x \(before.minX) at the image's left edge \(placed.rect.minX)")
        view.setSelectedRange(NSRange(location: NSMaxRange(markdown), length: 0))
        let drawn = view.caretRect(from: after)
        check(drawn.minY > placed.rect.midY,
              "the caret is text-high at the foot of the image line, like an attachment (\(drawn) vs image \(placed.rect))")
    }

    suite("image glyphs: none of the hidden markdown is ever drawn") {
        guard let (view, markdown) = fixture(), let lm = view.layoutManager, let tc = view.textContainer else { return }
        lm.ensureLayout(for: tc)
        let glyphs = lm.glyphRange(forCharacterRange: markdown, actualCharacterRange: nil)
        let shown = (glyphs.location..<NSMaxRange(glyphs)).filter { !lm.notShownAttribute(forGlyphAt: $0) }
        check(shown.isEmpty, "every glyph of the reference is not-shown, so no selection colour can reveal it (\(shown.count) shown)")
    }

    suite("image glyphs: an image wider than the column is drawn at the column's width, on one line") {
        guard let (view, markdown) = fixture(width: 900), let tc = view.textContainer,
              let placed = view.placedImages().first else { return }
        let column = tc.size.width - 2 * tc.lineFragmentPadding
        check(placed.rect.width <= column + 0.5, "the image fits the column (\(placed.rect.width) <= \(column))")
        check(abs(placed.rect.height - placed.rect.width / 2) < 0.5, "and keeps its aspect ratio")
        let fragments = lineFragments(for: markdown, in: view)
        equal(fragments.count, 1, "on one line")
        if let first = fragments.first {
            check(abs(first.height - (placed.rect.height + 6)) < 1, "as tall as the fitted image (\(first.height))")
        }
    }

    suite("image glyphs: text sharing a line with an image does not wrap the hidden markdown into gaps") {
        guard let (view, markdown) = fixture(width: 120, text: { "before\nsee \($0) here\nafter" }) else { return }
        let fragments = lineFragments(for: markdown, in: view)
        equal(fragments.count, 1, "one line: the reference takes the image's width, not ~60 characters")
    }
}

func runImageGlyphClickTests() {
    suite("image glyphs: AppKit's own hit-testing puts a click on an image before or after it by half") {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: 240)
        let text = "before line\n\(markdown)\nafter line"
        let view = makeTextView(text)
        let range = (text as NSString).range(of: markdown)
        guard let placed = view.placedImages().first else {
            check(false, "the image is laid out")
            return
        }
        for (x, expected, label) in [
            (placed.rect.minX + 20, range.location, "left half: before"),
            (placed.rect.maxX - 20, NSMaxRange(range), "right half: after"),
        ] {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let index = view.characterIndexForInsertion(at: NSPoint(x: x, y: placed.rect.midY))
            view.setSelectedRange(NSRange(location: index, length: 0))
            equal(view.selectedRange().location, expected, "\(label) (hit index \(index))")
        }
    }
}

// Maintainer screenshot: with the whole reference selected, the hidden
// `![320](Attachments/A81E…` showed at the foot of the image line in the
// selection colour. The glyphs are never drawn now (see the glyph-width
// tests); what is left is how a selected image looks. Like an attachment in
// any Mac text view: a tint over the picture, not a text selection band.
func runImageSelectionTests() {
    func fixture() -> (view: ChecklistTextView, markdown: NSRange, text: String)? {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: 240)
        let text = "before line\n\(markdown)\nafter line"
        let view = makeTextView(text)
        let range = (text as NSString).range(of: markdown)
        guard range.location != NSNotFound else { return nil }
        return (view, range, text)
    }
    func bandColor(_ view: ChecklistTextView) -> NSColor? {
        view.selectedTextAttributes[.backgroundColor] as? NSColor
    }

    suite("image selection: a selected image is tinted over its picture, with no text band") {
        guard let (view, markdown, _) = fixture(), let placed = view.placedImages().first else {
            check(false, "the image is laid out")
            return
        }
        view.setSelectedRange(markdown)
        equal(view.selectedImageRects(), [placed.rect], "the tint covers exactly the picture")
        check(bandColor(view).map { $0.alphaComponent == 0 } ?? true,
              "the selection band is not painted for a selection that is only the image")
    }

    suite("image selection: a selection of text keeps its band, and no image is tinted") {
        guard let (view, _, _) = fixture() else { return }
        view.setSelectedRange(NSRange(location: 0, length: 6))
        check(view.selectedImageRects().isEmpty, "nothing tinted")
        check((bandColor(view)?.alphaComponent ?? 0) > 0, "the band is back for text")
    }

    suite("image selection: text and an image selected together: band for the text, tint for the image") {
        guard let (view, markdown, text) = fixture(), let placed = view.placedImages().first else { return }
        let after = (text as NSString).range(of: "after line")
        view.setSelectedRange(NSRange(location: 3, length: NSMaxRange(after) - 3))
        equal(view.selectedImageRects(), [placed.rect], "the image inside the selection is tinted")
        check((bandColor(view)?.alphaComponent ?? 0) > 0, "and the text keeps its band")
        _ = markdown
    }

    suite("image selection: deselecting the image clears its tint") {
        guard let (view, markdown, _) = fixture() else { return }
        view.setSelectedRange(markdown)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        check(view.selectedImageRects().isEmpty, "no tint left behind")
        check((bandColor(view)?.alphaComponent ?? 0) > 0, "and the band colour is restored for the next selection")
    }
}

// Maintainer hand-test: "not able to resize." Driving the real app with real
// window-server drags resized fine from the middle of a picture, so the
// tracking loop was never the problem; reaching it was. The resize cursor
// never showed (NSTextView's own cursor update puts the I-beam back over any
// cursor rect), so nothing said where to grab, and the natural grab point,
// the picture's right edge, missed by a point: a real press at x=345.7 on a
// picture ending at 345 started a text selection instead (probe log). In the
// maintainer's 360pt window a 320pt picture also overran the 310pt column.
func runImageResizeHandleTests() {
    func fixture() -> (view: ChecklistTextView, placed: ChecklistTextView.PlacedImage)? {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: 240)
        let view = makeTextView("before line\n\(markdown)\nafter line")
        guard let placed = view.placedImages().first else {
            check(false, "the image is laid out")
            return nil
        }
        return (view, placed)
    }

    suite("image resize: the grab zone reaches a few points past the picture's right edge") {
        guard let (view, placed) = fixture() else { return }
        check(view.imageForResize(at: NSPoint(x: placed.rect.midX, y: placed.rect.midY)) != nil, "on the picture")
        check(view.imageForResize(at: NSPoint(x: placed.rect.maxX + 4, y: placed.rect.midY)) != nil,
              "just past its right edge, where a resize is grabbed")
        check(view.imageForResize(at: NSPoint(x: placed.rect.maxX + 20, y: placed.rect.midY)) == nil,
              "but not the empty line beyond, which still places the caret")
        check(view.imageForResize(at: NSPoint(x: placed.rect.midX, y: placed.rect.maxY + 30)) == nil,
              "nor the line below")
    }

    suite("image resize: the pointer says resize over the picture and its edge, I-beam elsewhere") {
        guard let (view, placed) = fixture() else { return }
        check(view.wantsResizeCursor(at: NSPoint(x: placed.rect.midX, y: placed.rect.midY)), "over the picture")
        check(view.wantsResizeCursor(at: NSPoint(x: placed.rect.maxX + 3, y: placed.rect.midY)), "over its edge")
        check(!view.wantsResizeCursor(at: NSPoint(x: 10, y: 4)), "not over text")
    }

    suite("image resize: a press that moves less than the drag threshold is a click") {
        check(!ChecklistTextView.isResizeDrag(from: NSPoint(x: 100, y: 50), to: NSPoint(x: 102, y: 51)),
              "2pt of hand jitter is still a click, so the caret is placed and the width left alone")
        check(ChecklistTextView.isResizeDrag(from: NSPoint(x: 100, y: 50), to: NSPoint(x: 104, y: 50)),
              "a few points sideways is a drag")
    }

    suite("image resize: a drag never makes a picture wider than the room left on its line") {
        guard let (view, placed) = fixture() else { return }
        let room = view.resizeRoom(for: placed)
        check(room > placed.rect.width && room <= view.imageColumnWidth,
              "the room (\(room)) is more than the picture and no more than the column")
        equal(ChecklistTextView.resizedWidth(from: 0, to: 5000, starting: placed.rect.width, maximum: room), room,
              "an enormous rightward drag stops at the room")
    }
}

// Maintainer: "image lines shouldn't be skipped in list mode, they should
// behave like the image is part of an option in the list." An item whose
// body is an image renders its marker, then the picture on the same line, as
// one item. Atomic caret rules apply to the reference, never the marker.
func runImageListItemTests() {
    func fixture(_ build: (String) -> String) -> (view: ChecklistTextView, text: String, markdown: NSRange, path: String)? {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: 160)
        let text = build(markdown)
        let view = makeTextView(text)
        let range = (text as NSString).range(of: markdown)
        guard range.location != NSNotFound else {
            check(false, "sanity: the reference is in the note")
            return nil
        }
        return (view, text, range, path)
    }

    /// Where body text starts on an item line with `prefix`, measured on a
    /// text item of the same shape.
    func bodyX(prefix: String) -> CGFloat {
        let view = makeTextView("\(prefix)word")
        guard let lm = view.layoutManager, let tc = view.textContainer else { return -1 }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: (prefix as NSString).length)
        return lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).minX
            + view.textContainerInset.width
    }

    for prefix in ["- [ ] ", "- [x] ", "- ", "1. "] {
        suite("image list item: `\(prefix)` then an image renders as one item line") {
            guard let (view, _, markdown, _) = fixture({ "before\n\(prefix)\($0)\nafter" }),
                  let placed = view.placedImages().first else {
                check(false, "the image is laid out")
                return
            }
            check(abs(placed.rect.minX - bodyX(prefix: prefix)) < 1,
                  "the picture starts where the item's text would (\(placed.rect.minX) vs \(bodyX(prefix: prefix)))")
            let line = (view.string as NSString).lineRange(for: markdown)
            let fragments = lineFragments(for: line, in: view)
            equal(fragments.count, 1, "marker and picture share one line, no wrapped-markdown gap")
            if let first = fragments.first {
                check(abs(first.height - (placed.rect.height + 6)) < 1,
                      "the line fits the picture (\(first.height) vs \(placed.rect.height + 6))")
            }
            check(abs(placed.rect.height - 80) < 0.5, "the picture keeps its own size")
        }
    }

    suite("image list item: clicking the checkbox toggles the item and keeps the image") {
        guard let (view, _, markdown, _) = fixture({ "before\n- [ ] \($0)" }),
              let lm = view.layoutManager, let tc = view.textContainer else { return }
        let markerStart = markdown.location - 6
        lm.ensureLayout(for: tc)
        var box = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: markerStart + 1, length: 1),
                                                               actualCharacterRange: nil), in: tc)
        box.origin.x += view.textContainerInset.width
        box.origin.y += view.textContainerInset.height
        check(view.handleSpecialClick(at: NSPoint(x: box.midX, y: box.midY)), "the click on the box is claimed")
        check(view.string.contains("- [x] ![160]"), "the item is checked")
        equal(view.placedImages().count, 1, "and the image is still drawn")
        check(view.placedImages().first?.isDimmed == true, "dimmed, the way a checked item's text is")
    }

    suite("image list item: a checked item strikes through nothing under the picture") {
        guard let (view, _, markdown, _) = fixture({ "before\n- [x] \($0)" }), let storage = view.textStorage else { return }
        var struck = false
        storage.enumerateAttribute(.strikethroughStyle, in: markdown) { value, _, _ in
            if let value = value as? Int, value != 0 { struck = true }
        }
        check(!struck, "no strikethrough line is drawn across the image")
    }

    suite("image list item: Left and Right step over the reference, never into the marker or the path") {
        guard let (view, _, markdown, _) = fixture({ "before\n- [ ] \($0)\nafter" }) else { return }
        let s = markdown.location
        let e = NSMaxRange(markdown)
        view.setSelectedRange(NSRange(location: e, length: 0))
        view.moveLeft(nil)
        equal(view.selectedRange().location, s, "Left from after the image lands just after the marker")
        view.moveLeft(nil)
        equal(view.selectedRange().location, s - 1, "and the next Left moves into the marker as text")
        view.setSelectedRange(NSRange(location: s, length: 0))
        view.moveRight(nil)
        equal(view.selectedRange().location, e, "Right from before the image jumps over it")
    }

    suite("image list item: Backspace after the image removes the reference and keeps the marker") {
        guard let (view, _, markdown, _) = fixture({ "before\n- [ ] \($0)\nafter" }) else { return }
        view.setSelectedRange(NSRange(location: NSMaxRange(markdown), length: 0))
        view.deleteBackward(nil)
        equal(view.string, "before\n- [ ] \nafter", "only the image goes")
    }

    suite("image list item: Return after the image starts a new item below") {
        guard let (view, text, markdown, _) = fixture({ "list\n- [ ] \($0)" }) else { return }
        view.setSelectedRange(NSRange(location: NSMaxRange(markdown), length: 0))
        view.insertNewline(nil)
        equal(view.string, text + "\n- [ ] ", "a fresh empty item")
        equal(view.selectedRange().location, (view.string as NSString).length, "with the caret in it")
    }

    suite("image list item: typing after the image goes into a new item below, before it into one above") {
        guard let (view, text, markdown, _) = fixture({ "list\n- [ ] \($0)\nafter" }) else { return }
        let md = (text as NSString).substring(with: markdown)
        view.setSelectedRange(NSRange(location: NSMaxRange(markdown), length: 0))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        equal(view.string, "list\n- [ ] \(md)\n- [ ] x\nafter", "typed text starts its own item")
        equal(view.selectedRange().location, ("list\n- [ ] \(md)\n- [ ] x" as NSString).length, "caret after it")

        view.setSelectedRange(NSRange(location: markdown.location, length: 0))
        view.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        equal(view.string, "list\n- [ ] y\n- [ ] \(md)\n- [ ] x\nafter", "typed before the image: an item above")
        equal(view.selectedRange().location, ("list\n- [ ] y" as NSString).length, "caret after the typed text")
    }

    suite("image list item: converting a note to list mode wraps image lines as items that render") {
        let path = writeLayoutScratchImage()
        let markdown = Attachments.markdown(path: path, width: 160)
        let converted = Checklist.convertedToList("list\nmilk\n\(markdown)", keyword: "list")
        equal(converted, "list\n- [ ] milk\n- [ ] \(markdown)", "the image line becomes an item")
        let view = makeTextView(converted)
        let range = (converted as NSString).range(of: markdown)
        equal(lineFragments(for: (converted as NSString).lineRange(for: range), in: view).count, 1,
              "and renders on one line")
        equal(view.placedImages().count, 1, "with its picture")
    }

    suite("image list item: an image pasted on an empty item fills that item") {
        guard let (view, _, _, _) = fixture({ "list\n- [ ] milk\n- [ ] \n\($0)" }) else { return }
        let ns = view.string as NSString
        let empty = ns.range(of: "- [ ] \n").location + 6
        let image = writeLayoutScratchNSImage()
        view.insertImage(image, at: empty)
        let line = ns.lineRange(for: NSRange(location: empty, length: 0))
        let newLine = (view.string as NSString).substring(with: (view.string as NSString).lineRange(for: NSRange(location: line.location, length: 0)))
        check(newLine.hasPrefix("- [ ] ![") && newLine.hasSuffix(".png)\n"), "the item now holds the image (\(newLine))")
        check(view.string.hasPrefix("list\n- [ ] milk\n- [ ] !["), "nothing else moved")
    }

    for (prefix, next) in [("- [ ] ", "- [ ] "), ("- [x] ", "- [ ] "), ("- ", "- "), ("3. ", "4. ")] {
        suite("image list item: an image pasted on `\(prefix)milk` becomes the next item, `\(next)`") {
            let view = makeTextView("before\n\(prefix)milk\nafter")
            let image = writeLayoutScratchNSImage()
            view.insertImage(image, at: ("before\n\(prefix)mi" as NSString).length)
            let lines = view.string.components(separatedBy: "\n")
            equal(lines.count, 4, "one line added (\(lines))")
            if lines.count == 4 {
                equal(lines[1], "\(prefix)milk", "the item is untouched")
                check(lines[2].hasPrefix("\(next)![") && lines[2].hasSuffix(".png)"), "the image is the next item (\(lines[2]))")
                equal(lines[3], "after", "the rest stays")
            }
            let caret = view.selectedRange().location
            equal(caret, ("before\n\(prefix)milk\n\(lines.count == 4 ? lines[2] : "")" as NSString).length,
                  "the caret is after the image, ready for Return")
        }
    }

    suite("image list item: in list mode an image pasted on a plain line lands as an item") {
        let view = makeTextView("list\n")
        view.insertImage(writeLayoutScratchNSImage(), at: 5)
        check(view.string.hasPrefix("list\n- [ ] !["), "wrapped as an item (\(view.string))")
    }
}

/// An in-memory image, for `insertImage`, which saves it beside the notes
/// file `writeLayoutScratchImage` points at.
private func writeLayoutScratchNSImage() -> NSImage {
    _ = writeLayoutScratchImage()
    let image = NSImage(size: NSSize(width: 120, height: 60))
    image.lockFocus()
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: 120, height: 60).fill()
    image.unlockFocus()
    return image
}
