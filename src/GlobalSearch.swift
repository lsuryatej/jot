import Foundation

/// One match, found while searching every note rather than just the open one.
struct GlobalSearchResult: Identifiable, Equatable {
    var id: String { "\(noteIndex)-\(lineNumber)-\(matchRange.location)" }
    let noteID: UUID
    let noteIndex: Int
    let lineNumber: Int
    let snippet: String
    let matchRange: NSRange
}

/// Cmd+F only searches the note that's open. This is what backs Cmd+Shift+F,
/// searching every note's text directly rather than through any separate
/// index, so it's always exactly as current as the notes themselves.
enum GlobalSearch {
    /// Capped so a one- or two-character query against a long history can't
    /// hand the UI thousands of rows to lay out.
    static let resultLimit = 300

    static func find(_ query: String, in notes: [Note]) -> [GlobalSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [GlobalSearchResult] = []

        for (noteIndex, note) in notes.enumerated() {
            let ns = note.text as NSString
            var searchStart = 0

            while searchStart < ns.length {
                let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
                let found = ns.range(of: trimmed, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }

                let lineRange = ns.lineRange(for: found)
                let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                let lineNumber = ns.substring(to: found.location)
                    .components(separatedBy: "\n").count

                results.append(GlobalSearchResult(
                    noteID: note.id,
                    noteIndex: noteIndex,
                    lineNumber: lineNumber,
                    snippet: line.isEmpty ? trimmed : line,
                    matchRange: found
                ))

                if results.count >= resultLimit { return results }
                searchStart = found.location + max(found.length, 1)
            }
        }

        return results
    }
}

// MARK: - Keyboard selection and match emphasis

/// Which result the keyboard has selected in the Cmd+Shift+F list.
///
/// Starts on the first result, so Return straight after typing opens the
/// best match, and starts over there whenever the query changes. Up and Down
/// stop at the ends rather than wrapping: a list that jumps from the last row
/// back to the first reads as having scrolled away.
struct GlobalSearchSelection: Equatable {
    private(set) var index: Int?

    init(count: Int) {
        index = count > 0 ? 0 : nil
    }

    /// A new query: back to the first result.
    mutating func reset(count: Int) {
        index = count > 0 ? 0 : nil
    }

    /// The same query with a different number of results (a note edited
    /// underneath the overlay): keep the row if it still exists.
    mutating func clamp(count: Int) {
        guard count > 0 else { index = nil; return }
        index = min(max(index ?? 0, 0), count - 1)
    }

    mutating func moveDown(count: Int) {
        guard count > 0 else { index = nil; return }
        index = min((index ?? -1) + 1, count - 1)
    }

    mutating func moveUp(count: Int) {
        guard count > 0 else { index = nil; return }
        index = max((index ?? 1) - 1, 0)
    }

    func selected(in results: [GlobalSearchResult]) -> GlobalSearchResult? {
        guard let index, results.indices.contains(index) else { return nil }
        return results[index]
    }
}

extension GlobalSearch {
    /// `text` with every case-insensitive occurrence of the (trimmed) query
    /// marked strongly emphasized, which SwiftUI's `Text` draws bold.
    static func highlighted(_ text: String, matching query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }
        let ns = text as NSString
        var start = 0
        while start < ns.length {
            let found = ns.range(of: needle, options: .caseInsensitive,
                                 range: NSRange(location: start, length: ns.length - start))
            guard found.location != NSNotFound, found.length > 0 else { break }
            if let range = Range(found, in: attributed) {
                attributed[range].inlinePresentationIntent = .stronglyEmphasized
            }
            start = NSMaxRange(found)
        }
        return attributed
    }

    /// How many characters of context are kept before a match that would
    /// otherwise sit past the visible end of a one-line row.
    static let excerptLead = 24

    /// `line`, cut at the front so its first match is near the start of the
    /// row. A result row shows one line, and a match 200 characters into a
    /// pasted paragraph was otherwise truncated away along with its bold.
    static func excerpt(of line: String, around query: String) -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = line as NSString
        let found = needle.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : ns.range(of: needle, options: .caseInsensitive)
        guard found.location != NSNotFound, found.location > excerptLead * 2 else { return line }
        // Start on a word boundary inside the lead, so the cut never lands
        // mid-word unless the lead is one long word.
        var cut = found.location - excerptLead
        let lead = ns.substring(with: NSRange(location: cut, length: excerptLead))
        if let space = lead.firstIndex(of: " ") {
            cut += (String(lead[..<space]) as NSString).length + 1
        }
        cut = ns.rangeOfComposedCharacterSequence(at: cut).location
        return "…" + ns.substring(from: cut)
    }

    /// What VoiceOver says when the keyboard selects a row: the focus stays
    /// in the search field, so the row is announced rather than focused.
    static func announcement(title: String, snippet: String, position: Int, count: Int) -> String {
        "\(title): \(snippet), \(position + 1) of \(count)"
    }
}
