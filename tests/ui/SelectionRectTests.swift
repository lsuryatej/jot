import AppKit
import Foundation

// Issue #9: multi-line selection and highlighting rendered visibly wrong in
// every display mode except Screen Edge.
//
// Screen Edge is the one mode that builds its `ChecklistTextView` without
// calling `installBackgroundLayoutManager()` (see `NoteCardEditor.makeNSView`
// in EdgeStackView.swift), so it runs the stock `NSLayoutManager`. That is the
// whole difference between the mode that looked right and every mode that did
// not, and it points at exactly one method.
//
// `fillBackgroundRectArray(_:count:forCharacterRange:color:)` is not only the
// hook for `.backgroundColor` attribute runs. AppKit fills the *selection*
// through it too, as one call carrying one rect per line fragment. Confirmed
// here rather than assumed: the selection suites below read back the rects
// this layout manager decides to paint over real, laid-out text, and a
// selection must reach `super` untouched. A rect rewritten onto the baseline
// at text height is correct for a wash behind a word and wrong for a
// selection, which fills its line fragment.
//
// The headless suite structurally cannot see this. It has no window server, so
// there are no line fragments, no baselines, and no selection to hand over.

// MARK: - Fixture

/// A laid-out `ChecklistTextView` in a real window, wired exactly as the main
/// editor wires it: the custom layout manager installed while the view is
/// still empty, and a line-height multiple large enough that a fragment is
/// visibly taller than its own text.
@MainActor
private struct EditorFixture {
    let window: NSWindow
    let view: ChecklistTextView
    let manager: TextHeightBackgroundLayoutManager
    let container: NSTextContainer
    let storage: NSTextStorage

    init?(text: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 140, y: 140, width: 440, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 360))
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 360))
        view.isRichText = false
        // Installed before any text exists, which is the only supported order:
        // see the doc comment on `installBackgroundLayoutManager`.
        view.installBackgroundLayoutManager()
        // The same inset the real editor uses with the header hidden. It is
        // load-bearing for this geometry: rects arrive with it applied while
        // fragments are measured without it.
        view.textContainerInset = NSSize(width: 18, height: 38)
        view.baseFont = .systemFont(ofSize: 13)
        view.lineHeightMultiple = 1.6

        scroll.documentView = view
        window.contentView?.addSubview(scroll)
        _ = bringUpAndWaitUntilKey(window, timeout: 2)

        view.string = text
        view.applyChecklistStyling()

        guard let manager = view.layoutManager as? TextHeightBackgroundLayoutManager,
              let container = view.textContainer,
              let storage = view.textStorage else { return nil }
        manager.ensureLayout(for: container)

        self.window = window
        self.view = view
        self.manager = manager
        self.container = container
        self.storage = storage
    }

    /// The rects AppKit itself would hand to `fillBackgroundRectArray` for
    /// `range`, taken from the same public layout-manager call AppKit uses.
    /// One rect per line fragment, in the text view's coordinates.
    func incomingRects(for range: NSRange, selected: Bool) -> [NSRect] {
        var count = 0
        let selectedRange = selected ? range : NSRange(location: NSNotFound, length: 0)
        guard let pointer = manager.rectArray(
            forCharacterRange: range,
            withinSelectedCharacterRange: selectedRange,
            in: container,
            rectCount: &count
        ) else { return [] }
        let origin = view.textContainerOrigin
        return (0..<count).map { pointer[$0].offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// What the layout manager will actually paint for that call: its own
    /// correction when it claims the call, and otherwise the incoming rects
    /// with their vertical edges snapped onto the window's pixels (the
    /// deselect-residue fix), still handed to `super`.
    func paintedRects(for range: NSRange, color: NSColor, selected: Bool) -> [NSRect] {
        let incoming = incomingRects(for: range, selected: selected)
        return manager.paintedBackgroundRects(
            for: incoming, charRange: range, color: color, scale: window.backingScaleFactor
        )
    }

    /// Half a device pixel: the most a selection edge may move when it is
    /// snapped onto the pixel grid.
    var halfPixel: CGFloat { 0.5 / max(1, window.backingScaleFactor) + 0.0001 }

    func font(at index: Int) -> NSFont? {
        guard index < storage.length else { return nil }
        return storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    func close() {
        window.orderOut(nil)
    }
}

/// The colour AppKit fills a selection with. Deliberately read off the text
/// view rather than hardcoded, because it is not one fixed colour: an
/// unfocused view selects in `unemphasizedSelectedContentBackgroundColor`
/// instead, which is the first reason a "does this colour look like the
/// selection colour" test would be testing the wrong thing.
@MainActor
private func selectionColor(_ view: NSTextView) -> NSColor {
    (view.selectedTextAttributes[.backgroundColor] as? NSColor) ?? .selectedTextBackgroundColor
}

private func approximatelyEqual(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.51) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - Suites

func runSelectionRectTests() {
    MainActor.assumeIsolated {
        let heading = "# Big heading line"
        let body = "ordinary body text here"
        let marked = "a ==highlight== and `code` inline"

        // MARK: selection spanning several body lines

        suite("a selection across several lines fills every line fragment") {
            guard let fixture = EditorFixture(text: "\(body)\n\(body)\n\(body)") else {
                check(false, "fixture came up")
                return
            }
            defer { fixture.close() }

            let range = NSRange(location: 4, length: (body as NSString).length * 2 + 8)
            let incoming = fixture.incomingRects(for: range, selected: true)
            let painted = fixture.paintedRects(for: range, color: selectionColor(fixture.view), selected: true)

            check(incoming.count >= 3, "the selection arrives as one rect per line fragment (got \(incoming.count))")
            equal(painted.count, incoming.count, "and nothing is added or dropped")
            for (index, pair) in zip(painted, incoming).enumerated() {
                check(pair.0.minX == pair.1.minX && pair.0.width == pair.1.width,
                      "line \(index): the selection keeps AppKit's horizontal extent")
                check(abs(pair.0.minY - pair.1.minY) <= fixture.halfPixel
                      && abs(pair.0.maxY - pair.1.maxY) <= fixture.halfPixel,
                      "line \(index): and fills the fragment AppKit measured, to the nearest pixel")
            }
            for index in painted.indices.dropLast() {
                check(painted[index].maxY == painted[index + 1].minY,
                      "lines \(index) and \(index + 1) share one edge: no overlap, no gap")
            }
        }

        suite("a cleared selection leaves nothing outside what AppKit redraws") {
            // The deselect residue: AppKit hands this layout manager selection
            // rects rounded out to whole points, but on deselect it redraws
            // only the exact fragments grown to the next device pixel. At this
            // fixture's 1.6 spacing the second line starts on a fractional
            // edge, so the stock rounding painted a pixel row above it that was
            // never repainted.
            guard let fixture = EditorFixture(text: "\(body)\n\(body)\n\(body)") else {
                check(false, "fixture came up")
                return
            }
            defer { fixture.close() }

            let scale = max(1, fixture.window.backingScaleFactor)
            let range = NSRange(location: (body as NSString).length + 3, length: (body as NSString).length)
            let incoming = fixture.incomingRects(for: range, selected: true).map(NSIntegralRect)
            let painted = fixture.manager.paintedBackgroundRects(
                for: incoming, charRange: range, color: selectionColor(fixture.view), scale: scale
            )
            var invalidated = NSRect.null
            let glyphs = fixture.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            fixture.manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                invalidated = invalidated.union(rect.offsetBy(dx: fixture.view.textContainerOrigin.x,
                                                              dy: fixture.view.textContainerOrigin.y))
            }
            let redrawTop = floor(invalidated.minY * scale) / scale
            let redrawBottom = ceil(invalidated.maxY * scale) / scale
            check(!painted.isEmpty, "the selection paints something")
            for rect in painted {
                check(rect.minY >= redrawTop - 0.0001, "painted top \(rect.minY) is inside the redraw (\(redrawTop))")
                check(rect.maxY <= redrawBottom + 0.0001, "painted bottom \(rect.maxY) is inside the redraw (\(redrawBottom))")
            }
        }

        suite("a selection is handed back to super rather than corrected") {
            guard let fixture = EditorFixture(text: "\(body)\n\(body)") else {
                check(false, "fixture came up")
                return
            }
            defer { fixture.close() }

            let range = NSRange(location: 2, length: (body as NSString).length + 6)
            let incoming = fixture.incomingRects(for: range, selected: true)
            let decision = fixture.manager.correctedBackgroundRects(
                for: incoming, charRange: range, color: selectionColor(fixture.view)
            )
            check(decision == nil, "nil means the stock layout manager draws it, exactly as Screen Edge does")
        }

        // MARK: selection spanning fonts

        suite("a selection from a heading into body text keeps each line's own height") {
            // Defect two, at its most visible. The whole call used to be sized
            // off the font at the first selected character, so selecting out of
            // a heading painted every following line at heading height.
            guard let fixture = EditorFixture(text: "\(heading)\n\(body)\n\(body)") else {
                check(false, "fixture came up")
                return
            }
            defer { fixture.close() }

            let headingFont = fixture.font(at: 3)
            let bodyFont = fixture.font(at: (heading as NSString).length + 3)
            check(headingFont?.pointSize ?? 0 > bodyFont?.pointSize ?? 0,
                  "the fixture really does put a larger font on the heading line")

            let range = NSRange(location: 3, length: (heading as NSString).length + (body as NSString).length)
            let incoming = fixture.incomingRects(for: range, selected: true)
            let painted = fixture.paintedRects(for: range, color: selectionColor(fixture.view), selected: true)

            guard incoming.count >= 2, painted.count == incoming.count else {
                check(false, "the selection spans at least two fragments (got \(incoming.count))")
                return
            }
            for (index, pair) in zip(painted, incoming).enumerated() {
                check(abs(pair.0.height - pair.1.height) <= fixture.halfPixel * 2,
                      "line \(index): filled at its own fragment's height")
                check(abs(pair.0.origin.y - pair.1.origin.y) <= fixture.halfPixel,
                      "line \(index): and at its own fragment's top edge")
            }
            check(painted[0].height != painted[1].height,
                  "the body line is not painted at the heading's height")
        }

        // MARK: attribute washes, which must still be corrected

        suite("a real highlight is still pulled onto its baseline at text height") {
            guard let fixture = EditorFixture(text: marked) else {
                check(false, "fixture came up")
                return
            }
            defer { fixture.close() }

            let highlight = (marked as NSString).range(of: "highlight")
            guard let color = fixture.storage.attribute(
                .backgroundColor, at: highlight.location, effectiveRange: nil
            ) as? NSColor else {
                check(false, "the styling pass put a background colour on the highlighted word")
                return
            }
            guard let font = fixture.font(at: highlight.location) else {
                check(false, "and a font")
                return
            }

            let incoming = fixture.incomingRects(for: highlight, selected: false)
            let decision = fixture.manager.correctedBackgroundRects(
                for: incoming, charRange: highlight, color: color
            )
            guard let decision, let painted = decision.first, let raw = incoming.first else {
                check(false, "an attribute wash is this layout manager's own business")
                return
            }
            equal(painted.height, ceil(font.ascender - font.descender), "sized to the text, not the line fragment")
            check(painted.height < raw.height, "a 1.6 line-height fragment is taller than its own text")
            check(painted.origin.y > raw.origin.y, "and the wash sits below the fragment's top edge")
            check(painted.maxY <= raw.maxY + 0.01, "without spilling past the bottom of its own line")
        }

        suite("an inline code span is still corrected, on its own metrics") {
            guard let fixture = EditorFixture(text: marked) else {
                check(false, "fixture came up")
                return
            }
            defer { fixture.close() }

            let code = (marked as NSString).range(of: "code")
            guard let color = fixture.storage.attribute(
                .backgroundColor, at: code.location, effectiveRange: nil
            ) as? NSColor, let font = fixture.font(at: code.location) else {
                check(false, "the styling pass washed and re-faced the code span")
                return
            }
            check(font.isFixedPitch, "inline code really is monospaced here")

            let incoming = fixture.incomingRects(for: code, selected: false)
            let decision = fixture.manager.correctedBackgroundRects(for: incoming, charRange: code, color: color)
            guard let painted = decision?.first, let raw = incoming.first else {
                check(false, "the code wash is corrected, not handed to super")
                return
            }
            equal(painted.height, ceil(font.ascender - font.descender), "sized off the monospaced face")
            check(painted.height < raw.height, "shrunk out of the taller fragment")
        }

        suite("a wash spanning two lines is sized per line, not per call") {
            // Defect two again, on the path the override was written for. One
            // font was read at the first character and applied to every rect in
            // the call, so a wash that reaches a second line with different
            // metrics was painted there at the first line's size.
            guard let fixture = EditorFixture(text: "\(heading)\n\(body)") else {
                check(false, "fixture came up")
                return
            }
            defer { fixture.close() }

            // A background run laid across both lines by hand. The markdown
            // styling pass has no syntax that spans a heading boundary, and
            // this is about the geometry, not about how the attribute got there.
            let wash = NSColor.systemYellow.withAlphaComponent(0.4)
            let span = NSRange(location: 3, length: (heading as NSString).length + 8)
            fixture.storage.addAttribute(.backgroundColor, value: wash, range: span)
            fixture.manager.ensureLayout(for: fixture.container)

            guard let headingFont = fixture.font(at: span.location),
                  let bodyFont = fixture.font(at: (heading as NSString).length + 2) else {
                check(false, "both lines carry a font")
                return
            }

            let incoming = fixture.incomingRects(for: span, selected: false)
            let decision = fixture.manager.correctedBackgroundRects(for: incoming, charRange: span, color: wash)
            guard let painted = decision, painted.count >= 2 else {
                check(false, "the wash covers two fragments (got \(incoming.count))")
                return
            }
            equal(painted[0].height, ceil(headingFont.ascender - headingFont.descender),
                  "the heading line is sized off the heading font")
            equal(painted[1].height, ceil(bodyFont.ascender - bodyFont.descender),
                  "the body line is sized off the body font, not the heading's")
            check(painted[1].height < painted[0].height, "so the second line is the shorter of the two")
            check(approximatelyEqual(painted[1].maxY, incoming[1].maxY, 12),
                  "and it lands on its own line rather than floating above it")
        }
    }
}
