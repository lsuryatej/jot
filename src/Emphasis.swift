import AppKit
import Foundation

/// Inline `**bold**`, `*italic*` and `` `code` `` spans — the three markers
/// that arrive by the hundred when AI chat output gets pasted into a note.
///
/// Same trade as every other marker in this app: the asterisks and backticks
/// stay in the file, so the note is still plain markdown in `cat` and still
/// renders everywhere else, and only the marker characters fold out of the
/// display, leaving the wrapped text styled in their place.
///
/// Underscore emphasis is deliberately absent. `_foo_` and `__foo__` are
/// legal markdown, but these notes are full of `some_var_name`, and an
/// identifier silently turning italic halfway through is a worse outcome
/// than an underscore pair staying literal.
struct Emphasis: Equatable {
    enum Kind: Equatable {
        case strong
        case emphasis
        case code
    }

    /// The wash behind inline code. Monospacing alone is too quiet a signal
    /// at body size, especially when the note's own font is already fixed
    /// pitch and the switch changes nothing at all. Kept neutral and very
    /// translucent so it reads as a tint on whatever paper is underneath
    /// rather than as a second highlighter competing with `Highlight`.
    static let codeBackgroundColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.16)

    let kind: Kind
    /// The whole span, both markers included.
    let range: NSRange
    /// The two marker spans that fold out of the glyph stream, opening first.
    let markerRanges: [NSRange]
    /// What actually gets styled.
    let contentRange: NSRange

    /// Every emphasis span in `text`, in whole-string coordinates, sorted by
    /// position.
    ///
    /// Computed over the whole note at once, like `Heading.markerRanges` and
    /// `Highlight.matches`, because glyph generation asks about arbitrary
    /// characters without knowing what line they're on.
    static func matches(in text: NSString) -> [Emphasis] {
        matches(in: text, respectingMath: true)
    }

    /// `respectingMath: false` is only for checking that a marker pair the
    /// Cmd+B / Cmd+I shortcut is about to write is well formed. Rendering
    /// always respects math.
    private static func matches(in text: NSString, respectingMath: Bool) -> [Emphasis] {
        var results: [Emphasis] = []
        var environment: [String: MathExpression.Value] = [:]
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line else { return }
            // On a line with something in the margin, `*` is multiplication:
            // folding `2*3*4` would show `234` next to a result of 24.
            guard !respectingMath || !showsMathResult(line, environment: &environment) else { return }
            let lineNS = line as NSString
            // Code first, and the emphasis pass is told to stay out of what it
            // found: inside backticks an asterisk is a character someone meant
            // to type, not a marker.
            let code = codeSpans(in: lineNS)
            var spans = code
            spans.append(contentsOf: emphasisSpans(in: lineNS, avoiding: code.map { $0.range }))
            spans.sort { $0.range.location < $1.range.location }
            results.append(contentsOf: spans.map { $0.offset(by: lineRange.location) })
        }
        return results
    }

    // MARK: - Cmd+B / Cmd+I

    /// One replacement that toggles a marker pair: apply `replacement` over
    /// `range` in a single edit (so it is one undo step), then select
    /// `selection`.
    struct ToggleEdit: Equatable {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    /// What Cmd+B (`.strong`) or Cmd+I (`.emphasis`) does to `text` given the
    /// current `selection`, or nil when it should do nothing.
    ///
    /// - A selection, or a caret, inside a rendered span of the same kind
    ///   unwraps that span. "Inside" includes the markers, so selecting just
    ///   the bold word and selecting `**word**` whole both unwrap.
    /// - A selection is otherwise wrapped, after trimming whitespace off both
    ///   ends: the parser needs a non-space character just inside each
    ///   marker, so `** two **` would never render as bold.
    /// - A caret strictly inside a word wraps that word, the way Typora and
    ///   VS Code's Markdown All in One behave. Anywhere else an empty pair is
    ///   inserted with the caret between, and pressing again on that empty
    ///   pair takes it back out.
    ///
    /// Like `toggleHighlight`, a wrap is only committed when the parser would
    /// read the result back as exactly that span; otherwise nothing changes.
    /// That refuses selections crossing a line, reaching into inline code, or
    /// italic inside bold (`***word***` has no reading here). The check
    /// ignores math, so a word on a math line can still be wrapped on
    /// request, but unwrapping only ever acts on spans that actually render,
    /// which keeps the `*` operators in `2*3*4` out of reach.
    static func toggle(_ kind: Kind, in text: NSString, selection: NSRange) -> ToggleEdit? {
        guard kind != .code else { return nil }
        let marker = kind == .strong ? "**" : "*"
        let markerLength = (marker as NSString).length
        guard selection.location >= 0, NSMaxRange(selection) <= text.length else { return nil }

        var target = selection
        if target.length > 0 {
            target = trimmingWhitespace(target, in: text)
            guard target.length > 0 else { return nil }
        }

        // Unwrap.
        let rendered = matches(in: text).filter { $0.kind == kind }
        let enclosing = rendered.first { span in
            if target.length == 0 {
                return target.location > span.range.location && target.location < NSMaxRange(span.range)
            }
            return target.location >= span.range.location && NSMaxRange(target) <= NSMaxRange(span.range)
        }
        if let span = enclosing {
            let content = text.substring(with: span.contentRange)
            let contentLength = span.contentRange.length
            let newSelection: NSRange
            if target.length == 0 {
                let shifted = target.location - (span.contentRange.location - span.range.location)
                newSelection = NSRange(
                    location: min(max(span.range.location, shifted), span.range.location + contentLength),
                    length: 0
                )
            } else {
                newSelection = NSRange(location: span.range.location, length: contentLength)
            }
            return ToggleEdit(range: span.range, replacement: content, selection: newSelection)
        }

        if target.length == 0 {
            let caret = target.location
            // An empty pair the caret is sitting in, most likely the one the
            // last press inserted: remove it.
            if starRun(endingAt: caret, in: text) == markerLength,
               starRun(in: text, from: caret) == markerLength {
                return ToggleEdit(
                    range: NSRange(location: caret - markerLength, length: markerLength * 2),
                    replacement: "",
                    selection: NSRange(location: caret - markerLength, length: 0)
                )
            }
            if let word = word(around: caret, in: text) {
                return wrapped(word, with: marker, kind: kind, in: text,
                               selection: NSRange(location: caret + markerLength, length: 0))
            }
            return ToggleEdit(
                range: target,
                replacement: marker + marker,
                selection: NSRange(location: caret + markerLength, length: 0)
            )
        }

        return wrapped(target, with: marker, kind: kind, in: text,
                       selection: NSRange(location: target.location + markerLength, length: target.length))
    }

    /// Wraps `range`, but only if the parser would read the result back as a
    /// span of `kind` over exactly `range`'s text.
    private static func wrapped(_ range: NSRange, with marker: String, kind: Kind, in text: NSString, selection: NSRange) -> ToggleEdit? {
        let markerLength = (marker as NSString).length
        let replacement = marker + text.substring(with: range) + marker
        let result = text.replacingCharacters(in: range, with: replacement) as NSString
        let expected = NSRange(location: range.location + markerLength, length: range.length)
        guard matches(in: result, respectingMath: false).contains(where: { $0.kind == kind && $0.contentRange == expected })
        else { return nil }
        return ToggleEdit(range: range, replacement: replacement, selection: selection)
    }

    private static func trimmingWhitespace(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(text.character(at: start)) { start += 1 }
        while end > start, isWhitespace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// The word the caret is strictly inside, or nil when the caret is at a
    /// word's edge or not touching one.
    private static func word(around caret: Int, in text: NSString) -> NSRange? {
        guard caret > 0, caret < text.length,
              isWordCharacter(text.character(at: caret - 1)),
              isWordCharacter(text.character(at: caret))
        else { return nil }
        var start = caret
        while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < text.length, isWordCharacter(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func starRun(endingAt end: Int, in text: NSString) -> Int {
        var index = end
        while index > 0, text.character(at: index - 1) == star { index -= 1 }
        return end - index
    }

    /// Mirrors `ChecklistTextView.recomputeMathResults`, including carrying
    /// variables down the note, so the two agree on which lines are math.
    private static func showsMathResult(_ line: String, environment: inout [String: MathExpression.Value]) -> Bool {
        guard let node = MathExpression.parse(line) else { return false }
        switch MathExpression.evaluate(node, environment: &environment) {
        case .success: return true
        case .failure(let error): return MathExpression.hint(for: error) != nil
        }
    }

    // MARK: - Scanning

    private static let star: unichar = 42
    private static let backtick: unichar = 96

    /// Backtick pairs, matched left to right and shortest-first. A lone
    /// backtick with no partner, and an empty `` `` `` pair, both stay
    /// literal — nothing folds unless there is something between the marks
    /// worth folding for.
    private static func codeSpans(in line: NSString) -> [Emphasis] {
        var spans: [Emphasis] = []
        var index = 0
        while index < line.length {
            guard line.character(at: index) == backtick else {
                index += 1
                continue
            }
            var end = index + 1
            while end < line.length, line.character(at: end) != backtick { end += 1 }
            guard end < line.length, end > index + 1 else {
                index += 1
                continue
            }
            spans.append(Emphasis(
                kind: .code,
                range: NSRange(location: index, length: end - index + 1),
                markerRanges: [NSRange(location: index, length: 1), NSRange(location: end, length: 1)],
                contentRange: NSRange(location: index + 1, length: end - index - 1)
            ))
            index = end + 1
        }
        return spans
    }

    /// Asterisk pairs. A run of two or more is always read as `**`, so
    /// `**bold**` can never come out as an italic wrapping `*bold*`.
    ///
    /// Nesting is not attempted: in `**outer *inner* outer**` the inner pair
    /// is part of the strong span's content and stays on screen as literal
    /// asterisks. Markdown nesting is rare in pasted chat output and the
    /// bookkeeping to fold two overlapping marker sets is not worth it.
    private static func emphasisSpans(in line: NSString, avoiding code: [NSRange]) -> [Emphasis] {
        var spans: [Emphasis] = []
        var index = 0
        while index < line.length {
            guard line.character(at: index) == star, !isInside(index, code) else {
                index += 1
                continue
            }
            let runLength = starRun(in: line, from: index)
            let markerLength = runLength >= 2 ? 2 : 1
            let contentStart = index + markerLength

            // The character right after the opening marker decides whether
            // this is a marker at all. `* a bullet item` has a space there,
            // and so does the stray asterisk in `a * b * c`; neither is
            // emphasis, and neither should quietly eat the rest of the line.
            guard contentStart < line.length, isContentCharacter(line.character(at: contentStart)) else {
                index += runLength
                continue
            }

            guard let close = closingRun(in: line, from: contentStart, markerLength: markerLength, avoiding: code) else {
                // No partner on this line, so the marker is just text the
                // note happens to contain.
                index += runLength
                continue
            }

            let whole = NSRange(location: index, length: close + markerLength - index)
            // A pair that reaches across a code span loses to it, same rule
            // as an asterisk sitting inside one.
            if !code.contains(where: { NSIntersectionRange($0, whole).length > 0 }) {
                spans.append(Emphasis(
                    kind: markerLength == 2 ? .strong : .emphasis,
                    range: whole,
                    markerRanges: [
                        NSRange(location: index, length: markerLength),
                        NSRange(location: close, length: markerLength),
                    ],
                    contentRange: NSRange(location: contentStart, length: close - contentStart)
                ))
            }
            index = close + markerLength
        }
        return spans
    }

    /// The first asterisk run after `contentStart` that can close a marker of
    /// `markerLength`: long enough, outside code, and with real content in
    /// front of it rather than a space.
    private static func closingRun(in line: NSString, from contentStart: Int, markerLength: Int, avoiding code: [NSRange]) -> Int? {
        var index = contentStart
        while index < line.length {
            guard line.character(at: index) == star else {
                index += 1
                continue
            }
            if isInside(index, code) {
                index += 1
                continue
            }
            let runLength = starRun(in: line, from: index)
            if runLength >= markerLength, index > contentStart, isContentCharacter(line.character(at: index - 1)) {
                return index
            }
            index += runLength
        }
        return nil
    }

    private static func starRun(in line: NSString, from start: Int) -> Int {
        var index = start
        while index < line.length, line.character(at: index) == star { index += 1 }
        return index - start
    }

    /// What is allowed to sit immediately inside a marker. Excluding the
    /// asterisk itself is what makes `****` and `***` nothing at all rather
    /// than a span wrapped around a leftover marker character.
    private static func isContentCharacter(_ character: unichar) -> Bool {
        guard character != star else { return false }
        guard let scalar = Unicode.Scalar(character) else { return true }
        return !CharacterSet.whitespaces.contains(scalar)
    }

    private static func isInside(_ index: Int, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(index, $0) }
    }

    private func offset(by delta: Int) -> Emphasis {
        Emphasis(
            kind: kind,
            range: NSRange(location: range.location + delta, length: range.length),
            markerRanges: markerRanges.map { NSRange(location: $0.location + delta, length: $0.length) },
            contentRange: NSRange(location: contentRange.location + delta, length: contentRange.length)
        )
    }
}
