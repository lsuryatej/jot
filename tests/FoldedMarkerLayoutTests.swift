import AppKit
import Foundation

// Issue #14: "a visual glitch for every header I type after the first one."
//
// Folded markers (heading hashes, `**`, `==`, a collapsed link's scheme) used
// to be generated as `.null` glyphs. The typesetter skips null glyphs
// entirely, so a run of them at the very start of a line was never placed in
// that line: it got swept into the END of the previous line's fragment,
// newline and all. Two visible symptoms, both only on lines after the first
// (the first line has no previous fragment to leak into):
//
// - typing `# ` on a new line put the caret back at the end of the line
//   above, since the only glyphs on the new line lived up there;
// - once the heading had text, its line fragment no longer started the
//   paragraph, so its `paragraphSpacingBefore` was silently dropped and every
//   later heading sat flush against the line above.
//
// Real `ChecklistTextView` layout, headless, like UILayerTests.

private struct Fragment {
    let text: String
    let rect: NSRect
}

private func fragments(of view: ChecklistTextView) -> [Fragment] {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return [] }
    lm.ensureLayout(for: tc)
    let ns = view.string as NSString
    var result: [Fragment] = []
    var glyph = 0
    while glyph < lm.numberOfGlyphs {
        var glyphRange = NSRange()
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
        let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        result.append(Fragment(text: ns.substring(with: chars), rect: rect))
        glyph = NSMaxRange(glyphRange)
    }
    return result
}

/// The caret AppKit itself would draw for a collapsed selection at `index`,
/// in container coordinates.
private func insertionRect(at index: Int, in view: ChecklistTextView) -> NSRect? {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return nil }
    lm.ensureLayout(for: tc)
    let caret = NSRange(location: index, length: 0)
    var count = 0
    guard let rects = lm.rectArray(
        forCharacterRange: caret, withinSelectedCharacterRange: caret, in: tc, rectCount: &count
    ), count > 0 else { return nil }
    return rects[0]
}

func runFoldedMarkerLayoutTests() {

    suite("#14: a second heading's folded marker stays on its own line") {
        let view = makeTextView("# MOVE\n# J")
        let lines = fragments(of: view).map(\.text)
        equal(lines, ["# MOVE\n", "# J"], "each line fragment holds exactly its own line")
    }

    suite("#14: typing `# ` on a new line keeps the caret on that line") {
        let text = "# MOVE\n# "
        let view = makeTextView(text)
        let end = (text as NSString).length
        guard let first = fragments(of: view).first, let caret = insertionRect(at: end, in: view) else {
            check(false, "layout produced a first line and a caret")
            return
        }
        check(caret.minY >= first.rect.maxY, "the caret sits below the first line, not beside it")
        let padding = view.textContainer?.lineFragmentPadding ?? 0
        equal(caret.minX, padding, "and at the start of the new line, since the marker is folded")

        // Jot's own caret correction reads the fragment of the character
        // before the caret; it has to agree.
        view.setSelectedRange(NSRange(location: end, length: 0))
        let drawn = view.caretRect(from: caret)
        check(drawn.minY >= first.rect.maxY, "the caret Jot actually draws is on the new line too")
    }

    suite("#14: headings after the first keep their spacing above") {
        let view = makeTextView("# MOVE\n## JOKE\nbody")
        let frags = fragments(of: view)
        guard frags.count == 3 else {
            check(false, "three line fragments, got \(frags.map(\.text))")
            return
        }
        // Level 2 asks for 12pt before it; a fragment that no longer starts
        // its paragraph gets none. The spacing lives inside the fragment,
        // above the glyphs, so measure the glyphs' own top.
        guard let lm = view.layoutManager, let storage = view.textStorage,
              let font = storage.attribute(.font, at: 10, effectiveRange: nil) as? NSFont else {
            check(false, "the heading has a font")
            return
        }
        let jGlyph = lm.glyphIndexForCharacter(at: 10) // "J" after "## "
        let baseline = lm.lineFragmentRect(forGlyphAt: jGlyph, effectiveRange: nil).minY
            + lm.location(forGlyphAt: jGlyph).y
        check(baseline - font.ascender >= frags[0].rect.maxY + 12,
              "the level-2 heading is pushed down by its paragraphSpacingBefore")
        equal(frags[1].text, "## JOKE\n", "the heading's marker is part of its own fragment")
    }

    suite("#14: the marker still folds to zero width") {
        let view = makeTextView("# MOVE\n## JOKE")
        guard let lm = view.layoutManager, let tc = view.textContainer else {
            check(false, "layout machinery exists")
            return
        }
        lm.ensureLayout(for: tc)
        let padding = tc.lineFragmentPadding
        let jGlyph = lm.glyphIndexForCharacter(at: 10) // "J" after "## "
        equal(lm.location(forGlyphAt: jGlyph).x, padding, "JOKE starts at the left edge, hashes take no room")
        let mGlyph = lm.glyphIndexForCharacter(at: 2) // "M" after "# "
        equal(lm.location(forGlyphAt: mGlyph).x, padding, "so does the first heading")
    }

    suite("#14: other folded markers at a line start stay on their line too") {
        let bold = makeTextView("abc\n**bold** x")
        equal(fragments(of: bold).map(\.text), ["abc\n", "**bold** x"], "leading ** stays with its line")

        let highlight = makeTextView("abc\n==hi== x")
        equal(fragments(of: highlight).map(\.text), ["abc\n", "==hi== x"], "leading == stays with its line")
    }
}
