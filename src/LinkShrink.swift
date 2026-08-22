import Foundation

/// A long URL found in a note, and the portion of it worth keeping visible.
struct LinkMatch: Equatable {
    /// The whole URL, exactly as it appears in the note's text.
    let range: NSRange
    /// The host, minus a leading "www.", shown even when the rest is hidden.
    let displayRange: NSRange
}

/// Finds URLs worth collapsing to just their domain.
///
/// The note's text never changes: this only says which ranges a renderer
/// should keep visible versus fold away, the same distinction the checklist
/// marker and image-markdown styling already draw between "in the file" and
/// "drawn on screen".
enum LinkShrink {
    /// Below this, hiding the scheme and path isn't worth doing, there's
    /// nothing meaningfully long to collapse.
    static let minimumHiddenLength = 12

    static func matches(in text: String) -> [LinkMatch] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let ns = text as NSString
        var results: [LinkMatch] = []

        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result, let url = result.url, var host = url.host, !host.isEmpty else { return }
            if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }

            let full = ns.substring(with: result.range)
            guard let hostRange = full.range(of: host, options: .caseInsensitive) else { return }
            let hostNSRange = NSRange(hostRange, in: full)
            let displayRange = NSRange(
                location: result.range.location + hostNSRange.location,
                length: hostNSRange.length
            )

            guard result.range.length - displayRange.length >= minimumHiddenLength else { return }
            results.append(LinkMatch(range: result.range, displayRange: displayRange))
        }

        return results
    }
}
