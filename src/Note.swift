import Foundation

/// A note, with an identity that survives editing and reordering.
///
/// The text alone was enough while notes only ever lived in this app. Syncing
/// to Apple Notes needs something stable to map onto a note over there, and
/// text is not it: the first keystroke would orphan the mapping.
struct Note: Identifiable, Equatable, Codable {
    let id: UUID
    var text: String
    /// This note's own font choice, overriding `SettingsManager.noteFontName`.
    /// Nil means "use the default" — every note started this way before per-note
    /// fonts existed, and a note that has never had its font touched still
    /// reads that way, so old note files decode straight through with nothing
    /// to migrate.
    var fontName: String?
    /// Same trade as `fontName`, for `SettingsManager.noteFontSize`.
    var fontSize: Double?

    init(id: UUID = UUID(), text: String = "", fontName: String? = nil, fontSize: Double? = nil) {
        self.id = id
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
    }

    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// First non-empty line, used as the title when exporting.
    ///
    /// When that line is a heading the hashes are stripped: they are markup,
    /// not words, and this is also where an explicit first-line heading
    /// replaces the automatic title (the heading text is the title).
    var title: String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let trimmed = (line.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        if let heading = Heading.parse(trimmed) {
            let body = trimmed.dropFirst(heading.markerLength)
                .trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? "Untitled note" : body
        }
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }
}
