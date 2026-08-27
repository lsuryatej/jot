import AppKit
import Foundation

// Diagnosing a live report: a pasted image's raw markdown text
// (`![320](Attachments/<uuid>.png)`) showing as visible text instead of
// staying hidden behind the drawn image. `applyChecklistStyling` is meant to
// paint that text `.clear` (src/PlainTextEditor.swift, "An image line is
// given the height of its image, and the markdown that produced it is
// painted out") whenever `Attachments.image(at:)` can actually load the
// referenced file — this checks that promise directly against a real image
// on disk, headlessly.

@discardableResult
private func writeScratchImage(width: Int = 200, height: Int = 100) -> (directory: URL, path: String) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jot-image-visibility-\(UUID().uuidString)")
    let attachmentsDir = directory.appendingPathComponent("Attachments", isDirectory: true)
    try! FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemPurple.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()

    let tiff = image.tiffRepresentation!
    let bitmap = NSBitmapImageRep(data: tiff)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let name = "\(UUID().uuidString).png"
    try! png.write(to: attachmentsDir.appendingPathComponent(name))

    setenv("JOT_NOTES_FILE", directory.appendingPathComponent("notes.json").path, 1)
    return (directory, "Attachments/\(name)")
}

func runImageMarkdownVisibilityTests() {
    suite("a pasted image's markdown text is painted invisible, matching insertImage's own shape") {
        let (_, path) = writeScratchImage()
        // The exact shape `Attachments.markdown(path:width:)` produces —
        // what `insertImage` actually writes into the note.
        let markdown = Attachments.markdown(path: path, width: 240)
        let text = "before\n\(markdown)\nafter"
        let view = makeTextView(text)

        let ns = text as NSString
        let markdownRange = ns.range(of: markdown)
        check(markdownRange.location != NSNotFound, "sanity: the markdown text is really in the note")

        let color = view.textStorage?.attribute(.foregroundColor, at: markdownRange.location, effectiveRange: nil) as? NSColor
        equal(color, NSColor.clear, "the reference text is painted clear, matching the styling pass's own claim")

        check(view.placedImages().count == 1, "and the image itself is found for drawing")
    }

    suite("a lone image line with no other content is still cleared") {
        let (_, path) = writeScratchImage()
        let markdown = Attachments.markdown(path: path, width: nil)
        let view = makeTextView(markdown)

        let color = view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        equal(color, NSColor.clear, "a width-less reference (nil alt text) is cleared the same way")
    }

    suite("insertImage into an already-open note (the real paste path) leaves the reference visible") {
        // `makeTextView` sets `.string` directly and calls
        // `applyChecklistStyling()` once at construction — that simulates a
        // freshly-loaded note, not a live paste into a note that's already
        // open and already styled. A real Cmd+V goes through `insertImage`,
        // which inserts at a *zero-length* range via `replace(...)` — a true
        // insertion, not a replacement of existing characters. AppKit gives
        // newly inserted text `typingAttributes`, not the neighboring run's
        // attributes the way replacing a non-empty range does — a different
        // rule from the one the resize test above exercises.
        let (_, path) = writeScratchImage()
        let image = Attachments.image(at: path)!
        let view = makeTextView("some existing note\nwith a second line")

        view.insertImage(image, at: (view.string as NSString).length)

        let references = Attachments.references(in: view.string)
        check(references.count == 1, "sanity: the reference actually landed in the text")
        guard let reference = references.first else { return }
        let color = view.textStorage?.attribute(.foregroundColor, at: reference.range.location, effectiveRange: nil) as? NSColor
        equal(color, NSColor.clear,
              "a live-pasted image's reference should be cleared the same as one present at load time")
    }

    suite("resizing an image (settingWidth + replace, beginResize's own shape) leaves the reference visible") {
        // beginResize's mouse-up handler, PlainTextEditor.swift: computes the
        // rewritten markdown via Attachments.settingWidth, then calls
        // `self.replace(range: placed.markdownRange, with: rewritten,
        // selecting: nil)` directly on the live text view — and nothing
        // else. Reproducing that exact shape here, not going through
        // PlainTextEditor's SwiftUI binding at all, since the live text view
        // mutation is the whole bug: `replace` fires `didChangeText`, which
        // round-trips through the SwiftUI Coordinator back into
        // `updateNSView`'s `if textView.string != text { loadNoteText(text) }`
        // — and since the text view's string already matches what SwiftUI
        // thinks it should be (this same edit produced both), that guard is
        // false and the restyle that would re-clear the reference never
        // runs. `toggleHighlight` and `toggleChecklist` call
        // `applyLinkFolding`/restyle themselves after their own direct
        // `replace()` calls for exactly this reason (see BACKLOG.md); this
        // is the one direct-mutation call site missing that.
        let (_, path) = writeScratchImage()
        let original = Attachments.markdown(path: path, width: 240)
        let view = makeTextView(original)

        let originalRange = NSRange(location: 0, length: (original as NSString).length)
        let colorBefore = view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        equal(colorBefore, NSColor.clear, "sanity: cleared right after the initial paste, as already covered above")

        guard let rewritten = Attachments.settingWidth(320, on: original, at: originalRange) else {
            check(false, "Attachments.settingWidth should succeed for a well-formed reference")
            return
        }
        view.replace(range: originalRange, with: rewritten, selecting: nil)

        let colorAfter = view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        equal(colorAfter, NSColor.clear,
              "still cleared after a resize — FAILS today: replace() alone doesn't trigger the restyle pass that clears it")
    }

    suite("the width annotation's own digits are cleared, not just the brackets/parens") {
        // The visible symptom reported was the *filename* showing, but the
        // width number sits right before it in the same reference — if
        // clearing were somehow only covering part of the range this would
        // catch it too.
        let (_, path) = writeScratchImage()
        let markdown = Attachments.markdown(path: path, width: 999)
        let text = markdown
        let view = makeTextView(text)
        let ns = text as NSString
        let digitLocation = ns.range(of: "999").location
        check(digitLocation != NSNotFound, "sanity: the width digits are present")
        let color = view.textStorage?.attribute(.foregroundColor, at: digitLocation, effectiveRange: nil) as? NSColor
        equal(color, NSColor.clear, "the width digits themselves are cleared too")
    }
}
