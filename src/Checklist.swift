import Foundation

/// One parsed checklist line.
struct ChecklistItem: Equatable {
    var indent: String
    var isChecked: Bool
    var body: String
    /// Range of the `- [ ]` marker within the line, for click hit-testing and
    /// styling. Does not include the space after the marker.
    var markerRange: NSRange
}

/// What pressing Return on a checklist line should do.
enum ChecklistNewline: Equatable {
    /// Text to insert at the caret.
    case continueList(String)
    /// Replacement for the whole line: the item was empty, so leave the list.
    case exitList(String)
}

/// Plain-text checklist parsing and rewriting.
///
/// Kept free of AppKit so every rule here is covered by tests. The text view
/// owns interaction; this owns what the text should become.
enum Checklist {
    /// One indent level. Spaces rather than tabs so alignment survives export
    /// into editors with a different tab width.
    static let indentUnit = "    "

    /// Lenient on input, strict on output.
    ///
    /// Accepts `- [ ]`, `* [ ]`, `+ [ ]`, and the bare `[ ]` written by earlier
    /// versions, so notes already on disk keep working without a migration.
    /// Always writes the `- [ ]` markdown task-list form, which renders as a
    /// real checkbox in Obsidian, Bear, and GitHub.
    private static let pattern = try? NSRegularExpression(
        pattern: "^([ \\t]*)(?:[-*+][ \\t]+)?\\[([ xX])\\][ \\t]?(.*)$"
    )

    // MARK: - Parsing

    static func item(in line: String) -> ChecklistItem? {
        guard let pattern else { return nil }
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }

        let indent = ns.substring(with: match.range(at: 1))
        let state = ns.substring(with: match.range(at: 2))
        let body = ns.substring(with: match.range(at: 3))

        // The marker runs from the end of the indent to the closing bracket.
        let closingBracket = match.range(at: 2).location + match.range(at: 2).length
        let markerRange = NSRange(
            location: indent.utf16.count,
            length: closingBracket + 1 - indent.utf16.count
        )

        return ChecklistItem(
            indent: indent,
            isChecked: state.lowercased() == "x",
            body: body,
            markerRange: markerRange
        )
    }

    static func render(indent: String, isChecked: Bool, body: String) -> String {
        "\(indent)- [\(isChecked ? "x" : " ")] \(body)"
    }

    static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: - Toggling

    /// Toggles every line of `block`, which must be whole lines.
    ///
    /// Mixed selections resolve predictably: if anything in the selection is not
    /// yet a checklist item, everything becomes one; otherwise, if anything is
    /// unchecked, everything gets checked; otherwise everything gets unchecked.
    static func toggled(block: String) -> String {
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        guard !lines.isEmpty else { return block }

        let parsed = lines.map { item(in: $0) }

        // Blank lines are skipped, so toggling a selection that spans paragraph
        // breaks does not litter it with empty checkboxes.
        var targets = lines.indices.filter {
            parsed[$0] != nil || !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Unless everything is blank, in which case the user is starting a list.
        if targets.isEmpty { targets = Array(lines.indices) }

        let everythingIsAnItem = targets.allSatisfy { parsed[$0] != nil }

        for index in targets {
            if everythingIsAnItem {
                let existing = parsed[index]!
                let shouldCheck = targets.contains { parsed[$0]!.isChecked == false }
                lines[index] = render(indent: existing.indent, isChecked: shouldCheck, body: existing.body)
            } else if let existing = parsed[index] {
                lines[index] = render(indent: existing.indent, isChecked: existing.isChecked, body: existing.body)
            } else {
                let indent = leadingWhitespace(of: lines[index])
                let body = String(lines[index].dropFirst(indent.count))
                lines[index] = render(indent: indent, isChecked: false, body: body)
            }
        }

        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    // MARK: - List mode

    /// A note whose first line is just the keyword behaves as a checklist:
    /// everything below it becomes an item, and Return keeps making more.
    ///
    /// The match is against the whole first line, so "listen to the podcast"
    /// is an ordinary note and only a bare "list" switches the mode on.
    static func isListMode(_ text: String, keyword: String) -> Bool {
        let keyword = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return false }

        let firstLine = text
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return firstLine == keyword
    }

    /// One line made list-shaped: a plain, non-blank line becomes an unchecked
    /// item at its own indent. Lines that are already items and blank lines
    /// come back alone — blanks stay paragraph breaks.
    static func itemized(line: String) -> String {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
              item(in: line) == nil
        else { return line }
        let indent = leadingWhitespace(of: line)
        return render(indent: indent, isChecked: false, body: String(line.dropFirst(indent.count)))
    }

    /// Turns every line below the keyword into an item, leaving ones that
    /// already are alone.
    static func convertedToList(_ text: String, keyword: String) -> String {
        guard isListMode(text, keyword: keyword) else { return text }

        var lines = text.components(separatedBy: "\n")
        // Line 0 holds the keyword itself and stays untouched.
        for index in lines.indices.dropFirst() {
            lines[index] = itemized(line: lines[index])
        }
        return lines.joined(separator: "\n")
    }

    /// What a paste of `block` into the note `target` should become, or nil
    /// when the paste should proceed as ordinary text.
    ///
    /// A multi-line paste into a list note lands as separate items rather than
    /// one raw block that would sit un-itemised until each line was
    /// individually left with Return. Single-line pastes and pastes into
    /// ordinary notes are none of this business.
    static func pastedAsListItems(_ block: String, into target: String, keyword: String) -> String? {
        guard block.contains("\n"), isListMode(target, keyword: keyword) else { return nil }
        return block.components(separatedBy: "\n").map { itemized(line: $0) }.joined(separator: "\n")
    }

    /// The text a fresh, empty item is made of.
    static func emptyItem(indent: String = "") -> String {
        render(indent: indent, isChecked: false, body: "")
    }

    // MARK: - Return key

    /// nil means "let the text view insert an ordinary newline".
    static func newline(inLine line: String) -> ChecklistNewline? {
        guard let existing = item(in: line) else { return nil }

        // Return on an empty item leaves the list, the way every editor does.
        guard !existing.body.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .exitList("")
        }

        return .continueList("\n" + render(indent: existing.indent, isChecked: false, body: ""))
    }

    // MARK: - Nesting

    /// Returns nil when no line in the block is a checklist item, so Tab keeps
    /// its ordinary meaning outside a list.
    static func indented(block: String, by levels: Int) -> String? {
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }

        let parsed = lines.map { item(in: $0) }
        guard parsed.contains(where: { $0 != nil }) else { return nil }

        var changed = false
        for index in lines.indices {
            guard let existing = parsed[index] else { continue }
            let indent: String
            if levels > 0 {
                indent = existing.indent + indentUnit
            } else if existing.indent.hasSuffix(indentUnit) {
                indent = String(existing.indent.dropLast(indentUnit.count))
            } else if existing.indent.isEmpty {
                continue
            } else {
                indent = ""
            }
            changed = true
            lines[index] = render(indent: indent, isChecked: existing.isChecked, body: existing.body)
        }

        guard changed else { return nil }
        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }
}
