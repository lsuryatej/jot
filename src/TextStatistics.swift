import Foundation

/// Live counts for the footer.
struct TextStatistics: Equatable {
    var words: Int
    var characters: Int
    var lines: Int

    static let empty = TextStatistics(words: 0, characters: 0, lines: 0)

    /// Footer label. Lives here rather than in the view so pluralisation is
    /// covered by tests.
    var summary: String {
        func pluralise(_ count: Int, _ singular: String) -> String {
            "\(count) \(singular)\(count == 1 ? "" : "s")"
        }
        return [
            pluralise(words, "word"),
            pluralise(characters, "char"),
            pluralise(lines, "line"),
        ].joined(separator: " · ")
    }

    static func of(_ text: String) -> TextStatistics {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count

        // Count what the user sees, so an emoji or an accented character counts
        // once rather than once per UTF-16 unit.
        let characters = text.count

        // An empty document is one line; a trailing newline does not open a new one.
        let lines = text.isEmpty
            ? 1
            : text.reduce(into: 1) { count, character in
                if character.isNewline { count += 1 }
            } - (text.hasSuffix("\n") ? 1 : 0)

        return TextStatistics(words: words, characters: characters, lines: max(1, lines))
    }
}

/// Sum and average over the numbers in a selection.
struct SelectionMath: Equatable {
    var count: Int
    var sum: Double
    var average: Double

    /// Matches integers and decimals, with optional thousands separators and a
    /// leading minus. Currency and percent signs around a number are ignored
    /// rather than breaking the match, so "$1,240.50" and "47.2%" both parse.
    private static let numberPattern = try? NSRegularExpression(
        pattern: "-?\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?|-?\\d+(?:\\.\\d+)?"
    )

    static func numbers(in text: String) -> [Double] {
        guard let regex = numberPattern else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            Double(ns.substring(with: match.range).replacingOccurrences(of: ",", with: ""))
        }
    }

    /// Returns nil when there is nothing worth showing. A single number has no
    /// meaningful average, so two is the threshold.
    static func of(_ text: String) -> SelectionMath? {
        let values = numbers(in: text)
        guard values.count >= 2 else { return nil }
        let sum = values.reduce(0, +)
        return SelectionMath(count: values.count, sum: sum, average: sum / Double(values.count))
    }

    // MARK: - Display

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    static func format(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    var summary: String {
        "Sum \(Self.format(sum)) · Avg \(Self.format(average))"
    }
}
