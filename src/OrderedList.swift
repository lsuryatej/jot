import Foundation

/// What kind of marker an ordered-list line carries.
///
/// Letters and roman numerals keep the case they were typed with, so `A.` is
/// continued by `B.` and `IV.` by `V.` rather than being silently lowercased.
enum OrderedMarkerKind: Equatable {
    /// `1.` `2.` …
    case number(Int)
    /// `a.` `b.` … a single letter, any case.
    case letter(Character)
    /// `i.` `ii.` `iii.` … written only with the small roman digits.
    case roman(Int)

    /// The marker text without the trailing dot, exactly as typed.
    var text: String {
        switch self {
        case .number(let value): return String(value)
        case .letter(let char): return String(char)
        case .roman(let value): return Self.romanString(value) ?? ""
        }
    }

    /// The marker that follows this one on the next line, or nil at the end of
    /// a sequence: after `z.` there is nowhere ordinary to go, and roman
    /// numerals stop where they always have.
    var successor: OrderedMarkerKind? {
        switch self {
        case .number(let value):
            return value >= 9999 ? nil : .number(value + 1)
        case .letter(let char):
            guard let scalar = char.asciiValue else { return nil }
            let next = Character(UnicodeScalar(scalar + 1))
            // Both ends stop at their own case boundary: `z` has no successor,
            // and stepping from `Z` into `[` would be punctuation, not a list.
            guard char.isLowercase ? next.isLowercase : next.isUppercase else { return nil }
            return .letter(next)
        case .roman(let value):
            return value >= 3999 ? nil : .roman(value + 1)
        }
    }

    // MARK: Roman numerals

    /// Characters that can make up a roman numeral. A single-letter marker
    /// drawn from this set reads as roman (`i.`, `v.`, `x.`); anything else
    /// single-letter reads as an alphabet list (`a.`, `d.`).
    private static let romanDigits: Set<Character> = ["i", "v", "x", "l", "c", "d", "m"]

    static func isRomanText(_ text: String) -> Bool {
        !text.isEmpty && text.lowercased().allSatisfy { romanDigits.contains($0) }
    }

    static func romanValue(_ text: String) -> Int? {
        let values: [Character: Int] = [
            "i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000,
        ]
        var total = 0
        var previous = 0
        for char in text.lowercased().reversed() {
            guard let value = values[char] else { return nil }
            total += value < previous ? -value : value
            previous = value
        }
        return (1...3999).contains(total) ? total : nil
    }

    static func romanString(_ value: Int) -> String? {
        guard (1...3999).contains(value) else { return nil }
        let pairs: [(number: Int, numeral: String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"),
            (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"),
            (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remaining = value
        var result = ""
        for pair in pairs {
            while remaining >= pair.number {
                result += pair.numeral
                remaining -= pair.number
            }
        }
        return result
    }
}

/// One parsed ordered-list line.
struct OrderedListItem: Equatable {
    var indent: String
    var kind: OrderedMarkerKind
    var body: String
    /// Range of the marker within the line, dot included, trailing space
    /// excluded — the same convention `ChecklistItem.markerRange` uses, for
    /// click hit-testing and styling.
    var markerRange: NSRange

    /// The marker text plus its dot: what gets painted on screen.
    var markerWithDot: String { kind.text + "." }
}

/// Plain-text ordered-list parsing and rewriting.
///
/// Kept free of AppKit like `Checklist`, so every rule here is covered by
/// tests. These lists coexist with checkboxes rather than replacing them:
/// typing `1.` or `a.` or `iv.` at the start of a line makes that line an
/// ordered item wherever it appears, no keyword required. The numbers are
/// never renumbered behind the user's back — the file keeps saying exactly
/// what was typed — only the marker Return generates next is computed here.
enum OrderedList {
    /// One indent level, matching `Checklist.indentUnit`.
    static let indentUnit = Checklist.indentUnit

    /// Strict on input: a number of up to four digits, a single letter, or a
    /// run of small-roman digits, then a dot, then a space and the body — or
    /// nothing at all. The space is mandatory when there is a body, exactly
    /// as markdown demands, so `3.14 is pi` stays prose and never becomes a
    /// list item. The three-way alternation matters — `[a-z]` alone would
    /// claim `v.` and `x.` for the alphabet, so the roman branch takes runs
    /// of two or more and the classifier hands single `i`/`v`/`x` to romans.
    private static let pattern = try? NSRegularExpression(
        pattern: "^([ \\t]*)([0-9]{1,4}|[A-Za-z]|[ivxlcdmIVXLCDM]{2,7})\\.([ \\t]+(.*))?[ \t]*$"
    )

    // MARK: - Parsing

    static func item(in line: String) -> OrderedListItem? {
        guard let pattern else { return nil }
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }

        let indent = ns.substring(with: match.range(at: 1))
        let rawMarker = ns.substring(with: match.range(at: 2))

        // Group 4 only exists when a separator space did; without one the
        // line was bare (`1.` at the end) and the body is simply empty.
        let bodyRange = match.range(at: 4)
        let body = bodyRange.location == NSNotFound ? "" : ns.substring(with: bodyRange)

        guard let kind = classify(rawMarker) else { return nil }

        // The marker runs from the end of the indent through the dot.
        let markerEnd = match.range(at: 2).location + match.range(at: 2).length + 1
        let markerRange = NSRange(
            location: indent.utf16.count,
            length: markerEnd - indent.utf16.count
        )

        return OrderedListItem(
            indent: indent,
            kind: kind,
            body: body,
            markerRange: markerRange
        )
    }

    private static func classify(_ raw: String) -> OrderedMarkerKind? {
        if let value = Int(raw) { return .number(value) }
        if raw.count == 1, let char = raw.first {
            if OrderedMarkerKind.isRomanText(raw) {
                guard let value = OrderedMarkerKind.romanValue(raw) else { return nil }
                return .roman(value)
            }
            return .letter(char)
        }
        guard OrderedMarkerKind.isRomanText(raw),
              let value = OrderedMarkerKind.romanValue(raw)
        else { return nil }
        return .roman(value)
    }

    // MARK: - Return key

    /// What pressing Return at the end of an ordered-list line should do.
    enum Newline: Equatable {
        /// Text to insert at the caret: a new line carrying the next marker.
        case continueList(String)
        /// Replacement for the whole line: the item was empty, so leave the
        /// list instead of stacking empty markers.
        case exitList(String)
    }

    /// nil means "let the text view insert an ordinary newline". Mid-item
    /// splits are deliberately none of this function's business — guessing
    /// how to renumber a split would mean rewriting text the user typed, and
    /// the caller guards that case off before getting here.
    static func newline(inLine line: String) -> Newline? {
        guard let existing = item(in: line) else { return nil }

        // Return on an empty item leaves the list, the way every editor does.
        guard !existing.body.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .exitList("")
        }

        guard let next = existing.kind.successor else { return nil }
        return .continueList("\n" + existing.indent + next.text + ". ")
    }
}
