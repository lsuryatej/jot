import AppKit
import Foundation

/// Inline `==highlighted text==` spans — Obsidian's own highlighter syntax,
/// so a note pasted or exported elsewhere still renders it as a real
/// highlight rather than stray equals signs.
///
/// Same trade as every other marker in this app: the `==` pairs stay in the
/// file, so it's still plain text in `cat`, and only the marker characters
/// fold out of the display (via the same `shouldGenerateGlyphs` machinery
/// link shrink and headings use), leaving the wrapped text painted with a
/// background colour in their place.
struct Highlight: Equatable {
    /// The whole span, both marker pairs included.
    let range: NSRange
    /// The two `==` marker spans that fold out of the glyph stream.
    let markerRanges: [NSRange]
    /// What actually gets the highlighted background.
    let contentRange: NSRange

    /// The colour painted behind highlighted content. One fixed translucent
    /// marker-yellow rather than something derived per `InkTheme`: a real
    /// highlighter reads the same way over any paper, and washing it over
    /// the surface (rather than painting solid) keeps it legible against
    /// True Dark as well as Cream and White.
    static let backgroundColor = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.2, alpha: 0.4)

    /// A pair must sit on one line, matching how the rest of this app's
    /// line-oriented markers work, and wrap at least one character that
    /// isn't itself `=` — which keeps `====` (an empty pair some notes use
    /// as a rule) from ever being read as a highlight.
    private static let regex = try! NSRegularExpression(pattern: "==([^=\\n]+)==")

    /// Every `==...==` span in `text`, in whole-string coordinates.
    ///
    /// Computed over the whole note at once, like `Heading.markerRanges`,
    /// because glyph generation asks about arbitrary characters without
    /// knowing what line they're on.
    static func matches(in text: NSString) -> [Highlight] {
        var results: [Highlight] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line else { return }
            let lineNS = line as NSString
            let lineMatches = regex.matches(in: line, range: NSRange(location: 0, length: lineNS.length))
            for match in lineMatches {
                let content = match.range(at: 1)
                guard content.length > 0 else { continue }
                let whole = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                let contentWhole = NSRange(location: lineRange.location + content.location, length: content.length)
                let opening = NSRange(location: whole.location, length: 2)
                let closing = NSRange(location: contentWhole.location + contentWhole.length, length: 2)
                results.append(Highlight(range: whole, markerRanges: [opening, closing], contentRange: contentWhole))
            }
        }
        return results
    }
}
