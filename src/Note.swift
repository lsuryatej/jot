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
    /// This note's Screen Edge card height, in points, when the user has
    /// dragged its resize handle to something shorter than its content. Nil
    /// means "size to content" — the only behaviour before this existed, so
    /// old note files with no key decode straight through with nothing to
    /// migrate, same trade as `fontName`/`fontSize`. Unused outside Screen
    /// Edge mode; a windowed note has no card to size.
    var cardHeight: Double?

    init(id: UUID = UUID(), text: String = "", fontName: String? = nil, fontSize: Double? = nil, cardHeight: Double? = nil) {
        self.id = id
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.cardHeight = cardHeight
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
        let trimmed = (firstNonBlankLine.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        if let heading = Heading.parse(trimmed) {
            let body = trimmed.dropFirst(heading.markerLength)
                .trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? "Untitled note" : body
        }
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }

    /// The first line holding anything but whitespace. Scans only as far as
    /// that line rather than splitting the whole note: the header's note menu
    /// asks this of every note each time the header redraws.
    private var firstNonBlankLine: Substring? {
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[start..<end]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            guard end < text.endIndex else { break }
            start = text.index(after: end)
        }
        return nil
    }

    /// Longest `menuTitle`, in characters, ellipsis included.
    static let menuTitleLength = 40

    /// `title`, cut to fit a menu item. A note's first line can be a whole
    /// paragraph, and an NSMenu grows as wide as its widest item.
    var menuTitle: String {
        let full = title
        guard full.count > Self.menuTitleLength else { return full }
        let cut = full.prefix(Self.menuTitleLength - 1)
            .trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }
}
