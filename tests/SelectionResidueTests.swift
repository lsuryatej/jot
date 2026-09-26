import AppKit
import Foundation

// A thin selection-coloured line left above (or below) text after the
// selection is cleared: the residue reported after Cmd+B / Cmd+I, after
// multi-line selections, and sometimes after a single-line one.
//
// What a probe in a real window measured, at a 1.3 line-height multiple, 13pt,
// 38pt top inset, on a 2x screen, selecting a word on the second line:
//
//   rectArray (what the layout manager measures)  y 58.8  height 20.8
//   rect handed to fillBackgroundRectArray        y 58.0  height 22.0
//   rect NSTextView invalidates on deselect       y 58.8  height 20.8
//   rect actually redrawn (pixel-aligned outward) y 58.5  height 21.5
//
// AppKit's own background pass rounds every selection rect out to whole
// points (NSIntegralRect) before filling it, while NSTextView invalidates the
// exact, fractional fragment when the selection goes away. Rows 58.0 to 58.5
// were painted and are never repainted: one device pixel of selection colour
// that stays behind. A line-height multiple makes fragment edges fractional,
// which is why it depends on the line and the spacing setting.
//
// The invariant tested here: whatever this layout manager fills for a
// selection stays inside the region AppKit redraws when that selection is
// cleared, and still fills its fragment (issue #9 must not come back).

@MainActor
private struct ResidueFixture {
    let view: ChecklistTextView
    let manager: TextHeightBackgroundLayoutManager
    let container: NSTextContainer

    init?(text: String, multiple: Double, size: CGFloat = 13) {
        let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 400))
        view.isRichText = false
        view.installBackgroundLayoutManager()
        view.textContainerInset = NSSize(width: 20, height: 38)
        view.baseFont = .systemFont(ofSize: size)
        view.lineHeightMultiple = multiple
        view.textStorage?.delegate = view
        view.string = text
        view.applyChecklistStyling()
        guard let manager = view.layoutManager as? TextHeightBackgroundLayoutManager,
              let container = view.textContainer else { return nil }
        manager.ensureLayout(for: container)
        self.view = view
        self.manager = manager
        self.container = container
    }

    var origin: NSPoint { view.textContainerOrigin }

    /// The rects AppKit's background pass hands to `fillBackgroundRectArray`
    /// for a selection: the layout manager's own rect array, rounded out to
    /// whole points, exactly as the probe observed.
    func incoming(_ range: NSRange) -> [NSRect] {
        var count = 0
        guard let pointer = manager.rectArray(
            forCharacterRange: range, withinSelectedCharacterRange: range,
            in: container, rectCount: &count
        ) else { return [] }
        return (0..<count).map { NSIntegralRect(pointer[$0].offsetBy(dx: origin.x, dy: origin.y)) }
    }

    /// The line fragments NSTextView invalidates when that selection goes away,
    /// in view coordinates, unrounded.
    func fragments(_ range: NSRange) -> [NSRect] {
        var out: [NSRect] = []
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            out.append(rect.offsetBy(dx: self.origin.x, dy: self.origin.y))
        }
        return out
    }
}

/// What the window server actually repaints for an invalidated rect: the rect
/// grown out to whole device pixels.
private func redrawn(_ rect: NSRect, scale: CGFloat) -> NSRect {
    let minY = floor(rect.minY * scale) / scale
    let maxY = ceil(rect.maxY * scale) / scale
    let minX = floor(rect.minX * scale) / scale
    let maxX = ceil(rect.maxX * scale) / scale
    return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

private func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
    let e: CGFloat = 0.0001
    return inner.minX >= outer.minX - e && inner.maxX <= outer.maxX + e
        && inner.minY >= outer.minY - e && inner.maxY <= outer.maxY + e
}

func runSelectionResidueTests() {
    MainActor.assumeIsolated {
        let text = "First line of the note here\nSecond line with more words in it\nThird line\nlast plain line"
        let selection = NSColor.selectedTextBackgroundColor

        for multiple in [1.0, 1.3, 1.6] {
            for scale in [CGFloat(1), CGFloat(2)] {
                for (label, range) in [("a word on line two", NSRange(location: 35, length: 10)),
                                       ("lines two to three", NSRange(location: 35, length: 38)),
                                       ("lines one to three", NSRange(location: 6, length: 60))] {
                    suite("selection residue: \(label), spacing \(multiple), \(Int(scale))x") {
                        guard let fixture = ResidueFixture(text: text, multiple: multiple) else {
                            check(false, "fixture came up")
                            return
                        }
                        let incoming = fixture.incoming(range)
                        let fragments = fixture.fragments(range)
                        let painted = fixture.manager.paintedBackgroundRects(
                            for: incoming, charRange: range, color: selection, scale: scale
                        )
                        guard painted.count == incoming.count, painted.count == fragments.count, !painted.isEmpty else {
                            check(false, "one painted rect per fragment (\(painted.count)/\(incoming.count)/\(fragments.count))")
                            return
                        }
                        let invalidated = fragments.reduce(NSRect.null) { $0.union($1) }
                        let region = redrawn(invalidated, scale: scale)
                        for (index, rect) in painted.enumerated() {
                            check(contains(region, rect),
                                  "line \(index): painted \(rect) stays inside what deselecting redraws \(region)")
                            let fragment = fragments[index]
                            check(abs(rect.minY - fragment.minY) <= 0.5 / scale + 0.0001
                                  && abs(rect.maxY - fragment.maxY) <= 0.5 / scale + 0.0001,
                                  "line \(index): and still fills its whole fragment \(fragment) (issue #9)")
                            equal(rect.minX, incoming[index].minX, "line \(index): x is AppKit's")
                            equal(rect.width, incoming[index].width, "line \(index): so is the width")
                        }
                        for index in painted.indices.dropLast() {
                            equal(painted[index].maxY, painted[index + 1].minY,
                                  "lines \(index) and \(index + 1) abut: no overlap to double up, no gap")
                        }
                    }
                }
            }
        }

        // The regression the three-line cases above could never see. AppKit
        // describes a selection with at most three rects, and every whole line
        // between the first and the last shares ONE block rect. Three lines
        // happen to give one rect per line; four or more, or Cmd+A from the
        // top (a single block), do not. Snapping each rect onto the one
        // fragment it overlapped most collapsed the block onto its tallest
        // line, leaving every other middle line unselected on screen.
        let note = """
        # Groceries and errands
        Pick up the dry cleaning before six, and remember that the shop on Ferris Street closes early on Thursdays so plan around it.
        - [ ] oat milk
        - [x] sourdough
        Body line three.
        ## Subheading here
        1. first numbered
        2. second numbered
        Last line of the note.
        """
        let length = (note as NSString).length
        for multiple in [1.0, 1.3, 1.6] {
            for size in [CGFloat(13), CGFloat(16)] {
                for scale in [CGFloat(1), CGFloat(2)] {
                    for (label, range) in [("Cmd+A", NSRange(location: 0, length: length)),
                                           ("mid-line to mid-line", NSRange(location: 10, length: length - 25)),
                                           ("line start to mid-line", NSRange(location: 24, length: length - 40))] {
                        suite("multi-line selection: \(label), spacing \(multiple), \(Int(size))pt, \(Int(scale))x") {
                            guard let fixture = ResidueFixture(text: note, multiple: multiple, size: size) else {
                                check(false, "fixture came up")
                                return
                            }
                            let incoming = fixture.incoming(range)
                            let fragments = fixture.fragments(range)
                            let painted = fixture.manager.paintedBackgroundRects(
                                for: incoming, charRange: range, color: selection, scale: scale
                            ).sorted { $0.minY < $1.minY }
                            check(fragments.count >= 9, "the note lays out as many lines (\(fragments.count))")
                            check(incoming.count < fragments.count,
                                  "AppKit hands over a block rect, not one rect per line (\(incoming.count) for \(fragments.count))")
                            equal(painted.count, incoming.count, "nothing is added or dropped")

                            let half = 0.5 / scale + 0.0001
                            var uncovered: [Int] = []
                            for (index, fragment) in fragments.enumerated() {
                                let covered = painted.contains {
                                    $0.minY <= fragment.minY + half && $0.maxY >= fragment.maxY - half
                                }
                                if !covered { uncovered.append(index) }
                            }
                            check(uncovered.isEmpty, "every selected line is filled top to bottom (unfilled: \(uncovered))")

                            let region = redrawn(fragments.reduce(NSRect.null) { $0.union($1) }, scale: scale)
                            for rect in painted {
                                check(contains(region, rect), "painted \(rect) stays inside what deselecting redraws \(region)")
                            }
                            for index in painted.indices.dropLast() {
                                equal(painted[index].maxY, painted[index + 1].minY,
                                      "rects \(index) and \(index + 1) meet on one edge: no overlap, no gap")
                            }
                            if let first = painted.first, let last = painted.last,
                               let top = fragments.first, let bottom = fragments.last {
                                check(abs(first.minY - top.minY) <= half, "the fill starts at the first line's top")
                                check(abs(last.maxY - bottom.maxY) <= half, "and ends at the last line's bottom")
                            }
                        }
                    }
                }
            }
        }

        suite("selection residue: a highlight wash is still corrected, not aligned as a selection") {
            guard let fixture = ResidueFixture(text: "a ==highlight== word\nnext", multiple: 1.6) else {
                check(false, "fixture came up")
                return
            }
            let storage = fixture.view.textStorage!
            let word = (storage.string as NSString).range(of: "highlight")
            guard let color = storage.attribute(.backgroundColor, at: word.location, effectiveRange: nil) as? NSColor else {
                check(false, "the styling pass washed the word")
                return
            }
            let incoming = fixture.incoming(word)
            let painted = fixture.manager.paintedBackgroundRects(for: incoming, charRange: word, color: color, scale: 2)
            let corrected = fixture.manager.correctedBackgroundRects(for: incoming, charRange: word, color: color)
            check(corrected != nil && painted == corrected!, "a wash paints exactly its baseline correction")
        }
    }
}
