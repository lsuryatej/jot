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
