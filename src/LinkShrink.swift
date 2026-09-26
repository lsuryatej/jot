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

            // NSDataDetector keeps a trailing "?" that almost always ends the
            // sentence ("did you see example.com/x?"); a real query has text after it.
            var range = result.range
            while range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 63 { range.length -= 1 }

            let full = ns.substring(with: range)
            guard let hostRange = full.range(of: host, options: .caseInsensitive) else { return }
            let hostNSRange = NSRange(hostRange, in: full)
            let displayRange = NSRange(
                location: range.location + hostNSRange.location,
                length: hostNSRange.length
            )

            guard range.length - displayRange.length >= minimumHiddenLength else { return }
            results.append(LinkMatch(range: range, displayRange: displayRange))
        }

        return results
    }
}

// MARK: - Opening

extension LinkShrink {
    /// The schemes Cmd+click will hand to the system. Anything else, `file:`
    /// and app-specific schemes above all, could launch or reveal something
    /// local from a line of pasted text, so it is never opened silently.
    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    static func isSafeToOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return openableSchemes.contains(scheme)
    }

    /// Any link covering `index`, shrunk or not, with the URL the data
    /// detector resolved for it: a bare `example.com` comes back as http, an
    /// email address as mailto. Same trailing-`?` trim as `matches(in:)`.
    static func link(containing index: Int, in text: String) -> (range: NSRange, url: URL)? {
        let ns = text as NSString
        guard index >= 0, index < ns.length,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let line = ns.lineRange(for: NSRange(location: index, length: 0))
        var found: (NSRange, URL)?
        detector.enumerateMatches(in: text, range: line) { result, _, stop in
            guard let result, let detected = result.url else { return }
            var range = result.range
            var trimmed = false
            while range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 63 {
                range.length -= 1
                trimmed = true
            }
            guard NSLocationInRange(index, range) else { return }
            // Re-derive the URL when a `?` came off, so what opens is what
            // shows as the link.
            let url = trimmed ? (URL(string: ns.substring(with: range)) ?? detected) : detected
            found = (range, url)
            stop.pointee = true
        }
        return found
    }
}
