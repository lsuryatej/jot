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
        var results: [Emphasis] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line else { return }
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
