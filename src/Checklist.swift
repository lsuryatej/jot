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

/// One parsed plain-bullet line.
struct BulletItem: Equatable {
    var indent: String
    var body: String
    /// Range of the `-` within the line, trailing space excluded — the same
    /// convention `ChecklistItem.markerRange` and `OrderedListItem.markerRange`
    /// use, so a future styling pass can treat all three alike.
    var markerRange: NSRange
}

/// Plain markdown bullets: `- milk` with no checkbox.
///
/// Lives beside `Checklist` rather than in a file of its own because the two
/// share the `-` character and have to agree about who owns a given line —
/// `- [ ] milk` is a checkbox first and a bullet never, and that rule is
/// easier to keep true when both parsers sit where you can read them together.
///
/// Only `-` counts as a marker. Markdown also allows `*` and `+`, but this app
/// spends both characters elsewhere: `*` opens emphasis spans (`Emphasis`) and
/// multiplies (`MathExpression`, where `2*3*4` must stay arithmetic), and `+`
/// adds on those same math lines. A leading `- ` collides with nothing —
/// negative numbers (`-5`) and dashed asides (`-- like this`) both fail the
/// mandatory separator, and `---` is a horizontal rule, not a list.
enum Bullet {
    /// The separator is mandatory only when there is a body, matching
    /// `OrderedList`: a lone `-` is an empty bullet the way a lone `1.` is an
    /// empty ordered item, so Return on it can end the list.
    private static let pattern = try? NSRegularExpression(
        pattern: "^([ \\t]*)-(?:[ \\t]+(.*))?[ \\t]*$"
    )

    // MARK: - Parsing

    static func item(in line: String) -> BulletItem? {
        guard let pattern else { return nil }
        // Checkboxes win outright. `- [ ] milk` matches the bullet shape too,
        // and letting it through here would hand the line to whichever caller
        // asked first instead of to the marker the user actually typed.
        guard Checklist.item(in: line) == nil else { return nil }

        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }

        let indent = ns.substring(with: match.range(at: 1))
        // Group 2 only exists when a separator did; without one the line was a
        // bare `-` and the body is simply empty.
        let bodyRange = match.range(at: 2)
        let body = bodyRange.location == NSNotFound ? "" : ns.substring(with: bodyRange)

        return BulletItem(
            indent: indent,
            body: body,
            markerRange: NSRange(location: indent.utf16.count, length: 1)
        )
    }

    // MARK: - Return key

    /// What pressing Return at the end of a bullet line should do. Mirrors
    /// `OrderedList.Newline` rather than reusing `ChecklistNewline`, so a
    /// caller cannot accidentally feed one list's outcome to the other's
    /// switch and write the wrong marker.
    enum Newline: Equatable {
        /// Text to insert at the caret: a new line carrying a fresh bullet.
        case continueList(String)
        /// Replacement for the whole line: the bullet was empty, so leave the
        /// list instead of stacking markers nobody asked for.
        case exitList(String)
    }

    /// nil means "let the text view insert an ordinary newline".
    static func newline(inLine line: String) -> Newline? {
        guard let existing = item(in: line) else { return nil }

        // Return on an empty item leaves the list, the way every editor does
        // and the way both neighbours here already do.
        guard !existing.body.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .exitList("")
        }

        // Always one space after the marker, whatever was typed: the same
        // strict-on-output trade `Checklist.render` makes.
        return .continueList("\n" + existing.indent + "- ")
    }
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
        // breaks does not litter it with empty checkboxes. Heading lines skip
        // too: they carry their own structure and never grow a checkbox.
        // Ordered-list lines (`1.` `a.` `iv.`) skip for the same reason —
        // wrapping them as `- [ ] 1. eggs` would nest one list inside another.
        func isStructural(_ line: String) -> Bool {
            Heading.parse(line) != nil || OrderedList.item(in: line) != nil
        }
        var targets = lines.indices.filter {
            if isStructural(lines[$0]) { return false }
            return parsed[$0] != nil || !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Unless everything is blank, in which case the user is starting a list.
        if targets.isEmpty {
            // A selection of nothing but headings or ordered items is not
            // asking to become checkboxes.
            guard !lines.contains(where: isStructural) else { return block }
            targets = Array(lines.indices)
        }

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
    /// come back alone — blanks stay paragraph breaks. Headings stay headings:
    /// `- [ ] # Foo` would demote structure into item text. Ordered-list
    /// lines stay ordered for the same reason: `1.` already carries structure.
    static func itemized(line: String) -> String {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
              item(in: line) == nil,
              Heading.parse(line) == nil,
              OrderedList.item(in: line) == nil
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
    ///
    /// `linePrefix` is whatever already sits before the caret on its line. When
    /// that holds a marker or text, the first pasted line finishes that line
    /// instead of opening a second item on it.
    static func pastedAsListItems(_ block: String, into target: String, keyword: String, linePrefix: String = "") -> String? {
        guard block.contains("\n"), isListMode(target, keyword: keyword) else { return nil }
        var lines = block.components(separatedBy: "\n")
        guard !linePrefix.trimmingCharacters(in: .whitespaces).isEmpty else {
            return lines.map { itemized(line: $0) }.joined(separator: "\n")
        }
        let first = lines.removeFirst()
        let head = item(in: first)?.body ?? first.trimmingCharacters(in: .whitespaces)
        return ([head] + lines.map { itemized(line: $0) }).joined(separator: "\n")
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
