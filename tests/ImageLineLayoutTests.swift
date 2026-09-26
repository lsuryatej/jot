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
