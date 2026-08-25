import Foundation

/// A bare keyword on the first line turns the whole note into a code block:
/// monospaced text with every parser this app runs switched off inside it.
///
/// Same shape as `Checklist.isListMode`, deliberately: the keyword is one
/// word on line one, matched case-insensitively after trimming, and it stays
/// in the file like every other marker here. Nothing is written to disk that
/// you could not read in `cat`.
///
/// Kept free of AppKit and SwiftUI so the rules are covered by the logic
/// tests, matching `Checklist`, `Heading`, and `OrderedList`. The text view
/// owns what a code block looks like; this owns what counts as one.
enum CodeBlock {
    /// The keyword used when the setting is empty or unset.
    static let defaultKeyword = "code"

    /// Whether `text` is a code note, given the configured keyword.
    static func isCodeMode(_ text: String, keyword: String) -> Bool {
        let keyword = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return false }

        let firstLine = text
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return firstLine == keyword
    }

    /// The code itself: everything after the keyword line.
    ///
    /// The keyword is a directive, not code, so it is left out of what Cmd+C
    /// copies. A trailing newline is dropped for the same reason a copied
    /// line from any editor does not carry one: what lands in the clipboard
    /// should paste as the code, not as the code plus a blank line.
    /// Returns nil when `text` is not a code note at all, so callers can fall
    /// straight through to the ordinary copy.
    static func body(of text: String, keyword: String) -> String? {
        guard isCodeMode(text, keyword: keyword) else { return nil }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
