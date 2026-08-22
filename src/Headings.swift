import Foundation

/// A markdown heading at the start of a line: one to three `#`s, then a
/// space, then the heading text.
///
/// Same trade as the checkbox markers: the hashes stay in the file, so it
/// stays readable in `cat` and renders as real headings everywhere else, and
/// the app styles only lines that genuinely carry them. Strict on input —
/// four or more hashes has no level here and neither does a hash with no
/// space, so `####` and `#hashtag` are ordinary text. Leading whitespace
/// disqualifies too, matching markdown.
struct Heading: Equatable {
    let level: Int
    /// Hashes plus the single space after them: the exact span the display
    /// folds away while the file keeps every character.
    let markerLength: Int

    static func parse(_ line: String) -> Heading? {
        var depth = 0
        var offset = 0
        for character in line {
            if character == "#" {
                // Hashes must lead the line; anything before them, or past
                // the third, means this was never a heading.
                if offset != depth { return nil }
                depth += 1
                if depth > 3 { return nil }
            } else if character == " ", depth > 0 {
                // The space closes the marker; whatever follows is the text
                // and is none of the parser's business.
                return Heading(level: depth, markerLength: offset + 1)
            } else {
                return nil
            }
            offset += 1
        }
        // Hashes with no trailing space (`#` alone, or `###`): not a heading.
        return nil
    }

    /// Every heading marker span in `text`, in whole-string coordinates.
    ///
    /// Computed over the whole note at once because glyph generation asks
    /// about arbitrary characters without knowing what line they are on.
    static func markerRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byLines]
        ) { line, lineRange, _, _ in
            guard let line, let heading = parse(line) else { return }
            // Markers are pure ASCII, so the character count is the UTF-16
            // count and the two coordinate systems agree.
            ranges.append(
                NSRange(location: lineRange.location, length: min(heading.markerLength, lineRange.length))
            )
        }
        return ranges
    }
}
