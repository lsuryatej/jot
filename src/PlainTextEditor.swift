import SwiftUI
import AppKit
import Carbon.HIToolbox


enum SwipeDirection {
    case left
    case right
}

/// The swipe-recognition state machine behind `SwipeScrollView`, extracted so
/// the rules are testable without synthesising scroll events against a real
/// scroll view (which needs a window server).
///
/// A gesture accumulates horizontal deltas until they cross the threshold,
/// fires exactly once, then goes quiet until the fingers lift or a new gesture
/// begins. Vertical-dominant deltas are not swipes at all.
struct SwipeAccumulator {
    static let threshold: CGFloat = 55

    enum Outcome: Equatable {
        /// Crossed the threshold this event: navigate, and consume the event.
        case fire(SwipeDirection)
        /// Still accumulating: consume the event either way — a horizontal
        /// gesture must never scroll the text view sideways.
        case absorb
        /// Vertical intent belongs to the text view's own scrolling.
        case passThrough
    }

    private var accumulatedX: CGFloat = 0
    private var didFire = false

    mutating func receive(deltaX: CGFloat, deltaY: CGFloat) -> Outcome {
        guard abs(deltaX) > abs(deltaY) else { return .passThrough }

        accumulatedX += deltaX
        if !didFire, abs(accumulatedX) >= Self.threshold {
            didFire = true
            // Natural scrolling: fingers moving right (positive dx) means
            // "go back", matching the direction pages move under your fingers.
            return .fire(accumulatedX > 0 ? .right : .left)
        }
        return .absorb
    }

    mutating func begin() {
        accumulatedX = 0
        didFire = false
    }

    /// Fingers lifted or cancelled: the next gesture starts from zero.
    mutating func end() {
        begin()
    }
}

/// Scroll view that turns a horizontal two-finger swipe into a note-navigation
/// event instead of a horizontal scroll.
///
/// SwiftUI's `DragGesture` cannot do this: trackpad swipes arrive as
/// scroll-wheel events, which `DragGesture` never receives, and the text view
/// swallows real drags for text selection.
final class SwipeScrollView: NSScrollView {
    var onSwipe: ((SwipeDirection) -> Void)?

    private var accumulator = SwipeAccumulator()

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            accumulator.begin()
        }

        switch accumulator.receive(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) {
        case .fire(let direction):
            onSwipe?(direction)
        case .absorb:
            break  // consumed: never scroll the text view sideways
        case .passThrough:
            super.scrollWheel(with: event)
            return
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            accumulator.end()
        }
    }
}

/// Draws `.backgroundColor` runs at the height of the text itself rather than
/// the height of the line fragment holding it.
///
/// Exactly the correction `caretRect` already makes, for exactly the same
/// reason. A line-height multiple adds its extra leading above the glyphs, and
/// AppKit fills the whole fragment, so a highlight ends up painted across the
/// gap above its own words and into the descenders of the line before it. The
/// effect had always been there on `==highlights==`; inline code made it
/// impossible to ignore, because pasted output is full of code spans.
final class TextHeightBackgroundLayoutManager: NSLayoutManager {
    /// Moves one incoming background rect onto the baseline of the line
    /// fragment it belongs to, at the height of its own font. Returns nil when
    /// this fragment is not the rect's fragment.
    ///
    /// Pure on purpose, exactly like `caretRect`: the two mistakes below are
    /// invisible from the drawing code and impossible to catch through an
    /// AppKit override, so the math lives somewhere a test can reach it
    /// without a layout manager, a text storage, or a window server.
    ///
    /// - Parameters:
    ///   - rect: the rect AppKit wants filled, in the text view's coordinates.
    ///   - lineFragment: the fragment, in the text container's coordinates.
    ///   - baselineOffset: the glyph baseline's y within that fragment.
    ///   - containerInset: the text view's `textContainerInset`.
    ///   - font: the font of the run being washed, not the line's first font.
    static func backgroundRect(
        for rect: NSRect,
        lineFragment: NSRect,
        baselineOffset: CGFloat,
        containerInset: NSSize,
        font: NSFont
    ) -> NSRect? {
        // Trap one: the rect arrives with the container inset already applied
        // while fragments are measured from the container's own origin. At
        // this app's 38pt top inset the two spaces never overlap at all, so an
        // intersection test against a raw fragment silently matches nothing
        // and every rect falls through uncorrected.
        let fragment = lineFragment.offsetBy(dx: containerInset.width, dy: containerInset.height)
        guard fragment.intersects(rect) else { return nil }

        // Trap two: a line-height multiple does not inflate this rect. It
        // pushes the glyphs down inside a taller fragment and leaves the rect
        // behind at the top, so the box is already the right height and simply
        // in the wrong place. Guarding on height and bailing out therefore
        // corrects nothing. Always reposition.
        var corrected = rect
        corrected.origin.y = fragment.minY + baselineOffset - ceil(font.ascender)
        corrected.size.height = ceil(font.ascender - font.descender)
        return corrected
    }

    /// Whether one background call is a `.backgroundColor` attribute run —
    /// this class's entire reason to exist — rather than the text selection,
    /// which AppKit fills through the very same method.
    ///
    /// Issue #9. Selection rectangles arrive here as one call carrying one rect
    /// per line fragment, and a selection is supposed to fill its fragment:
    /// pulling it onto the baseline at text height collapses every selected
    /// line and repositions it, which is what the report described. Screen Edge
    /// looked right only because it never installs this layout manager.
    ///
    /// The test is "do the characters carry this colour", not "is this colour
    /// the selection colour", and the asymmetry is deliberate. A colour
    /// comparison fails from both ends: an unfocused view selects in
    /// `unemphasizedSelectedContentBackgroundColor` rather than
    /// `selectedTextBackgroundColor`, so the comparison misses real selections,
    /// and the system selection colour moves with the accent colour, so a
    /// highlight can coincide with it and lose its correction. Asking the text
    /// storage answers the question that actually matters and is immune to
    /// both: a selection's characters carry no `.backgroundColor` of their own.
    ///
    /// The whole range must carry it, not just the first character. A selection
    /// dragged out of a highlighted word starts inside that run, and reading
    /// only `charRange.location` would call it a wash and collapse it.
    static func isAttributeWash(charRange: NSRange, color: NSColor, textStorage: NSTextStorage) -> Bool {
        guard charRange.length > 0,
              charRange.location >= 0,
              charRange.location + charRange.length <= textStorage.length else { return false }

        var washed = true
        textStorage.enumerateAttribute(.backgroundColor, in: charRange) { value, _, stop in
            guard let runColor = value as? NSColor, runColor == color else {
                washed = false
                stop.pointee = true
                return
            }
        }
        return washed
    }

    /// The rects this manager will actually paint for one background call, or
    /// nil when the call is none of its business and belongs to `super`
    /// untouched.
    ///
    /// Split out of the override so a test can drive the real layout manager,
    /// over real laid-out text, and read back the decision. Everything the
    /// override does after this is `setFill` and a bezier path, which no test
    /// can see and no test needs to.
    func correctedBackgroundRects(for rects: [NSRect], charRange: NSRange, color: NSColor) -> [NSRect]? {
        guard let textStorage, textStorage.length > 0, !rects.isEmpty,
              Self.isAttributeWash(charRange: charRange, color: color, textStorage: textStorage) else { return nil }

        let glyphRange = self.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let inset = firstTextView?.textContainerInset ?? .zero

        var output: [NSRect] = []
        for rect in rects {
            var corrected = rect
            var matched = false

            enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphRange, _ in
                // One rect per line fragment, so the first fragment this rect
                // overlaps is the one it belongs to.
                guard !matched else { return }
                // The font of the run on *this* line, not one font read once
                // for the whole call. A wash reaching a second line — a wrapped
                // span, or a run crossing from a heading into body text — used
                // to be sized everywhere off the first selected character, so
                // the later lines were painted at the first line's metrics.
                // Inline code makes the same mistake within a single line,
                // which is why the font was already being read per run rather
                // than per fragment.
                guard let font = self.font(forGlyphRange: fragmentGlyphRange, clampedTo: charRange) else { return }
                guard let fitted = Self.backgroundRect(
                    for: rect,
                    lineFragment: fragmentRect,
                    baselineOffset: self.location(forGlyphAt: fragmentGlyphRange.location).y,
                    containerInset: inset,
                    font: font
                ) else { return }

                matched = true
                corrected = fitted
            }

            output.append(corrected)
        }
        return output
    }

    /// Snaps one incoming selection rect onto the line fragments it covers,
    /// with both vertical edges on the nearest device pixel. Returns nil when
    /// the rect covers none of `lineFragments`.
    ///
    /// The residue this exists for: AppKit's background pass rounds every
    /// selection rect out to whole points (`NSIntegralRect`) before handing it
    /// to `fillBackgroundRectArray`, but when the selection goes away
    /// `NSTextView` invalidates the exact line fragments, and the window server
    /// only grows those out to the next device pixel. With a line-height
    /// multiple the fragment edges are fractional (58.8pt, say), so the fill
    /// started at 58.0 and the redraw at 58.5: one pixel row of selection
    /// colour painted above the text and never painted over. The same happens
    /// at the bottom edge, and wherever a Cmd+B / Cmd+I edit leaves the
    /// selection on a line whose edges are fractional.
    ///
    /// One rect is not one line. AppKit describes a selection with at most
    /// three rects: the partial first line, one block for every whole line in
    /// between, and the partial last line (Cmd+A from the top of a note is a
    /// single block). The block must keep its full height, so the rect's top
    /// takes the top of the first fragment it covers and its bottom the bottom
    /// of the last. Snapping each rect onto just one fragment, the one it
    /// overlapped most, collapsed every middle block onto its tallest line,
    /// which is how the #9 regression came back.
    ///
    /// "Covers" means at least half of the fragment: the rounding out adds
    /// under a point, so a neighbouring fragment it pokes into never
    /// qualifies, while a fragment the rect really spans always does.
    /// Snapping each edge to the nearest pixel keeps the fill inside that
    /// redraw by construction, and the three rects meet on one shared edge
    /// instead of overlapping by a point (which doubled up a translucent
    /// selection colour). x and width stay AppKit's: the invalidation spans
    /// the whole fragment width, so horizontal rounding can never escape it.
    ///
    /// Pure, like `backgroundRect`, so the geometry is testable headless.
    ///
    /// - Parameters:
    ///   - rect: the rect AppKit wants filled, in the text view's coordinates.
    ///   - lineFragments: the selection's fragments, in the text container's
    ///     coordinates, in layout order.
    ///   - containerInset: the text view's `textContainerInset`.
    ///   - scale: device pixels per point of the window being drawn into.
    static func selectionRect(
        for rect: NSRect,
        lineFragments: [NSRect],
        containerInset: NSSize,
        scale: CGFloat
    ) -> NSRect? {
        var top: CGFloat?
        var bottom: CGFloat?
        for lineFragment in lineFragments {
            let fragment = lineFragment.offsetBy(dx: containerInset.width, dy: containerInset.height)
            let overlap = min(rect.maxY, fragment.maxY) - max(rect.minY, fragment.minY)
            guard fragment.height > 0, overlap >= fragment.height / 2 else { continue }
            top = min(top ?? fragment.minY, fragment.minY)
            bottom = max(bottom ?? fragment.maxY, fragment.maxY)
        }
        guard let top, let bottom else { return nil }
        let pixels = max(1, scale)
        let minY = (top * pixels).rounded() / pixels
        let maxY = (bottom * pixels).rounded() / pixels
        return NSRect(x: rect.minX, y: minY, width: rect.width, height: maxY - minY)
    }

    /// Every rect this manager fills for one background call: a wash's
    /// baseline correction, or, for anything else (the selection, find
    /// matches), AppKit's rects snapped onto their fragments by
    /// `selectionRect`. A rect that matches no fragment, which only an
    /// unusual caller could produce, is left exactly as it came.
    func paintedBackgroundRects(for rects: [NSRect], charRange: NSRange, color: NSColor, scale: CGFloat) -> [NSRect] {
        correctedBackgroundRects(for: rects, charRange: charRange, color: color)
            ?? alignedSelectionRects(for: rects, charRange: charRange, scale: scale)
    }

    /// The non-wash half of `paintedBackgroundRects`, split out so the
    /// override, which has already asked whether the call is a wash, does not
    /// walk the attribute runs a second time.
    private func alignedSelectionRects(for rects: [NSRect], charRange: NSRange, scale: CGFloat) -> [NSRect] {
        guard let textStorage, textStorage.length > 0, charRange.length > 0 else { return rects }

        let inset = firstTextView?.textContainerInset ?? .zero
        // Every fragment the rects reach, not only the ones `charRange` names:
        // a partial redraw can hand over a clipped range with rects that still
        // span whole lines, and a block must not lose the lines outside it.
        var glyphRange = self.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        if let container = textContainers.first {
            let reach = rects.reduce(NSRect.null) { $0.union($1) }
                .offsetBy(dx: -inset.width, dy: -inset.height)
            glyphRange = NSUnionRange(glyphRange, self.glyphRange(forBoundingRectWithoutAdditionalLayout: reach, in: container))
        }
        var fragments: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, _, _ in
            fragments.append(fragmentRect)
        }
        // The empty line after a trailing newline has no glyphs, so it is not
        // enumerated, yet Cmd+A selects it.
        if extraLineFragmentTextContainer != nil, extraLineFragmentRect.height > 0 {
            fragments.append(extraLineFragmentRect)
        }
        return rects.map { rect in
            Self.selectionRect(for: rect, lineFragments: fragments, containerInset: inset, scale: scale) ?? rect
        }
    }

    /// The font of the washed run where it enters one line fragment.
    ///
    /// A fragment can start before the washed range does — the run may begin
    /// mid-line — so the lookup is clamped into `charRange`, which is the span
    /// actually being painted.
    private func font(forGlyphRange fragmentGlyphRange: NSRange, clampedTo charRange: NSRange) -> NSFont? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let fragmentStart = characterIndexForGlyph(at: fragmentGlyphRange.location)
        let lower = max(charRange.location, fragmentStart)
        let upper = max(charRange.location, charRange.location + charRange.length - 1)
        let index = min(max(0, min(lower, upper)), textStorage.length - 1)
        return textStorage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        var incoming: [NSRect] = []
        incoming.reserveCapacity(rectCount)
        for index in 0..<rectCount { incoming.append(rectArray[index]) }

        guard let corrected = correctedBackgroundRects(for: incoming, charRange: charRange, color: color) else {
            // The selection (and find matches) still fill through `super`, at
            // full fragment height, exactly as issue #9 needs; only their
            // vertical edges move, onto the pixels AppKit will redraw when
            // the selection is cleared. See `selectionRect`.
            let scale = firstTextView?.window?.backingScaleFactor ?? 1
            let aligned = alignedSelectionRects(for: incoming, charRange: charRange, scale: scale)
            aligned.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                super.fillBackgroundRectArray(base, count: buffer.count, forCharacterRange: charRange, color: color)
            }
            return
        }

        color.setFill()
        for rect in corrected {
            // A hair of padding so the wash reads as a surface behind the text
            // rather than a box clamped to its bounding rect.
            let padded = rect.insetBy(dx: -1.5, dy: -1)
            NSBezierPath(roundedRect: padded, xRadius: 3, yRadius: 3).fill()
        }
    }
}

/// Text view with checklist behaviour.
///
/// The text stays plain markdown on disk. Everything here is presentation and
/// interaction: the file never holds anything you could not read in `cat`.
final class ChecklistTextView: NSTextView, NSTextStorageDelegate, NSLayoutManagerDelegate {
    /// Guards the styling pass against re-entering itself through the text
    /// storage delegate.
    private var isStyling = false

    // MARK: - Pure geometry (extracted for the headless tests)

    /// The smallest an image may be dragged down to: below this the resize
    /// handles would be smaller than the cursor itself.
    static let minimumImageWidth: CGFloat = 48

    /// The width an in-progress image resize should preview, given where the
    /// drag started and where it is now. One-sided on purpose — images may
    /// grow without limit but never shrink past the minimum.
    static func resizedWidth(from startX: CGFloat, to x: CGFloat, starting startWidth: CGFloat) -> CGFloat {
        max(minimumImageWidth, startWidth + (x - startX))
    }

    /// Where an inline math result sits horizontally: just past the end of
    /// its line, but never further right than the container's edge. Bounded
    /// both ways so short and long lines land in the same visible margin.
    static func mathResultX(textEnd: CGFloat, resultWidth: CGFloat, containerRight: CGFloat) -> CGFloat {
        min(max(textEnd + 16, containerRight - resultWidth - 14), containerRight - resultWidth - 4)
    }

    /// The vertical distance between guide dots or grid lines: the font's own
    /// line box scaled by the spacing setting, with a floor so a tiny font
    /// never packs the pattern into noise.
    static func guideVerticalPitch(lineHeight: CGFloat, spacingMultiple: Double) -> CGFloat {
        max(18, lineHeight * CGFloat(spacingMultiple))
    }

    var lineHeightMultiple: Double = 1.0 {
        didSet { defaultParagraphStyle = paragraphStyle }
    }

    /// Extra tracking between characters, in points. Applied by the styling
    /// pass like every other visual property, so the file never holds it.
    var letterSpacing: Double = 0 {
        didSet {
            guard letterSpacing != oldValue else { return }
            applyChecklistStyling()
        }
    }

    /// A bare keyword on the first line puts the note in checklist mode.
    var listKeyword: String = "list"

    /// A bare keyword on the first line turns the note into a code block.
    var codeKeyword: String = CodeBlock.defaultKeyword {
        didSet {
            guard codeKeyword != oldValue else { return }
            applyChecklistStyling()
        }
    }

    /// The palette text is painted with, derived from the chosen surface.
    var ink: InkTheme = .system {
        didSet {
            guard ink != oldValue else { return }
            textColor = ink.text
            insertionPointColor = ink.text
            applyChecklistStyling()
        }
    }

    /// Writing guides drawn under the glyphs.
    var guide: PaperGuide = .none {
        didSet {
            guard guide != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether the note was in list mode at the last edit, so the switch can be
    /// noticed and the existing body converted once.
    private var wasListMode = false

    /// Whether the note was a code block at the last edit. Mirrors
    /// `wasListMode`, and exists for the same reason: typing or deleting the
    /// keyword changes how every *other* line is drawn, which a restyle
    /// limited to the edited line would not pick up.
    private var wasCodeMode = false

    /// Renders the first line larger and bolder, so a note reads as a titled
    /// card without the title being a separate field. The text stays plain.
    var stylesFirstLineAsTitle = false

    /// The authoritative body font.
    ///
    /// Never read this back from `NSTextView.font`: that property reports the
    /// font of the *first character*, which the title styling has already made
    /// bold and a point larger. Deriving the base font from it fed the styling
    /// pass its own output, so every restyle promoted the whole note another
    /// point — the text grew a little each time an item was toggled.
    var baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            font = baseFont
            applyChecklistStyling()
        }
    }

    private var titleFont: NSFont {
        .monospacedSystemFont(ofSize: baseFont.pointSize + 1, weight: .semibold)
    }

    /// Reports the height the content needs, for cards that size to their note.
    var onHeightChange: ((CGFloat) -> Void)?

    /// Without an enclosing scroll view the text container never learns how
    /// wide it is, so lines run past the card and get clipped instead of
    /// wrapping — and the measured height comes back short to match.
    override func layout() {
        super.layout()
        guard onHeightChange != nil, let textContainer else { return }
        let width = bounds.width - textContainerInset.width * 2
        if abs(textContainer.size.width - width) > 0.5 {
            textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        reportHeight()
    }

    /// Measured through TextKit 1. Touching `layoutManager` opts this view out
    /// of TextKit 2, which is a fair trade for a reliable content height —
    /// nothing here depends on TextKit 2 behaviour.
    func reportHeight() {
        guard let onHeightChange, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let height = max(18, used + textContainerInset.height * 2)
        if abs(height - lastReportedHeight) > 0.5 {
            lastReportedHeight = height
            DispatchQueue.main.async { onHeightChange(height) }
        }
    }

    private var lastReportedHeight: CGFloat = -1

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = CGFloat(lineHeightMultiple)
        return style
    }

    // MARK: - Editing helpers

    /// Routes every mutation through the undo-aware path, so Cmd+Z still walks
    /// back through checklist edits.
    func replace(range: NSRange, with replacement: String, selecting selection: NSRange?) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let selection {
            setSelectedRange(clamped(selection))
        }
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let length = (string as NSString).length
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    /// The line under `location`, without its trailing newline.
    private func contentRange(forLineAt location: Int) -> NSRange {
        let ns = string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let full = ns.lineRange(for: NSRange(location: min(location, ns.length - 1), length: 0))
        let hasNewline = full.length > 0 && ns.substring(with: full).hasSuffix("\n")
        return NSRange(location: full.location, length: full.length - (hasNewline ? 1 : 0))
    }

    // MARK: - Toggle

    @objc func toggleChecklist(_ sender: Any?) {
        // Markers mean nothing inside a code block, so the command that writes
        // them does nothing there rather than leaving inert `- [ ]` in the code.
        guard !isCodeMode else { return }
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = ns.length == 0
            ? NSRange(location: 0, length: 0)
            : ns.lineRange(for: selection)

        let block = ns.substring(with: lineRange)
        let updated = Checklist.toggled(block: block)
        guard updated != block else { return }

        let delta = (updated as NSString).length - (block as NSString).length
        let newSelection = selection.length > 0
            ? NSRange(location: lineRange.location, length: (updated as NSString).length)
            : NSRange(location: selection.location + delta, length: 0)

        replace(range: lineRange, with: updated, selecting: newSelection)
    }

    /// Wraps the selection in `==...==`, or strips an existing pair back off
    /// a selection that already carries one. Phrase-sized rather than
    /// line-sized like `toggleChecklist`, since a highlight is usually a few
    /// words, not a whole line.
    ///
    /// With nothing selected, drops an empty `====` pair and lands the caret
    /// between the two marker pairs, ready to type straight into it.
    @objc func toggleHighlight(_ sender: Any?) {
        guard !isCodeMode else { return }
        let selection = selectedRange()
        let ns = string as NSString

        // "Already highlighted" is decided by whether the selection sits
        // inside a real, parsed highlight — not by whether the selected
        // *text itself* looks like `==...==`. A fresh wrap below deliberately
        // leaves the selection over just the content, markers excluded, so
        // a second toggle (a real second click, using whatever selection
        // the first one left behind) would never see the markers in a plain
        // string comparison and would just wrap again, nesting deeper each
        // time — this bug, caught in real use. Matching against the whole
        // note's actual highlight spans instead handles that shape (and a
        // bare caret sitting anywhere inside one, no selection needed) the
        // same way.
        if let existing = Highlight.matches(in: ns).first(where: {
            selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range)
        }) {
            let content = ns.substring(with: existing.contentRange)
            replace(
                range: existing.range,
                with: content,
                selecting: NSRange(location: existing.range.location, length: (content as NSString).length)
            )
        } else if selection.length == 0 {
            replace(range: selection, with: "====", selecting: NSRange(location: selection.location + 2, length: 0))
        } else {
            // Not every selection can be expressed as a highlight.
            // `Highlight.matches` only accepts a span that stays on one line
            // and holds no `=` of its own, so wrapping `total = 40`, a
            // selection crossing a newline, or one covering two adjacent
            // highlights whole emits markers the parser cannot read back:
            // they stay on screen as literal `==`, the next toggle finds no
            // span to unwrap, and every further click nests another pair.
            // Rather than duplicating the parser's rules here, build the
            // replacement, parse the text it would produce, and only commit
            // when a real highlight lands over exactly the selected content.
            //
            // A refused wrap changes nothing at all — text and selection are
            // both left as they were. The alternative, quietly narrowing the
            // selection to its first line or dropping its `=` characters,
            // would highlight something other than what was selected, which
            // is a worse surprise than the button doing nothing on input the
            // syntax has no way to represent.
            let selected = ns.substring(with: selection)
            let wrapped = ns.replacingCharacters(in: selection, with: "==\(selected)==") as NSString
            let contentRange = NSRange(location: selection.location + 2, length: (selected as NSString).length)
            guard Highlight.matches(in: wrapped).contains(where: { $0.contentRange == contentRange }) else { return }

            replace(range: selection, with: "==\(selected)==", selecting: contentRange)
        }

        // `replace` inserts brand-new `==` characters into text the layout
        // manager has already generated glyphs for — unlike a fresh keystroke
        // building glyphs incrementally, this is a bulk mid-document edit.
        // `didProcessEditing` already ran by the time `replace` returns (it
        // fires synchronously off `didChangeText()`), but the fold-forcing
        // half of that — `applyLinkFolding`'s whole-document glyph
        // invalidation — is deferred there by one run-loop tick, since it
        // can't run from inside NSTextStorage's own edit bracket. Called
        // from here, outside any bracket, it can run immediately instead of
        // trusting that deferred tick, closing whatever gap was letting
        // `==markers==` show up unfolded for a moment (or longer) after a
        // toolbar/menu-triggered toggle.
        applyLinkFolding()
    }

    // MARK: - Bold / italic

    /// Cmd+B. See `Emphasis.toggle` for exactly what it does to the text.
    @objc func toggleBold(_ sender: Any?) {
        toggleEmphasis(.strong, actionName: "Bold")
    }

    /// Cmd+I. See `Emphasis.toggle` for exactly what it does to the text.
    @objc func toggleItalic(_ sender: Any?) {
        toggleEmphasis(.emphasis, actionName: "Italic")
    }

    private func toggleEmphasis(_ kind: Emphasis.Kind, actionName: String) {
        // Asterisks are literal inside a code block, same as `==`.
        guard !isCodeMode,
              let edit = Emphasis.toggle(kind, in: string as NSString, selection: selectedRange())
        else { return }
        // One `replace` is one replaceCharacters, so one undo step. Breaking
        // coalescing first keeps it from merging into the typing before it,
        // so Cmd+Z takes back the markers and nothing else.
        breakUndoCoalescing()
        replace(range: edit.range, with: edit.replacement, selecting: edit.selection)
        undoManager?.setActionName(actionName)
        // Same reason as the end of `toggleHighlight`: fold the new markers
        // now rather than one run-loop tick later. Only the edited line,
        // since that is the only place markers appeared or went.
        let edited = NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
        applyLinkFolding(in: (string as NSString).lineRange(for: edited))
    }

    /// Whether this view is already observing the header buttons' toggle
    /// notifications, so `enableHeaderToggleButtons()` can be called
    /// idempotently from every construction site — matching the same
    /// lazy-and-idempotent shape `recomputeLinkMatches()` already uses for
    /// `layoutManager.delegate`.
    private var isObservingHeaderToggleButtons = false

    /// Lets the header's Checklist/Highlight buttons act on this view
    /// directly via notification instead of `NSApp.sendAction(_:to: nil,
    /// from: nil)`. Called only from the single-note editor
    /// (`PlainTextEditor.makeNSView`) — Screen Edge mode's cards have no
    /// such buttons, so there's nothing for them to observe.
    func enableHeaderToggleButtons() {
        guard !isObservingHeaderToggleButtons else { return }
        isObservingHeaderToggleButtons = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(toggleChecklist(_:)),
            name: .jotRequestToggleChecklistFromHeader, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(toggleHighlight(_:)),
            name: .jotRequestToggleHighlightFromHeader, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Handles this app's own shortcuts directly.
    ///
    /// The main menu is not displayed outside Dock mode, and relying on it to
    /// dispatch key equivalents there is a bet not worth making. Handling them
    /// here means Cmd+L and Shift-Cmd-V behave the same in every display mode.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == [.command, .shift], key == "v" {
            extractTextFromClipboardImage(nil)
            return true
        }
        // Ctrl-Cmd-Up/Down walk the current note through the list. Like Cmd+N
        // and Cmd+Shift+F below, this posts rather than acts: the text view
        // exists in every display mode, and AppDelegate owns the one
        // NotesManager along with the knowledge of whether the panel shows.
        if flags == [.command, .control] {
            if event.keyCode == UInt16(kVK_UpArrow) {
                NotificationCenter.default.post(name: .jotRequestMoveNoteUp, object: nil)
                return true
            }
            if event.keyCode == UInt16(kVK_DownArrow) {
                NotificationCenter.default.post(name: .jotRequestMoveNoteDown, object: nil)
                return true
            }
        }
        // Cmd-Option-Left/Right switch which note is showing, the keyboard
        // equivalent of a two-finger swipe. Option rather than Control, so it
        // doesn't collide with the reordering shortcut above, and it matches
        // Safari/Chrome's own Cmd-Option-Left/Right tab-switching muscle
        // memory. Same posting pattern as the move above.
        if flags == [.command, .option] {
            if event.keyCode == UInt16(kVK_RightArrow) {
                NotificationCenter.default.post(name: .jotRequestNextNote, object: nil)
                return true
            }
            if event.keyCode == UInt16(kVK_LeftArrow) {
                NotificationCenter.default.post(name: .jotRequestPreviousNote, object: nil)
                return true
            }
        }
        // Cmd+V is routed here too. The main menu is not displayed outside Dock
        // mode, and if it is not consulted for key equivalents then the paste
        // override is never reached at all.
        if flags == [.command], key == "v" {
            paste(nil)
            return true
        }
        // Cmd+C is claimed only for the case that would otherwise be missed:
        // the caret inside a code block, in a display mode with no main menu
        // to dispatch the Edit menu's Copy. Every other Cmd+C falls through to
        // the standard copy exactly as before, and the first-responder check
        // keeps this from reaching over the find bar's own copy.
        if flags == [.command], key == "c", window?.firstResponder === self,
           copyWholeCodeBlock() {
            return true
        }
        if flags == [.command], key == "l" {
            toggleChecklist(nil)
            return true
        }
        if flags == [.command, .shift], key == "h" {
            toggleHighlight(nil)
            return true
        }
        // Markdown markers, not font traits: the note is plain text, and
        // `usesFontPanel` is off, so there is no Font menu competing for
        // these. First-responder check for the same reason as Cmd+C above.
        if flags == [.command], key == "b", window == nil || window?.firstResponder === self {
            toggleBold(nil)
            return true
        }
        if flags == [.command], key == "i", window == nil || window?.firstResponder === self {
            toggleItalic(nil)
            return true
        }
        if flags == [.command], key == "n" {
            NotificationCenter.default.post(name: .jotRequestNewNote, object: nil)
            return true
        }
        if flags == [.command], key == "/" {
            NotificationCenter.default.post(name: .jotRequestToggleChrome, object: nil)
            return true
        }
        if flags == [.command, .shift], key == "f" {
            NotificationCenter.default.post(name: .jotRequestGlobalSearch, object: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Both are no-ops inside a code block, so the menu says so instead of
        // offering a command that would do nothing.
        if item.action == #selector(toggleChecklist(_:)) { return !isCodeMode }
        if item.action == #selector(toggleHighlight(_:)) { return !isCodeMode }
        if item.action == #selector(toggleBold(_:)) { return !isCodeMode }
        if item.action == #selector(toggleItalic(_:)) { return !isCodeMode }
        if item.action == #selector(extractTextFromClipboardImage(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - List mode

    var isListMode: Bool {
        // A code note is never also a list note: both keywords claim the whole
        // first line, and if someone configures the same word for both, the
        // code block wins. Rendering a note as plain monospaced text is the
        // more literal reading of "this line says code", and it is the mode
        // that switches everything else off, so letting it win keeps the two
        // from half-applying over each other.
        !isCodeMode && Checklist.isListMode(string, keyword: listKeyword)
    }

    var isCodeMode: Bool {
        CodeBlock.isCodeMode(string, keyword: codeKeyword)
    }

    /// The face a code block is drawn in.
    ///
    /// Code mode overrides the font *name* that per-note and theme-note
    /// typography resolved to, but keeps the size those settled on. The point
    /// of the keyword is monospaced rendering, so a proportional per-note
    /// font would defeat it, while the size is a legibility choice that has
    /// nothing to do with the note being code. A base font that is already
    /// fixed-pitch is left exactly as it is, so a user who picked Menlo (or a
    /// theme note that did) keeps their own monospaced face rather than being
    /// pushed onto the system one.
    private var codeFont: NSFont {
        baseFont.isFixedPitch
            ? baseFont
            : .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
    }

    /// Converts the body the moment the keyword appears, and only then.
    ///
    /// Done on the transition rather than continuously: converting on every
    /// keystroke would turn a half-typed word into an item under the cursor.
    private func applyListModeIfNeeded() {
        let nowListMode = isListMode
        defer { wasListMode = nowListMode }
        guard nowListMode, !wasListMode else { return }

        let converted = Checklist.convertedToList(string, keyword: listKeyword)
        guard converted != string else { return }

        let caret = selectedRange()
        let whole = NSRange(location: 0, length: (string as NSString).length)
        // Deferred: the text storage is mid-edit when this is called.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shift = (converted as NSString).length - whole.length
            self.replace(
                range: NSRange(location: 0, length: (self.string as NSString).length),
                with: converted,
                selecting: NSRange(location: max(0, caret.location + max(0, shift)), length: 0)
            )
        }
    }

    // MARK: - Code blocks

    /// Whether this edit flipped code mode on or off.
    private func codeModeDidChange() -> Bool {
        let now = isCodeMode
        defer { wasCodeMode = now }
        return now != wasCodeMode
    }

    /// Copies the whole code block when there is nothing selected and the
    /// caret sits inside one, and reports whether it did. False means the
    /// ordinary copy should run: either this is not a code note, or there is a
    /// selection, which is an explicit request for exactly that text.
    ///
    /// Takes the pasteboard so a test can hand it a private one instead of
    /// clobbering whatever the user has on the general clipboard.
    @discardableResult
    func copyWholeCodeBlock(to pasteboard: NSPasteboard = .general) -> Bool {
        guard selectedRange().length == 0,
              let body = CodeBlock.body(of: string, keyword: codeKeyword)
        else { return false }
        pasteboard.clearContents()
        pasteboard.setString(body, forType: .string)
        return true
    }

    /// Overridden rather than handled only in `performKeyEquivalent`, so the
    /// Edit menu's own Copy item behaves the same way the shortcut does.
    override func copy(_ sender: Any?) {
        if copyWholeCodeBlock() { return }
        super.copy(sender)
    }

    // MARK: - Return

    override func insertNewline(_ sender: Any?) {
        // Nothing continues itself inside a code block: no checklist items, no
        // ordered numbering. Return inserts a newline and that is all.
        guard !isCodeMode else {
            super.insertNewline(sender)
            return
        }

        let selection = selectedRange()
        guard selection.length == 0, (string as NSString).length > 0 else {
            super.insertNewline(sender)
            return
        }

        let lineRange = contentRange(forLineAt: selection.location)
        let line = (string as NSString).substring(with: lineRange)

        // An ordered-list line (`1.` `a.` `iv.`) continues its own sequence
        // ahead of checklist-mode conversion, so typing `1.` inside a list
        // note keeps its shape instead of being wrapped as `- [ ] 1. …`.
        // Mid-line carets fall through to an ordinary newline: splitting an
        // item in half is not the moment to invent renumbering.
        if selection.location == lineRange.location + lineRange.length,
           let outcome = OrderedList.newline(inLine: line) {
            switch outcome {
            case .exitList(let replacement):
                replace(
                    range: lineRange,
                    with: replacement,
                    selecting: NSRange(location: lineRange.location + (replacement as NSString).length, length: 0)
                )
            case .continueList(let insertion):
                replace(
                    range: selection,
                    with: insertion,
                    selecting: NSRange(location: selection.location + (insertion as NSString).length, length: 0)
                )
            }
            return
        }

        // In list mode a plain line becomes an item as soon as you leave it,
        // so the whole note stays a list without any markers being typed.
        if isListMode,
           lineRange.location > 0,
           Checklist.item(in: line) == nil,
           !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = Checklist.leadingWhitespace(of: line)
            let converted = Checklist.render(
                indent: indent,
                isChecked: false,
                body: String(line.dropFirst(indent.count))
            )
            // One edit, so one undo step covers both halves.
            let replacement = converted + "\n" + Checklist.emptyItem(indent: indent)
            replace(
                range: lineRange,
                with: replacement,
                selecting: NSRange(
                    location: lineRange.location + (replacement as NSString).length,
                    length: 0
                )
            )
            return
        }

        // A plain `- ` bullet continues itself the way the two markers above
        // do. It sits below list-mode conversion rather than above it like the
        // ordered branch: inside a checklist note the mode's promise is that
        // every line becomes an item, and `1.` has no checkbox equivalent to
        // be wrapped into while a dash does. End-of-line only, for both
        // outcomes — mid-line the ordered branch leaves the text alone, and
        // emptying a marker the caret is standing inside of is the surprising
        // half of the two behaviours, not the one worth copying.
        if selection.location == lineRange.location + lineRange.length,
           let outcome = Bullet.newline(inLine: line) {
            switch outcome {
            case .exitList(let replacement):
                replace(
                    range: lineRange,
                    with: replacement,
                    selecting: NSRange(location: lineRange.location + (replacement as NSString).length, length: 0)
                )
            case .continueList(let insertion):
                replace(
                    range: selection,
                    with: insertion,
                    selecting: NSRange(location: selection.location + (insertion as NSString).length, length: 0)
                )
            }
            return
        }

        guard let outcome = Checklist.newline(inLine: line) else {
            super.insertNewline(sender)
            return
        }

        switch outcome {
        case .exitList(let replacement):
            replace(
                range: lineRange,
                with: replacement,
                selecting: NSRange(location: lineRange.location + (replacement as NSString).length, length: 0)
            )

        case .continueList(let insertion):
            // Splitting mid-item and guessing what the remainder should become
            // is worse than just inserting a plain newline there.
            guard selection.location == lineRange.location + lineRange.length else {
                super.insertNewline(sender)
                return
            }
            replace(
                range: selection,
                with: insertion,
                selecting: NSRange(location: selection.location + (insertion as NSString).length, length: 0)
            )
        }
    }

    // MARK: - Nesting

    override func insertTab(_ sender: Any?) {
        // Tab indents checklist items everywhere else; in a code block it is
        // just a tab, which is what indenting code with it should do.
        if isCodeMode || !indentSelection(by: 1) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if isCodeMode || !indentSelection(by: -1) { super.insertBacktab(sender) }
    }

    private func indentSelection(by levels: Int) -> Bool {
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let selection = selectedRange()
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        guard let updated = Checklist.indented(block: block, by: levels) else { return false }

        let unit = (Checklist.indentUnit as NSString).length
        let newSelection = selection.length > 0
            ? NSRange(location: lineRange.location, length: (updated as NSString).length)
            : NSRange(location: max(lineRange.location, selection.location + (levels > 0 ? unit : -unit)), length: 0)

        replace(range: lineRange, with: updated, selecting: newSelection)
        return true
    }

    // MARK: - Images in, text out

    /// Accepts an image dropped anywhere in the note and replaces it with the
    /// text Vision reads out of it.
    func enableImageDrops() {
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TextRecognition.image(from: sender.draggingPasteboard) != nil
            ? .copy
            : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = TextRecognition.image(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }

        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        // Option-drop reads the image as text; a plain drop keeps the image.
        if NSEvent.modifierFlags.contains(.option) {
            recognize(image, insertingAt: index)
        } else {
            insertImage(image, at: index)
        }
        return true
    }

    /// Cmd+V inserts an image on the clipboard as an image.
    ///
    /// Text extraction used to live here, but pasting a screenshot to *keep* it
    /// is the more common intent, so OCR moved to its own command.
    override func paste(_ sender: Any?) {
        if TextRecognition.containsImage(.general),
           let image = TextRecognition.image(from: .general) {
            insertImage(image, at: selectedRange().location)
            return
        }
        if let pasted = NSPasteboard.general.string(forType: .string),
           insertPastedListText(pasted) || insertAtImageEdge(pasted) {
            return
        }
        super.paste(sender)
    }

    /// The list-note half of `paste(_:)`, split out so it can be driven
    /// without touching the real clipboard. False means "paste normally".
    func insertPastedListText(_ pasted: String) -> Bool {
        guard !isCodeMode else { return false }
        let range = clamped(selectedRange())
        let ns = string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
        let linePrefix = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        guard let converted = Checklist.pastedAsListItems(pasted, into: string, keyword: listKeyword, linePrefix: linePrefix)
        else { return false }
        replace(
            range: range,
            with: converted,
            selecting: NSRange(location: range.location + (converted as NSString).length, length: 0)
        )
        return true
    }

    /// Shift-Cmd-V: read the clipboard image as text instead of inserting it.
    @objc func extractTextFromClipboardImage(_ sender: Any?) {
        guard let image = TextRecognition.image(from: .general) else {
            NSSound.beep()
            return
        }
        recognize(image, insertingAt: selectedRange().location)
    }

    /// Saves the image beside the notes and drops a markdown reference to it on
    /// its own line. The note stays plain text.
    func insertImage(_ image: NSImage, at index: Int) {
        do {
            let path = try Attachments.save(image)
            let markdown = Attachments.markdown(path: path, width: Attachments.defaultWidth(for: image))
            let ns = string as NSString
            let location = min(index, ns.length)
            let needsLeadingBreak = location > 0 && ns.substring(with: NSRange(location: location - 1, length: 1)) != "\n"
            let insertion = (needsLeadingBreak ? "\n" : "") + markdown + "\n"
            replace(
                range: NSRange(location: location, length: 0),
                with: insertion,
                selecting: NSRange(location: location + (insertion as NSString).length, length: 0)
            )
        } catch {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "Could not save that image"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func recognize(_ image: NSImage, insertingAt index: Int) {
        Task { @MainActor in
            do {
                let recognised = try await TextRecognition.recognizeText(in: image)
                let insertion = recognised.hasSuffix("\n") ? recognised : recognised + "\n"
                let target = NSRange(location: min(index, (self.string as NSString).length), length: 0)
                self.replace(
                    range: target,
                    with: insertion,
                    selecting: NSRange(location: target.location + (insertion as NSString).length, length: 0)
                )
            } catch {
                NSSound.beep()
                NSLog("Jot: text recognition failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Clicking the box

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, (string as NSString).length > 0 else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard handleSpecialClick(at: point, modifiers: event.modifierFlags) else {
            isTrackingClick = true
            defer { isTrackingClick = false }
            super.mouseDown(with: event)
            return
        }
    }

    /// The actual hit-test-and-act logic, isolated from window-coordinate
    /// conversion so it is directly testable: `point` must already be in this
    /// view's own coordinate space. Returns true when the click was claimed
    /// (a checkbox toggled, or an image resize began) and false when the
    /// caller should fall through to normal caret placement.
    ///
    /// Kept separate from `mouseDown` itself for a second reason beyond
    /// testability: constructing a real `NSWindow` to drive `mouseDown`
    /// through `convert(_:from:)` hangs indefinitely in a plain command-line
    /// process with no window server session, which this project's
    /// swiftc-only test binary is. Testing this method directly sidesteps
    /// that entirely, rather than fighting it.
    ///
    /// `modifiers` comes from the click event itself rather than the live
    /// `NSEvent.modifierFlags`, so a test can say whether Cmd was down.
    @discardableResult
    func handleSpecialClick(at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        if let placed = image(at: point) {
            beginResize(placed, from: point)
            return true
        }

        // A currency hint says the sum was skipped because of a setting, so
        // clicking it goes to the setting rather than placing a caret in the
        // margin, where there is no text to edit anyway.
        if mathHintRects.contains(where: { $0.insetBy(dx: -4, dy: -2).contains(point) }) {
            NotificationCenter.default.post(name: .jotRequestPrivacySettings, object: nil)
            return true
        }

        // Cmd+click opens, the Zed / VS Code convention. Any link counts, not
        // only the long ones that get shrunk. A Cmd+click anywhere else falls
        // through to NSTextView's own Cmd+click (discontiguous selection).
        if modifiers.contains(.command), let url = openableLink(at: point) {
            if LinkShrink.isSafeToOpen(url) {
                linkOpener(url)
            } else {
                NSSound.beep()
            }
            return true
        }

        // A plain click on a collapsed link opens it up for editing. Claimed
        // rather than passed on, because unfolding moves the text under the
        // pointer: the caret goes on the character that was clicked, placed
        // here before the layout shifts, not whatever ends up under the
        // pointer afterwards.
        if !modifiers.contains(.command), let match = linkMatch(at: point), !isExpanded(match) {
            let index = min(
                max(characterIndexForInsertion(at: point), match.displayRange.location),
                NSMaxRange(match.displayRange)
            )
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: index, length: 0))
            revealsLinkAtSelection = true
            applyLinkFolding(in: match.range)
            return true
        }

        let index = characterIndexForInsertion(at: point)
        let lineRange = contentRange(forLineAt: index)
        let line = (string as NSString).substring(with: lineRange)

        guard let item = Checklist.item(in: line) else { return false }

        let markerStart = lineRange.location + item.markerRange.location
        let markerEnd = markerStart + item.markerRange.length
        guard index >= markerStart, index <= markerEnd else { return false }

        let updated = Checklist.toggled(block: line)
        replace(range: lineRange, with: updated, selecting: selectedRange())
        return true
    }

    // MARK: - Caret

    /// Draws the caret on the text's own baseline, at the text's height.
    ///
    /// The line box is as tall as the line-spacing setting makes it, and on an
    /// image line as tall as the image. Centring the caret in that box was not
    /// enough: extra leading is not distributed evenly, so the caret floated
    /// above the glyphs like a superscript. Anchoring to the real baseline from
    /// the layout manager puts it where the text actually sits.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: caretRect(from: rect), color: color, turnedOn: flag)
    }

    func caretRect(from rect: NSRect) -> NSRect {
        let ascender = ceil(baseFont.ascender)
        let textHeight = ceil(baseFont.ascender - baseFont.descender)
        guard rect.height > textHeight + 0.5 else { return rect }

        var caret = rect
        caret.size.height = textHeight

        guard let layoutManager,
              let textStorage,
              textStorage.length > 0
        else {
            // Empty note: nothing has been laid out, so sit on the bottom of
            // the box, which is where the first glyph will land.
            caret.origin.y = rect.maxY - textHeight
            return caret
        }

        let characterIndex = min(max(0, selectedRange().location), textStorage.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let baseline = fragment.minY
            + layoutManager.location(forGlyphAt: glyphIndex).y
            + textContainerInset.height

        caret.origin.y = baseline - ascender
        return caret
    }

    // MARK: - Writing guides

    /// Dots and grid lines drawn behind the glyphs.
    ///
    /// The vertical pitch follows the real line height, so the pattern
    /// breathes with the font size and line-spacing settings instead of
    /// fighting them. Both axes are phase-locked to the text container's
    /// inset so the pattern starts where the text does rather than drifting
    /// with window size. Lines span the full bounds rather than just the
    /// dirty rect, so partial redraws can't leave seams at their edges.
    private func drawGuide(in dirtyRect: NSRect) {
        guard guide != .none else { return }
        let color = ink.guide.withAlphaComponent(0.16)
        // The standard line box: ascent, descent, leading.
        let lineHeight = baseFont.ascender - baseFont.descender + baseFont.leading
        let verticalPitch = Self.guideVerticalPitch(lineHeight: lineHeight, spacingMultiple: lineHeightMultiple)
        let horizontalPitch: CGFloat = 22

        // The text view is only as tall as its content; cover the visible
        // clip too so an empty tail of the window stays patterned.
        let covered = CGSize(
            width: bounds.width,
            height: max(bounds.height, enclosingScrollView?.contentView.bounds.height ?? 0)
        )

        let xs = stride(from: textContainerInset.width, through: covered.width, by: horizontalPitch)
        let ys = stride(from: textContainerInset.height, through: covered.height, by: verticalPitch)

        switch guide {
        case .dots:
            color.setFill()
            for y in ys where y >= dirtyRect.minY - 2 && y <= dirtyRect.maxY + 2 {
                for x in xs where x >= dirtyRect.minX - 2 && x <= dirtyRect.maxX + 2 {
                    NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
                }
            }
        case .grid:
            let path = NSBezierPath()
            path.lineWidth = 0.5
            for x in xs where x >= dirtyRect.minX && x <= dirtyRect.maxX {
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x, y: covered.height))
            }
            for y in ys where y >= dirtyRect.minY && y <= dirtyRect.maxY {
                path.move(to: NSPoint(x: 0, y: y))
                path.line(to: NSPoint(x: covered.width, y: y))
            }
            color.setStroke()
            path.stroke()
        case .none:
            break
        }
    }

    // MARK: - Inline images

    /// Width being previewed during a resize drag, so the text is rewritten
    /// once on mouse-up rather than on every frame of the drag.
    private var resizingRange: NSRange?
    private var previewWidth: CGFloat?

    struct PlacedImage {
        let image: NSImage
        let markdownRange: NSRange
        let rect: NSRect
    }

    /// Where each image reference lands on screen, derived fresh from layout.
    func placedImages() -> [PlacedImage] {
        guard let textStorage else { return [] }
        let ns = textStorage.string as NSString
        return loadedImageReferences(touching: NSRange(location: 0, length: ns.length)).compactMap(placedImage(for:))
    }

    /// Where one loaded reference's image is drawn: at the reference's first
    /// glyph, at its display width.
    private func placedImage(for loaded: LoadedImageReference) -> PlacedImage? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: loaded.markdownRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height

        let width = displayWidth(for: loaded.reference, image: loaded.image, markdownRange: loaded.markdownRange)
        let height = width * (loaded.image.size.height / max(1, loaded.image.size.width))
        return PlacedImage(
            image: loaded.image,
            markdownRange: loaded.markdownRange,
            rect: NSRect(x: rect.minX, y: rect.minY, width: width, height: height)
        )
    }

    private func displayWidth(for reference: ImageReference, image: NSImage, markdownRange: NSRange) -> CGFloat {
        if let previewWidth, resizingRange == markdownRange { return previewWidth }
        return reference.width ?? Attachments.defaultWidth(for: image)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawGuide(in: dirtyRect)
        super.draw(dirtyRect)
        drawMathResults(in: dirtyRect)
        for placed in placedImages() where placed.rect.intersects(dirtyRect) {
            placed.image.draw(
                in: placed.rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }
    }

    /// Whether `line` holds nothing but image references (and whitespace).
    static func isImageOnlyLine(_ line: String, references: [ImageReference]) -> Bool {
        guard !references.isEmpty else { return false }
        let remainder = NSMutableString(string: line)
        for reference in references.sorted(by: { $0.range.location > $1.range.location }) {
            remainder.deleteCharacters(in: reference.range)
        }
        return (remainder as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Double-clicking inside an image's hidden markdown selects the whole
    /// reference. Selecting one word of an invisible path highlighted a sliver
    /// of blank space under the image and was never what anyone meant.
    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        let proposed = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        guard granularity == .selectByWord, let textStorage else { return proposed }
        let ns = textStorage.string as NSString
        guard proposedCharRange.location <= ns.length else { return proposed }
        let lineRange = ns.lineRange(for: NSRange(location: proposedCharRange.location, length: 0))
        for reference in Attachments.references(in: ns.substring(with: lineRange)) {
            let markdownRange = NSRange(location: lineRange.location + reference.range.location, length: reference.range.length)
            guard NSLocationInRange(proposedCharRange.location, markdownRange),
                  Attachments.image(at: reference.path) != nil else { continue }
            return NSUnionRange(markdownRange, proposedCharRange)
        }
        return proposed
    }

    // MARK: - Images as single characters

    /// An image reference whose file loads, so it is drawn as a picture.
    struct LoadedImageReference {
        let reference: ImageReference
        let image: NSImage
        /// The whole `![320](path)` run, in string coordinates.
        let markdownRange: NSRange
        /// Whether its line holds nothing but image references.
        let isAloneOnLine: Bool
        /// Its line, without the trailing newline.
        let lineRange: NSRange
    }

    /// Loaded image references on the lines touching `range`.
    ///
    /// These are the ones drawn as pictures over clear markdown, so they are
    /// the ones that must act like one attachment character: the characters
    /// underneath are invisible, and a caret among them edits a path the user
    /// cannot see. A reference whose file does not load shows its markdown
    /// and stays ordinary text, so it can be fixed.
    func loadedImageReferences(touching range: NSRange) -> [LoadedImageReference] {
        guard let textStorage else { return [] }
        let ns = textStorage.string as NSString
        guard ns.length > 0 else { return [] }
        let lines = ns.lineRange(for: clamped(range))
        var loaded: [LoadedImageReference] = []
        ns.enumerateSubstrings(in: lines, options: [.byLines]) { line, lineRange, _, _ in
            guard let line, line.contains("![") else { return }
            let references = Attachments.references(in: line)
            let alone = Self.isImageOnlyLine(line, references: references)
            for reference in references {
                guard let image = Attachments.image(at: reference.path) else { continue }
                loaded.append(LoadedImageReference(
                    reference: reference,
                    image: image,
                    markdownRange: NSRange(location: lineRange.location + reference.range.location, length: reference.range.length),
                    isAloneOnLine: alone,
                    lineRange: lineRange
                ))
            }
        }
        return loaded
    }

    /// Set while `mouseDown` is tracking a click, so a caret landing inside a
    /// reference is placed by where the pointer is, not by which way it came.
    private var isTrackingClick = false

    /// `proposed`, adjusted so no edge of it falls inside a loaded image
    /// reference.
    ///
    /// A caret inside goes to an edge. Arrow keys come from one edge and so
    /// jump to the other, which is what Left and Right over an attachment do
    /// in any Mac text view. Anything else (a click, Up or Down, a caret
    /// set in code) goes to the edge nearer the proposed point, judged by the
    /// middle of the drawn image rather than the middle of the hidden text,
    /// since the image is what the user is looking at.
    ///
    /// A selection with an end inside grows to cover the whole reference,
    /// except when the previous selection already covered it: then that end
    /// is shrinking back across the image (Shift-Left after Shift-Right), and
    /// it lets go of the whole reference instead of getting stuck on it.
    func atomicSelection(_ proposed: NSRange, previous: NSRange, fromClick: Bool) -> NSRange {
        let atoms = loadedImageReferences(touching: proposed)
        guard !atoms.isEmpty else { return proposed }
        func inside(_ index: Int, _ atom: NSRange) -> Bool {
            index > atom.location && index < NSMaxRange(atom)
        }

        if proposed.length == 0 {
            guard let atom = atoms.first(where: { inside(proposed.location, $0.markdownRange) }) else { return proposed }
            let start = atom.markdownRange.location
            let end = NSMaxRange(atom.markdownRange)
            if !fromClick, previous.length == 0 {
                if previous.location == start { return NSRange(location: end, length: 0) }
                if previous.location == end { return NSRange(location: start, length: 0) }
            }
            return NSRange(location: nearerEdge(of: atom, to: proposed.location), length: 0)
        }

        var lower = proposed.location
        var upper = NSMaxRange(proposed)
        for atom in atoms.map(\.markdownRange) {
            let lowerInside = inside(lower, atom)
            let upperInside = inside(upper, atom)
            guard lowerInside || upperInside else { continue }
            if previous.length > 0, NSIntersectionRange(previous, atom) == atom {
                let shrunkLower = lowerInside ? NSMaxRange(atom) : lower
                let shrunkUpper = upperInside ? atom.location : upper
                if shrunkLower <= shrunkUpper {
                    lower = shrunkLower
                    upper = shrunkUpper
                    continue
                }
            }
            if lowerInside { lower = atom.location }
            if upperInside { upper = NSMaxRange(atom) }
        }
        return NSRange(location: lower, length: upper - lower)
    }

    /// `range` grown so it never cuts a loaded reference in half. What a
    /// deletion is widened to.
    func rangeCoveringWholeImages(_ range: NSRange) -> NSRange {
        var lower = range.location
        var upper = NSMaxRange(range)
        for atom in loadedImageReferences(touching: range).map(\.markdownRange) {
            if lower > atom.location && lower < NSMaxRange(atom) { lower = atom.location }
            if upper > atom.location && upper < NSMaxRange(atom) { upper = NSMaxRange(atom) }
        }
        return NSRange(location: lower, length: upper - lower)
    }

    /// The edge of `atom` nearer `location`, measured against the middle of
    /// the drawn image. Falls back to the middle of the text while the
    /// storage is mid-edit, when layout cannot be asked for.
    private func nearerEdge(of atom: LoadedImageReference, to location: Int) -> Int {
        let start = atom.markdownRange.location
        let end = NSMaxRange(atom.markdownRange)
        let byText = location - start <= end - location ? start : end
        guard textStorage?.editedMask.isEmpty ?? true,
              let layoutManager, let textContainer,
              let placed = placedImage(for: atom) else { return byText }
        let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        let x = layoutManager.boundingRect(forGlyphRange: glyph, in: textContainer).minX + textContainerInset.width
        return x < placed.rect.midX ? start : end
    }

    /// Where a click on an image that did not turn into a resize puts the
    /// caret: before the image for its left half, after it for its right.
    func caretLocation(forClickOn placed: PlacedImage, at point: NSPoint) -> Int {
        point.x < placed.rect.midX ? placed.markdownRange.location : NSMaxRange(placed.markdownRange)
    }

    /// Inserts `text` beside an image that has its line to itself, on a line
    /// of its own. Returns false, doing nothing, anywhere else.
    ///
    /// Text sharing a line with an image would sit at the foot of an
    /// image-tall line, and that line would go back to wrapping its hidden
    /// markdown into blank image-tall gaps (issue #10). So typing or pasting
    /// before an image opens a line above it, and after an image a line
    /// below it. Text that already brings its own line break (Return) is
    /// left to the normal path.
    @discardableResult
    func insertAtImageEdge(_ text: String) -> Bool {
        guard !text.isEmpty, !hasMarkedText() else { return false }
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let ns = string as NSString
        let location = selection.location
        for atom in loadedImageReferences(touching: selection) where atom.isAloneOnLine {
            let start = atom.markdownRange.location
            let end = NSMaxRange(atom.markdownRange)
            if location == start, !text.hasSuffix("\n"),
               ns.substring(with: NSRange(location: atom.lineRange.location, length: start - atom.lineRange.location))
                .trimmingCharacters(in: .whitespaces).isEmpty {
                replace(range: selection, with: text + "\n",
                        selecting: NSRange(location: start + (text as NSString).length, length: 0))
                return true
            }
            if location == end, !text.hasPrefix("\n"),
               ns.substring(with: NSRange(location: end, length: NSMaxRange(atom.lineRange) - end))
                .trimmingCharacters(in: .whitespaces).isEmpty {
                let insertion = "\n" + text
                replace(range: selection, with: insertion,
                        selecting: NSRange(location: end + (insertion as NSString).length, length: 0))
                return true
            }
        }
        return false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound || replacementRange == selectedRange(),
           let text = (string as? String) ?? (string as? NSAttributedString)?.string,
           insertAtImageEdge(text) {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Set while one of the delete commands below runs. A change it proposes
    /// that cuts into a loaded image is refused and widened into this, then
    /// made once the command returns, so it is still one edit and one undo.
    private var isInterceptingDeletion = false
    private var widenedDeletion: NSRange?

    private func deletingWholeImages(_ command: () -> Void) {
        isInterceptingDeletion = true
        widenedDeletion = nil
        command()
        isInterceptingDeletion = false
        guard let widened = widenedDeletion else { return }
        widenedDeletion = nil
        replace(range: widened, with: "", selecting: NSRange(location: widened.location, length: 0))
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        if isInterceptingDeletion,
           affectedRanges.count == 1,
           (replacementStrings ?? [""]).allSatisfy(\.isEmpty) {
            let range = affectedRanges[0].rangeValue
            let widened = rangeCoveringWholeImages(range)
            if widened != range {
                widenedDeletion = widened
                return false
            }
        }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    override func deleteBackward(_ sender: Any?) { deletingWholeImages { super.deleteBackward(sender) } }
    override func deleteForward(_ sender: Any?) { deletingWholeImages { super.deleteForward(sender) } }
    override func deleteWordBackward(_ sender: Any?) { deletingWholeImages { super.deleteWordBackward(sender) } }
    override func deleteWordForward(_ sender: Any?) { deletingWholeImages { super.deleteWordForward(sender) } }
    override func deleteToBeginningOfLine(_ sender: Any?) { deletingWholeImages { super.deleteToBeginningOfLine(sender) } }
    override func deleteToEndOfLine(_ sender: Any?) { deletingWholeImages { super.deleteToEndOfLine(sender) } }
    override func deleteToBeginningOfParagraph(_ sender: Any?) { deletingWholeImages { super.deleteToBeginningOfParagraph(sender) } }
    override func deleteToEndOfParagraph(_ sender: Any?) { deletingWholeImages { super.deleteToEndOfParagraph(sender) } }
    override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        deletingWholeImages { super.deleteBackwardByDecomposingPreviousCharacter(sender) }
    }

    /// Returns the image under `point`, if any.
    private func image(at point: NSPoint) -> PlacedImage? {
        placedImages().first { $0.rect.contains(point) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for placed in placedImages() {
            addCursorRect(placed.rect, cursor: .resizeLeftRight)
        }
    }

    /// Drag an image left or right to resize it. The width lives in the text,
    /// so the result is still something you could have typed by hand.
    private func beginResize(_ placed: PlacedImage, from startPoint: NSPoint) {
        let startWidth = placed.rect.width
        resizingRange = placed.markdownRange
        previewWidth = startWidth

        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .default) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            let point = self.convert(event.locationInWindow, from: nil)

            if event.type == .leftMouseDragged {
                self.previewWidth = Self.resizedWidth(from: startPoint.x, to: point.x, starting: startWidth)
                self.needsDisplay = true
                return
            }

            stop.pointee = true
            defer {
                self.resizingRange = nil
                self.previewWidth = nil
            }
            guard let finalWidth = self.previewWidth, abs(finalWidth - startWidth) > 1 else {
                // A click, not a drag: the image is one character, so the
                // caret goes before or after it by which half was clicked.
                self.window?.makeFirstResponder(self)
                self.setSelectedRange(NSRange(location: self.caretLocation(forClickOn: placed, at: startPoint), length: 0))
                return
            }

            let ns = self.string as NSString
            let markdown = ns.substring(with: placed.markdownRange)
            guard let rewritten = Attachments.settingWidth(
                finalWidth,
                on: markdown,
                at: NSRange(location: 0, length: (markdown as NSString).length)
            ) else { return }

            self.replace(range: placed.markdownRange, with: rewritten, selecting: nil)
        }
    }

    // MARK: - Inline math

    /// One result per line that evaluated, recomputed whenever the text
    /// changes. Evaluated top to bottom in one pass so later lines see
    /// earlier variables — the whole reason this recomputes on every
    /// keystroke rather than tracking a dependency graph.
    /// `isHint` marks a line that produced no number but has a reason worth
    /// saying, currently only a mixed-currency sum with no usable rate. It is
    /// drawn muted rather than in the accent colour, and it is clickable.
    private var mathResults: [(lineRange: NSRange, text: String, isHint: Bool)] = []

    /// Where each hint was last drawn, for hit-testing a click on it. Rebuilt
    /// on every draw, since the text under it moves as the note is edited.
    private var mathHintRects: [NSRect] = []

    /// Speaks the caret line's result to VoiceOver when it changes, since the
    /// results are only ever drawn. See EditorAccessibility.swift.
    let mathSpeech = MathResultSpeech()

    /// The drawn results in the form accessibility reads them.
    var spokenMathResults: [SpokenMathResult] {
        mathResults.map { SpokenMathResult(lineRange: $0.lineRange, text: $0.text, isHint: $0.isHint) }
    }

    func recomputeMathResults() {
        defer { mathSpeech.resultsUpdated(spokenMathResults) }
        // Math results are a parse of the text, so they stay out of a code
        // block like every other parser.
        guard let textStorage, !isCodeMode else { mathResults = []; return }
        let ns = textStorage.string as NSString
        var environment: [String: MathExpression.Value] = [:]
        var results: [(NSRange, String, Bool)] = []

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line, let node = MathExpression.parse(line) else { return }
            switch MathExpression.evaluate(node, environment: &environment) {
            case .success(let value):
                results.append((lineRange, MathExpression.format(value), false))
            case .failure(let error):
                guard let hint = MathExpression.hint(for: error) else { return }
                results.append((lineRange, hint, true))
            }
        }
        mathResults = results
    }

    private func drawMathResults(in dirtyRect: NSRect) {
        mathHintRects = []
        guard let layoutManager, let textContainer, !mathResults.isEmpty else { return }
        let font = NSFont.monospacedSystemFont(ofSize: max(10, baseFont.pointSize - 1), weight: .medium)
        let resultAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink.accent,
        ]
        // A hint is not an answer, so it does not get the accent the answers
        // use. Muted, it reads as an aside rather than as a result.
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink.secondary,
        ]

        for (lineRange, text, isHint) in mathResults {
            let attributes = isHint ? hintAttributes : resultAttributes
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 || lineRange.length == 0 else { continue }
            let fragment = layoutManager.lineFragmentUsedRect(
                forGlyphAt: min(glyphRange.location, max(0, layoutManager.numberOfGlyphs - 1)),
                effectiveRange: nil
            )
            var lineRect = fragment
            lineRect.origin.x += textContainerInset.width
            lineRect.origin.y += textContainerInset.height
            guard lineRect.intersects(dirtyRect) else { continue }

            let size = (text as NSString).size(withAttributes: attributes)
            // Right-aligned in the margin, never overlapping the text itself
            // even on a long line — it simply sits past the end of it.
            //
            // Bounded against the text container's own width, not the view's
            // `bounds.width`: the scroll view can report a wider bounds than
            // what is actually visible, which pushed results out past the
            // window edge where they were clipped.
            let textEnd = lineRect.minX + layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).width
            let rightEdge = textContainer.size.width + textContainerInset.width
            let x = Self.mathResultX(textEnd: textEnd, resultWidth: size.width, containerRight: rightEdge)
            let drawRect = NSRect(x: x, y: lineRect.minY + (lineRect.height - size.height) / 2, width: size.width, height: size.height)
            (text as NSString).draw(in: drawRect, withAttributes: attributes)
            if isHint { mathHintRects.append(drawRect) }
        }
    }

    // MARK: - Links

    /// Recomputed alongside math, on every keystroke — the note's text is
    /// small enough that scanning it fresh each time is simpler than tracking
    /// which lines changed, matching `recomputeMathResults`.
    private var linkMatches: [LinkMatch] = []

    /// Set by a plain click on a collapsed link: while it is set, whichever
    /// shrunk link the selection touches is drawn in full so it can be
    /// edited. Cleared the moment the selection leaves every link, which
    /// folds it back. Tied to the selection rather than to the URL's text
    /// (the old Cmd+click model keyed a set by the URL string), because
    /// editing the URL changes that string, and a link that folded itself
    /// away on the first keystroke inside it could not be edited at all.
    /// Session-only presentation state, never written to disk.
    private var revealsLinkAtSelection = false

    /// Where Cmd+click sends a link. NSWorkspace in the app; a spy in tests,
    /// so a test run never launches a browser.
    var linkOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Whether `match` is currently drawn in full.
    func isExpanded(_ match: LinkMatch) -> Bool {
        revealsLinkAtSelection && selectionTouches(match.range)
    }

    /// The caret counts as touching a link from its first character through
    /// the position just past its last, so End on a link keeps it open for
    /// appending.
    private func selectionTouches(_ range: NSRange) -> Bool {
        let selection = selectedRange()
        if selection.length == 0 {
            return selection.location >= range.location && selection.location <= NSMaxRange(range)
        }
        return NSIntersectionRange(selection, range).length > 0
    }

    private var expandedLinkRanges: [NSRange] {
        linkMatches.filter(isExpanded).map(\.range)
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        let before = expandedLinkRanges
        // Snapped before AppKit sees them, so a caret inside a hidden image
        // reference is never drawn, not even for one frame.
        let previous = selectedRange()
        let ranges = ranges.map { value -> NSValue in
            let proposed = value.rangeValue
            let snapped = atomicSelection(proposed, previous: previous, fromClick: isTrackingClick)
            return snapped == proposed ? value : NSValue(range: snapped)
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard revealsLinkAtSelection else { return }
        if !linkMatches.contains(where: { selectionTouches($0.range) }) {
            revealsLinkAtSelection = false
        }
        let after = expandedLinkRanges
        guard after != before else { return }
        // Only the links that opened or folded are re-laid out, and at once:
        // no animation, nothing else in the note moves.
        let changed = (before + after).reduce(nil as NSRange?) { union, range in
            union.map { NSUnionRange($0, range) } ?? range
        }
        // Refolding forces glyph generation, which AppKit refuses while the
        // text storage is mid-edit (a selection change can arrive from inside
        // one); defer in that case only, same as `didProcessEditing` does.
        if textStorage?.editedMask.isEmpty ?? true {
            applyLinkFolding(in: changed)
        } else {
            DispatchQueue.main.async { [weak self] in self?.applyLinkFolding(in: changed) }
        }
    }

    /// Swaps the document for a different note's text and restyles it.
    ///
    /// This is the body of the note-switch branch in
    /// `PlainTextEditor.updateNSView`, kept on the view so the sequence has one
    /// home and can be driven directly by a test. Callers are responsible for
    /// only reaching it on a genuine divergence between the model and the view.
    func loadNoteText(_ text: String) {
        let caret = selectedRange().location
        // Another note's results are a starting point, not a change to speak.
        mathSpeech.rebase()
        string = text
        // The stack that was just built up belongs to the note being left. Its
        // actions are recorded against that note's ranges, and the text view
        // has no idea the document underneath it changed, so the next Cmd+Z
        // would replay the previous note's edit into this one: characters
        // vanish from a note nobody touched, or the recorded offset lands past
        // the end of a shorter note and the text storage raises
        // NSRangeException. Either way `scheduleSave` writes the damage to
        // notes.json 0.6s later. Undo history belongs to a note, and this is
        // where a note ends, so the stack goes with it.
        undoManager?.removeAllActions()
        let length = (text as NSString).length
        setSelectedRange(NSRange(location: min(caret, length), length: 0))
        applyChecklistStyling()
        recomputeLinkMatches()
        applyLinkFolding()
    }

    func recomputeLinkMatches() {
        // Overriding an NSTextView designated initializer to wire this up
        // once broke the plain `ChecklistTextView()` initializer every
        // production call site relies on — Swift stops synthesizing a
        // subclass's other inherited initializers as soon as one designated
        // initializer is overridden. Wiring it lazily here, idempotently,
        // sidesteps that entirely.
        if layoutManager?.delegate !== self { layoutManager?.delegate = self }
        guard let textStorage, !isCodeMode else { linkMatches = []; return }
        linkMatches = LinkShrink.matches(in: textStorage.string)
    }

    /// Swaps in the layout manager that draws backgrounds at text height.
    ///
    /// Call this on a freshly constructed view and nowhere else. Replacing a
    /// layout manager that has already laid text out leaves the new one's idea
    /// of the string stale, and the typesetter walks off the end of it the next
    /// time anything asks for a glyph. An empty view has nothing to go stale.
    ///
    /// It is a separate call rather than initializer work because overriding a
    /// designated initializer would take the plain `ChecklistTextView()` every
    /// other call site relies on down with it, the same trap documented on
    /// `recomputeLinkMatches`.
    func installBackgroundLayoutManager() {
        guard let textContainer, textStorage?.length ?? 0 == 0 else { return }
        textContainer.replaceLayoutManager(TextHeightBackgroundLayoutManager())
    }

    /// Folds every collapsed link's scheme and path out of the glyph stream
    /// entirely, rather than just coloring them invisible: color alone would
    /// still reserve their full width, leaving a blank gap where the hidden
    /// text used to be instead of actually shortening the line.
    ///
    /// This only sets the visible styling and forces glyphs to regenerate;
    /// which characters actually fold away is decided in
    /// `layoutManager(_:shouldGenerateGlyphs:...)` below, at the moment
    /// glyphs are built. Setting `notShownAttribute` directly here instead
    /// looked like it worked — it survives right up until the next layout
    /// pass silently regenerates those glyphs from scratch and the flag is
    /// gone, since nothing else tells AppKit which glyphs should stay hidden
    /// once it decides to rebuild them.
    ///
    /// `range` limits both the restyle and the glyph invalidation to the
    /// characters that changed (a link opening or folding, one edited line),
    /// so the rest of the note is not re-laid out; nil means the whole note.
    func applyLinkFolding(in range: NSRange? = nil) {
        guard let layoutManager, let textStorage else { return }
        let ns = textStorage.string as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let target = range.map { NSIntersectionRange($0, whole) } ?? whole

        for match in linkMatches {
            guard match.range.location + match.range.length <= ns.length else { continue }
            guard range == nil || NSIntersectionRange(match.range, target).length > 0 else { continue }
            let isExpanded = self.isExpanded(match)

            textStorage.addAttributes(
                [
                    .foregroundColor: ink.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: ink.link,
                ],
                range: isExpanded ? match.range : match.displayRange
            )
        }

        layoutManager.invalidateGlyphs(forCharacterRange: target, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: target, actualCharacterRange: nil)
    }

    /// Whether `characterIndex` falls inside a currently-collapsed link's
    /// hidden zone (the scheme and path around the domain that stays
    /// visible) or inside a heading's folded marker. Both re-derive from
    /// state kept fresh by the styling pass, since this runs during glyph
    /// generation, not on every keystroke.
    private func isCharacterFolded(_ characterIndex: Int, in text: NSString) -> Bool {
        for range in headingMarkers where NSLocationInRange(characterIndex, range) {
            return true
        }
        for range in highlightMarkers where NSLocationInRange(characterIndex, range) {
            return true
        }
        for range in emphasisMarkers where NSLocationInRange(characterIndex, range) {
            return true
        }
        for match in linkMatches {
            guard match.range.location + match.range.length <= text.length else { continue }
            guard characterIndex >= match.range.location, characterIndex < match.range.location + match.range.length else { continue }
            if isExpanded(match) { return false }
            let displayStart = match.displayRange.location
            let displayEnd = displayStart + match.displayRange.length
            return characterIndex < displayStart || characterIndex >= displayEnd
        }
        return false
    }

    /// The hook that actually makes folding stick: called every time AppKit
    /// (re)builds glyphs for a range, so a hidden character stays hidden
    /// across any future invalidation, not just the moment this happened to
    /// run once.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        // The marker arrays are already emptied for a code block by the
        // styling pass; the explicit guard says so at the point it matters,
        // since folding a character out of code would hide real content.
        guard !isCodeMode else { return 0 }
        guard !linkMatches.isEmpty || !headingMarkers.isEmpty || !highlightMarkers.isEmpty || !emphasisMarkers.isEmpty,
              let textStorage else { return 0 }
        let ns = textStorage.string as NSString

        var mutableProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var foldedOffsets: [Int] = []
        for i in 0..<glyphRange.length where isCharacterFolded(characterIndexes[i], in: ns) {
            // A control character, not `.null`: the typesetter skips null
            // glyphs outright, so a folded run at the start of a line was
            // never placed in that line at all. It got swept onto the end of
            // the previous line's fragment, which put the caret up there on a
            // fresh `# ` line and cost every heading after the first its
            // spacing above, since its fragment no longer started the
            // paragraph (#14). A control character is laid out where it
            // stands; `shouldUse` below gives it zero width.
            mutableProperties[i] = .controlCharacter
            foldedOffsets.append(i)
        }
        guard !foldedOffsets.isEmpty else { return 0 }

        layoutManager.setGlyphs(
            glyphs,
            properties: mutableProperties,
            characterIndexes: characterIndexes,
            font: font,
            forGlyphRange: glyphRange
        )
        // Zero advancement (from `shouldUse` below) collapses the width;
        // `notShownAttribute` keeps the glyph from ever being drawn, and it
        // can only be set once the glyph exists — which, now that
        // `setGlyphs` above has just created it, it does.
        for offset in foldedOffsets {
            layoutManager.setNotShownAttribute(true, forGlyphAt: glyphRange.location + offset)
        }
        return glyphRange.length
    }

    /// Folded markers arrive here as control characters (see above), and
    /// this is where they lose their width: zero advancement keeps each one
    /// in its own line fragment, at its own position, taking no room.
    /// Real control characters (newlines, tabs) keep AppKit's own action.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard !isCodeMode, let textStorage else { return action }
        let ns = textStorage.string as NSString
        guard charIndex < ns.length else { return action }
        // A line break is never folded: `isCharacterFolded` never claims
        // one, but guard anyway since breaking a line is the one action
        // that must survive whatever the marker ranges say.
        if action.contains(.paragraphBreak) || action.contains(.lineBreak) { return action }
        return isCharacterFolded(charIndex, in: ns) ? .zeroAdvancement : action
    }

    /// The match under `point`, hit-testing only the part currently on
    /// screen: the domain while collapsed, the whole URL once expanded.
    func linkMatch(at point: NSPoint) -> LinkMatch? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString

        for match in linkMatches {
            guard match.range.location + match.range.length <= ns.length else { continue }
            let isExpanded = self.isExpanded(match)
            let hitRange = isExpanded ? match.range : match.displayRange

            let glyphRange = layoutManager.glyphRange(forCharacterRange: hitRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textContainerInset.width
            rect.origin.y += textContainerInset.height
            if rect.contains(point) { return match }
        }
        return nil
    }

    /// The URL of whatever link is drawn under `point`, shrunk or not, or nil.
    /// Hit-tests the glyphs actually on screen, so the empty margin past the
    /// end of a line that happens to end in a link is not the link.
    func openableLink(at point: NSPoint) -> URL? {
        guard !isCodeMode, let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        guard ns.length > 0 else { return nil }

        // A collapsed link's hidden characters have no glyph width, so its
        // visible domain is the part to hit-test; `linkMatch` does exactly that.
        let index: Int
        if let match = linkMatch(at: point) {
            index = match.displayRange.location
        } else {
            let inContainer = NSPoint(
                x: point.x - textContainerInset.width,
                y: point.y - textContainerInset.height
            )
            let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
            guard glyph < layoutManager.numberOfGlyphs else { return nil }
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            guard glyphRect.contains(inContainer) else { return nil }
            index = layoutManager.characterIndexForGlyph(at: glyph)
        }
        return LinkShrink.link(containing: index, in: string)?.url
    }

    /// Whether the pointer should be the pointing hand: Cmd held over a link
    /// Cmd+click would actually open.
    func wantsLinkCursor(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.command), let url = openableLink(at: point) else { return false }
        return LinkShrink.isSafeToOpen(url)
    }

    private var showsLinkCursor = false
    private var linkCursorTrackingArea: NSTrackingArea?

    /// NSTextView's own tracking only reports what it needs for the I-beam,
    /// so this view asks for mouse-moved events of its own.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkCursorTrackingArea { removeTrackingArea(linkCursorTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        linkCursorTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateLinkCursor(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    /// Pressing or releasing Cmd with the pointer already resting on a link
    /// changes the cursor without waiting for the mouse to move.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateLinkCursor(at: point, modifiers: event.modifierFlags)
    }

    /// Leaving the view drops the hand at once rather than leaving it
    /// stuck on whatever the pointer moves over next.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if showsLinkCursor {
            NSCursor.arrow.set()
            showsLinkCursor = false
        }
    }

    private func updateLinkCursor(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        if wantsLinkCursor(at: point, modifiers: modifiers) {
            NSCursor.pointingHand.set()
            showsLinkCursor = true
        } else if showsLinkCursor {
            NSCursor.iBeam.set()
            showsLinkCursor = false
        }
    }

    // MARK: - Styling

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isStyling, editedMask.contains(.editedCharacters) else { return }
        let codeModeChanged = codeModeDidChange()
        applyListModeIfNeeded()
        // Title styling spans the first line, which an edit anywhere can change
        // the extent of, so restyle the whole note when that mode is on. The
        // same goes for the edit that adds or removes the code keyword: every
        // other line has to pick up (or drop) the code treatment.
        //
        // Below the title/code cases, restyling still can't stop at
        // `editedRange` alone: `Emphasis.matches` threads a math environment
        // top to bottom, so a variable defined or removed here can flip
        // whether a LATER line reads as math or as emphasis, and that later
        // line's font never gets touched unless it's inside this pass's
        // target too. Emphasis-styled content is the only thing that depends
        // on an earlier line this way, so the target widens to the rest of
        // the note — never backward, since nothing here looks upward — rather
        // than paying for a full-note restyle on every keystroke.
        let target: NSRange?
        if stylesFirstLineAsTitle || codeModeChanged {
            target = nil
        } else {
            target = NSRange(location: editedRange.location, length: textStorage.length - editedRange.location)
        }
        applyChecklistStyling(in: target)
        recomputeMathResults()
        recomputeLinkMatches()
        // Deferred like `applyListModeIfNeeded`: folding forces glyph
        // generation, and the text storage is still inside its own
        // beginEditing/endEditing bracket here — AppKit raises
        // NSInternalInconsistencyException if glyph generation is forced
        // before that bracket closes.
        DispatchQueue.main.async { [weak self] in self?.applyLinkFolding() }
        needsDisplay = true
    }

    /// Restyles the lines touching `range`, or the whole note when nil.
    ///
    /// Attribute-only changes are safe to make from didProcessEditing, which is
    /// why this never adds or removes characters.
    func applyChecklistStyling(in range: NSRange? = nil) {
        guard let textStorage, !isStyling else { return }
        isStyling = true
        defer { isStyling = false }

        let ns = textStorage.string as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let target = ns.length == 0 ? whole : ns.lineRange(for: clamped(range ?? whole))

        let isCode = isCodeMode
        var baseline: [NSAttributedString.Key: Any] = [
            .font: isCode ? codeFont : baseFont,
            .foregroundColor: ink.text,
            .paragraphStyle: paragraphStyle,
        ]
        // Kern 0 is the same as no kern, so it only goes on when asked for.
        if letterSpacing != 0 {
            baseline[.kern] = letterSpacing
        }
        textStorage.setAttributes(baseline, range: target)

        // A code block is plain monospaced text and nothing else: every parser
        // below this point stays out of it, and the marker positions glyph
        // generation folds against are emptied so no marker folds either. The
        // keyword line is painted the same pale way list mode paints its own.
        if isCode {
            if ns.length > 0 {
                let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
                let marker = NSIntersectionRange(firstLine, target)
                if marker.length > 0 {
                    textStorage.addAttribute(.foregroundColor, value: ink.secondary, range: marker)
                }
            }
            highlightMarkers = []
            headingMarkers = []
            emphasisMarkers = []
            return
        }

        if Checklist.isListMode(ns as String, keyword: listKeyword), ns.length > 0 {
            let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
            let marker = NSIntersectionRange(firstLine, target)
            if marker.length > 0 {
                textStorage.addAttribute(.foregroundColor, value: ink.secondary, range: marker)
            }
        }

        if stylesFirstLineAsTitle, ns.length > 0 {
            let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
            let firstLineText = ns.substring(with: firstLine)
            // An explicit first-line heading beats the automatic title: it
            // sizes itself by its own level below, and piling the title
            // treatment on top would flatten the distinction the user just
            // wrote. The heading text still serves as the title everywhere
            // one is shown (see `Note.title`).
            if Heading.parse(firstLineText) == nil {
                let titleRange = NSIntersectionRange(firstLine, target)
                if titleRange.length > 0 {
                    textStorage.addAttribute(
                        .font,
                        value: titleFont,
                        range: titleRange
                    )
                }
            }
        }

        ns.enumerateSubstrings(in: target, options: [.byLines]) { line, lineRange, _, _ in
            guard let line else { return }

            if let heading = Heading.parse(line) {
                let style = NSMutableParagraphStyle()
                style.lineHeightMultiple = CGFloat(self.lineHeightMultiple)
                // Room above a heading so it reads as its own section; the
                // very first line keeps its inset instead of pushing down.
                if lineRange.location > 0 {
                    // Shrinking gaps down to a floor: past level 4 the deeper
                    // levels sit close together on purpose, since a run of
                    // them is usually one dense subsection rather than four
                    // separate ones.
                    style.paragraphSpacingBefore = [CGFloat(18), 12, 8, 6, 6, 6][heading.level - 1]
                }
                let face = self.headingFont(heading)
                // Held to the height the regular face at this size gives
                // the line, for the same reason `holdLineHeight` holds a
                // bold word's line: Helvetica Neue and American Typewriter
                // draw Bold a point taller than Regular, so a `#### ` line,
                // which has no size lift, would push every line below it
                // down by that point on top of its own spacing.
                if face.font != face.regular {
                    let natural = Self.typesetLineHeight(of: face.regular, multiple: style.lineHeightMultiple)
                    let bolded = Self.typesetLineHeight(of: face.font, multiple: style.lineHeightMultiple)
                    if bolded > natural + 0.01 {
                        // TextKit adds the font's leading after clamping to
                        // the maximum, so the cap leaves room for it.
                        style.maximumLineHeight = natural - face.font.leading
                    }
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: face.font, .paragraphStyle: style]
                if face.needsSyntheticStroke {
                    attributes[.strokeWidth] = NoteFont.syntheticBoldStrokeWidth
                }
                textStorage.addAttributes(attributes, range: lineRange)
                return
            }

            // Ordered-list markers are painted the way checkbox markers are —
            // visible in the file, styled on screen — but bold rather than
            // pale, since the number IS the content here and there is no
            // checked state to reserve the accent for.
            if let ordered = OrderedList.item(in: line) {
                let markerRange = NSRange(
                    location: lineRange.location + ordered.markerRange.location,
                    length: ordered.markerRange.length
                )
                // The same real Bold `**bold**` gets (see `NoteFont.bold(of:)`),
                // not the font manager's Semibold, and a stroke in Monaco.
                let bold = NoteFont.bold(of: self.baseFont)
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: self.ink.secondary,
                    .font: bold.font,
                ]
                if bold.needsSyntheticStroke {
                    attributes[.strokeWidth] = NoteFont.syntheticBoldStrokeWidth
                }
                textStorage.addAttributes(attributes, range: markerRange)
                self.holdLineHeight(of: ns.lineRange(for: lineRange), boldSpans: [markerRange], in: textStorage)
                return
            }

            // An image line is given the height of its image, and the markdown
            // that produced it is painted out. The characters are still there
            // on disk, but the editor treats the whole reference as one
            // character (see "Images as single characters"), so a caret can
            // never sit inside the hidden path.
            let references = Attachments.references(in: line)
            if !references.isEmpty {
                var tallest: CGFloat = 0
                for reference in references {
                    guard let image = Attachments.image(at: reference.path) else { continue }
                    let width = reference.width ?? Attachments.defaultWidth(for: image)
                    tallest = max(tallest, width * (image.size.height / max(1, image.size.width)))

                    textStorage.addAttribute(
                        .foregroundColor,
                        value: NSColor.clear,
                        range: NSRange(
                            location: lineRange.location + reference.range.location,
                            length: reference.range.length
                        )
                    )
                }
                if tallest > 0 {
                    let style = NSMutableParagraphStyle()
                    style.minimumLineHeight = tallest + 6
                    style.maximumLineHeight = tallest + 6
                    // Min/max line height applies to every line fragment of
                    // the paragraph, not just the first. A reference is ~60
                    // characters, wider than a narrow note, so it used to
                    // wrap, and each wrapped piece of invisible markdown got
                    // its own image-tall line: a blank gap under the picture
                    // that Down arrow and double-click landed in (issue #10).
                    // A line holding nothing but references is laid out as a
                    // single line instead. A line mixing text and an image
                    // keeps wrapping so its visible text is never clipped.
                    if Self.isImageOnlyLine(line, references: references) {
                        style.lineBreakMode = .byClipping
                    }
                    textStorage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                }
            }

            guard let item = Checklist.item(in: line) else { return }

            let markerRange = NSRange(
                location: lineRange.location + item.markerRange.location,
                length: item.markerRange.length
            )
            textStorage.addAttribute(
                .foregroundColor,
                value: item.isChecked ? self.ink.accent : self.ink.secondary,
                range: markerRange
            )

            guard item.isChecked else { return }
            let bodyStart = markerRange.location + markerRange.length
            let bodyLength = lineRange.location + lineRange.length - bodyStart
            guard bodyLength > 0 else { return }

            textStorage.addAttributes(
                [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: self.ink.secondary,
                    .foregroundColor: self.ink.secondary,
                ],
                range: NSRange(location: bodyStart, length: bodyLength)
            )
        }

        // Highlights are found over the whole note, like headings just below,
        // but only the part of each span that falls inside `target` gets its
        // background repainted — the same "only the touched lines" discipline
        // the rest of this pass follows, since `setAttributes(baseline...)`
        // above already wiped whatever background used to be there.
        let highlights = Highlight.matches(in: ns)
        for highlight in highlights {
            let content = NSIntersectionRange(highlight.contentRange, target)
            guard content.length > 0 else { continue }
            textStorage.addAttribute(.backgroundColor, value: Highlight.backgroundColor, range: content)
        }
        highlightMarkers = highlights.flatMap { $0.markerRanges }

        // Emphasis runs after everything above it on purpose: it restyles the
        // font each run is already carrying rather than deriving one from
        // `baseFont`, so `## text with **bold**` keeps its heading size and
        // only gains the weight, and a bold word on the auto-title line stays
        // title-sized. Whatever painted that font has to have painted it first.
        let emphases = Emphasis.matches(in: ns)
        var boldLines: [NSRange] = []
        for emphasis in emphases {
            let content = NSIntersectionRange(emphasis.contentRange, target)
            guard content.length > 0 else { continue }
            if emphasis.kind == .strong {
                let line = ns.lineRange(for: content)
                if boldLines.last != line { boldLines.append(line) }
            }
            applyEmphasis(emphasis.kind, to: content, in: textStorage)
        }
        let boldSpans = emphases.filter { $0.kind == .strong }.map(\.contentRange)
        for line in boldLines {
            holdLineHeight(of: line, boldSpans: boldSpans, in: textStorage)
        }
        emphasisMarkers = emphases.flatMap { $0.markerRanges }

        // Fresh positions for the folding pass: glyph generation asks about
        // arbitrary characters and has to fold against where the markers sit
        // *now*, not where they sat before this edit.
        headingMarkers = Heading.markerRanges(in: ns)
    }

    /// Where the current note's heading markers are, in string coordinates.
    /// Recomputed by every styling pass; read by glyph generation.
    private(set) var headingMarkers: [NSRange] = []

    /// Where the current note's `==...==` highlight markers are, in string
    /// coordinates. Recomputed by every styling pass; read by glyph
    /// generation, same as `headingMarkers`.
    private(set) var highlightMarkers: [NSRange] = []

    /// Where the current note's `**`, `*` and `` ` `` markers are, in string
    /// coordinates. Recomputed by every styling pass; read by glyph
    /// generation, same as `headingMarkers`.
    private(set) var emphasisMarkers: [NSRange] = []

    /// Restyles one emphasis span's content in place.
    ///
    /// Enumerating the existing `.font` rather than starting from `baseFont`
    /// is what lets bold inside a heading stay heading-sized: the trait is
    /// added to whatever is already there. A run that somehow carries no font
    /// falls back to the body one rather than being skipped.
    private func applyEmphasis(_ kind: Emphasis.Kind, to range: NSRange, in textStorage: NSTextStorage) {
        let manager = NSFontManager.shared
        textStorage.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
            let current = (value as? NSFont) ?? self.baseFont
            switch kind {
            case .strong:
                // See `NoteFont.bold(of:)` for why this is not the font
                // manager's own bold conversion.
                let bold = NoteFont.bold(of: current)
                textStorage.addAttribute(.font, value: bold.font, range: runRange)
                if bold.needsSyntheticStroke {
                    textStorage.addAttribute(.strokeWidth, value: NoteFont.syntheticBoldStrokeWidth, range: runRange)
                }
            case .emphasis:
                let italic = manager.convert(current, toHaveTrait: .italicFontMask)
                // Plenty of fixed-pitch faces have no italic cut, SF Mono among
                // them, and that is the default note font. `convert` hands back
                // the upright face unchanged in that case, which would fold the
                // asterisks away and put nothing at all in their place. Colour
                // carries the emphasis instead rather than losing it.
                if manager.traits(of: italic).contains(.italicFontMask) {
                    textStorage.addAttribute(.font, value: italic, range: runRange)
                } else {
                    textStorage.addAttribute(.foregroundColor, value: self.ink.accent, range: runRange)
                }
            case .code:
                // The same reasoning as `codeFont`: a note already set in a
                // fixed-pitch face keeps its own rather than being pushed onto
                // the system mono, and the wash carries the signal instead.
                let mono = current.isFixedPitch
                    ? current
                    : NSFont.monospacedSystemFont(ofSize: current.pointSize, weight: .regular)
                textStorage.addAttributes(
                    [.font: mono, .backgroundColor: Emphasis.codeBackgroundColor],
                    range: runRange
                )
            }
        }
    }

    /// Keeps a line holding bold text exactly as tall as it would be
    /// without it.
    ///
    /// A few families draw their Bold with taller vertical metrics than
    /// their Regular (Helvetica Neue and American Typewriter Bold are a point
    /// taller at 13pt), so a word turning bold would push every line below
    /// it down. Capping the paragraph's maximum line height at the natural
    /// height the line had before (each bold run measured as the face it was
    /// derived from) takes that jump away and leaves only the glyphs' own
    /// width change. Lines that already carry a fixed height (images) are
    /// left alone, and a line whose bold is no taller gets no cap at all.
    private static let lineHeightMeasure = NSLayoutManager()

    private func holdLineHeight(of line: NSRange, boldSpans: [NSRange], in textStorage: NSTextStorage) {
        let measure = Self.lineHeightMeasure
        var natural: CGFloat = 0
        var bolded: CGFloat = 0
        textStorage.enumerateAttribute(.font, in: line, options: []) { value, runRange, _ in
            let font = (value as? NSFont) ?? self.baseFont
            let height = measure.defaultLineHeight(for: font)
            bolded = max(bolded, height)
            let isBold = boldSpans.contains { NSIntersectionRange($0, runRange).length > 0 }
            // A bold run is measured as its family's non-bold face, standing
            // in for the font it carried before `applyEmphasis` ran.
            natural = max(natural, isBold ? measure.defaultLineHeight(for: self.unbolded(font)) : height)
        }
        guard bolded > natural + 0.01 else { return }
        let existing = (textStorage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)
            ?? paragraphStyle
        guard existing.maximumLineHeight == 0 else { return }
        let style = (existing.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        let multiple = style.lineHeightMultiple > 0 ? style.lineHeightMultiple : 1
        style.maximumLineHeight = natural * multiple
        textStorage.addAttribute(.paragraphStyle, value: style, range: line)
    }

    /// How tall TextKit actually makes a one-line paragraph set in `font`.
    ///
    /// `defaultLineHeight(for:)` rounds its estimate differently from the
    /// typesetter: Helvetica Neue at 19pt reports 23 but lays out at 22.53,
    /// so a cap derived from it held nothing back. Measured once per face
    /// and multiple, since a styling pass can ask for every heading line.
    private static var typesetHeights: [String: CGFloat] = [:]

    static func typesetLineHeight(of font: NSFont, multiple: CGFloat) -> CGFloat {
        let key = "\(font.fontName) \(font.pointSize) \(multiple)"
        if let known = typesetHeights[key] { return known }
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = multiple
        let storage = NSTextStorage(string: "Hg", attributes: [.font: font, .paragraphStyle: style])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 10_000, height: 10_000))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let height = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
        typesetHeights[key] = height
        return height
    }

    /// The same family and size at the weight a note's text would carry if
    /// it were not bold: regular for body text, or the heading weight.
    private func unbolded(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
    }

    /// A heading's face: `font` to draw it in, `regular` the same family at
    /// the same size without the weight (what its line height is held to),
    /// and whether the weight has to come from a stroke instead.
    struct HeadingFace {
        let font: NSFont
        let regular: NSFont
        let needsSyntheticStroke: Bool
    }

    /// Headings step up from the note's own font, so a typewriter note gets
    /// bold typewriter headings rather than a system-font intruder.
    ///
    /// Bold is `NoteFont.bold(of:)`, the same as `**bold**`: the font
    /// manager's bold trait lands on Semibold in SF Mono, New York and SF
    /// Rounded, and on nothing at all in Monaco.
    func headingFont(_ heading: Heading) -> HeadingFace {
        // Size carries the top of the hierarchy and weight carries the bottom.
        // Level 3 is the hinge: the last level that gets any lift, and the one
        // that trades bold away so it cannot be mistaken for a level 2. Below
        // it nothing grows, because a scratchpad cannot hold six distinct
        // sizes and a heading that renders smaller than body text looks broken.
        let lift: CGFloat = [6.0, 3.5, 1.5, 0.0, 0.0, 0.0][heading.level - 1]
        let manager = NSFontManager.shared
        let sized = manager.convert(baseFont, toSize: baseFont.pointSize + lift)
        guard heading.level != 3 else {
            return HeadingFace(font: sized, regular: sized, needsSyntheticStroke: false)
        }
        let bold = NoteFont.bold(of: sized)
        return HeadingFace(font: bold.font, regular: sized, needsSyntheticStroke: bold.needsSyntheticStroke)
    }
}

/// Plain-text editor backed by `NSTextView`.
///
/// SwiftUI's `TextEditor` exposes neither the caret position nor scroll events,
/// which made per-line checklist toggling and swipe navigation impossible.
struct PlainTextEditor: NSViewRepresentable {
    var lineHeightMultiple: Double = 1.0
    var baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var letterSpacing: Double = 0
    var ink: InkTheme = .system
    var guide: PaperGuide = .none
    var listKeyword: String = "list"
    var codeKeyword: String = CodeBlock.defaultKeyword
    /// Extra room at the top when the header bar is hidden, so the first line
    /// clears the traffic lights instead of tucking under them.
    var topInset: CGFloat = 12
    @Binding var text: String
    @Binding var selectedRange: NSRange
    /// Set by global search to jump to a specific match. Consumed and reset
    /// to nil in `updateNSView` once applied, so it fires exactly once per
    /// selection rather than re-scrolling on every unrelated update.
    @Binding var scrollTarget: NSRange?
    var onSwipe: (SwipeDirection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SwipeScrollView {
        let scrollView = SwipeScrollView()
        scrollView.onSwipe = onSwipe
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        // With the header hidden, this scroll view's top edge sits flush with
        // the window's own top edge, under the transparent titlebar — exactly
        // the case AppKit's automatic content-inset exists for, so it adds its
        // own top inset to clear the traffic lights on top of the `topInset`
        // already passed in for that same purpose. Doubled, not missing: the
        // gap this produces is nearly 3x the intended one. `topInset` already
        // covers it by hand (12pt with the header showing, 38pt without), so
        // AppKit's own pass needs to stay out of it.
        scrollView.automaticallyAdjustsContentInsets = false

        let textView = ChecklistTextView()
        textView.installBackgroundLayoutManager()
        textView.delegate = context.coordinator

        // Plain text, and nothing that rewrites what you typed.
        textView.isRichText = false
        // `isRichText = false` doesn't remove the standard "Font ▸ Show
        // Fonts…" contextual-menu item on its own — that one's gated by
        // `usesFontPanel`, which defaults to true independent of rich-text
        // status. Left alone, it opens the system Font Panel and lets you
        // pick any per-selection font, which then vanishes on the very next
        // keystroke: every note-type feature here (headings, checklists,
        // highlights) repaints font/color attributes across the whole note
        // on every edit, so a manual pick was never going to survive one.
        // Rather than build real per-run rich text to make that panel
        // actually work — which would break the plain-text-is-the-file
        // model everywhere else — the honest fix is to stop offering
        // something that only pretends to work.
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: topInset)

        // Native in-note search. The Find menu items drive this through the
        // responder chain, giving real match highlighting and next/previous
        // rather than a hand-rolled search bar.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.lineHeightMultiple = lineHeightMultiple
        textView.baseFont = baseFont
        textView.letterSpacing = letterSpacing
        textView.listKeyword = listKeyword
        textView.codeKeyword = codeKeyword
        // The ink assignment repaints text and caret itself; the labelColor
        // above only covers the moment before it.
        textView.ink = ink
        textView.guide = guide
        textView.textStorage?.delegate = textView
        textView.enableImageDrops()
        textView.enableHeaderToggleButtons()
        textView.string = text
        textView.applyChecklistStyling()
        textView.recomputeMathResults()
        textView.recomputeLinkMatches()
        textView.applyLinkFolding()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: SwipeScrollView, context: Context) {
        context.coordinator.parent = self
        scrollView.onSwipe = onSwipe

        guard let textView = scrollView.documentView as? ChecklistTextView else { return }

        if textView.textContainerInset.height != topInset {
            textView.textContainerInset = NSSize(width: 20, height: topInset)
        }

        if textView.listKeyword != listKeyword {
            textView.listKeyword = listKeyword
        }
        if textView.codeKeyword != codeKeyword {
            textView.codeKeyword = codeKeyword
        }

        if textView.lineHeightMultiple != lineHeightMultiple {
            textView.lineHeightMultiple = lineHeightMultiple
            textView.applyChecklistStyling()
        }

        // Both fire their own restyle in didSet, so only touch them on a
        // real change.
        if textView.baseFont != baseFont {
            textView.baseFont = baseFont
        }
        if textView.letterSpacing != letterSpacing {
            textView.letterSpacing = letterSpacing
        }
        if textView.ink != ink {
            textView.ink = ink
        }
        if textView.guide != guide {
            textView.guide = guide
        }

        // Only touch the text view when the model genuinely diverged (note
        // switch). Assigning unconditionally would fight the user's typing and
        // reset undo on every keystroke.
        if textView.string != text {
            textView.loadNoteText(text)
        }

        // Runs after the text-diff block above, so a jump into a different
        // note lands against that note's already-current string rather than
        // the one it's replacing.
        if let target = scrollTarget {
            let length = (textView.string as NSString).length
            if target.location != NSNotFound, target.location <= length {
                let safeRange = NSRange(
                    location: target.location,
                    length: min(target.length, length - target.location)
                )
                textView.scrollRangeToVisible(safeRange)
                textView.setSelectedRange(safeRange)
                textView.showFindIndicator(for: safeRange)
            }
            DispatchQueue.main.async { self.scrollTarget = nil }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor

        init(_ parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.selectedRange = textView.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selectedRange = textView.selectedRange()
        }
    }
}
