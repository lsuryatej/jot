import AppKit

/// A note that IS a theme.
///
/// The first line reading exactly `theme` turns the rest of the note into a
/// live-editable appearance: one `key: value` pair per line, edited like any
/// other text, applied to the whole app as you type. Nothing is persisted —
/// the theme exists only while its note does, and the bottom-most theme note
/// wins when there are several, the same way the last word usually does.
///
/// The grammar is deliberately small:
///
///     theme
///     paper: #223038        (hex paper; everything else is derived from it)
///     tint: amber           (for translucent papers instead of a hex)
///     ink: #e8e4d8          (optional; derived from the paper otherwise)
///     accent: #7cc4ff       (optional)
///     font: Avenir Next     (any installed font name)
///     size: 14              (points)
///     spacing: 1.3          (line-height multiple)
///     tracking: 0.5         (extra points between characters)
///     guides: dots|grid|none
///
/// Lines that are not recognised pairs are ignored rather than rejected, so
/// plain prose can sit among the settings as commentary. A pair with an
/// unparseable value is ignored too: a half-typed `size:` line should never
/// throw the whole theme away mid-edit.
enum ThemeNote {
    static let keyword = "theme"

    /// Whether `text` opens with the bare keyword.
    ///
    /// Whole-line exact, lowercased after trimming — the same culture as the
    /// list keyword, so "# theme" stays a heading and "theme park" stays prose.
    static func isActive(_ text: String) -> Bool {
        let first = text.components(separatedBy: "\n").first ?? ""
        return first.trimmingCharacters(in: .whitespaces).lowercased() == keyword
    }

    // MARK: - Parsed values

    struct Theme: Equatable {
        /// Hex paper colour; when present the surface is opaque and every
        /// missing colour is derived from it.
        var paperHex: NSColor?
        /// For translucent papers: which wash to lay on the material.
        var tint: GlassTint?
        var inkHex: NSColor?
        var accentHex: NSColor?
        var fontName: String?
        var fontSize: Double?
        var lineSpacing: Double?
        var letterSpacing: Double?
        var guide: PaperGuide?

        static func == (lhs: Theme, rhs: Theme) -> Bool {
            // NSColor equality across constructed instances is unreliable;
            // compare by resolved sRGB components instead.
            func key(_ c: NSColor?) -> String {
                guard let c else { return "-" }
                let s = c.usingColorSpace(.sRGB)!
                return String(format: "%.3f,%.3f,%.3f", s.redComponent, s.greenComponent, s.blueComponent)
            }
            return key(lhs.paperHex) == key(rhs.paperHex)
                && lhs.tint == rhs.tint
                && key(lhs.inkHex) == key(rhs.inkHex)
                && key(lhs.accentHex) == key(rhs.accentHex)
                && lhs.fontName == rhs.fontName
                && lhs.fontSize == rhs.fontSize
                && lhs.lineSpacing == rhs.lineSpacing
                && lhs.letterSpacing == rhs.letterSpacing
                && lhs.guide == rhs.guide
        }
    }

    // MARK: - Parsing

    private static let hexPattern = try? NSRegularExpression(pattern: "^#?[0-9a-fA-F]{6}$")

    static func color(fromHex raw: String) -> NSColor? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    /// Parses a theme note's body, or nil when the text is not a theme note.
    static func parse(_ text: String) -> Theme? {
        guard isActive(text) else { return nil }

        var theme = Theme()
        for rawLine in text.components(separatedBy: "\n").dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "paper", "background":
                theme.paperHex = color(fromHex: value) ?? theme.paperHex
            case "tint":
                theme.tint = GlassTint(rawValue: value.lowercased()) ?? theme.tint
            case "ink", "text":
                theme.inkHex = color(fromHex: value) ?? theme.inkHex
            case "accent":
                theme.accentHex = color(fromHex: value) ?? theme.accentHex
            case "font":
                if !value.isEmpty { theme.fontName = value }
            case "size":
                if let parsed = Double(value) {
                    theme.fontSize = SettingsManager.clampedFontSize(parsed)
                }
            case "spacing":
                if let parsed = Double(value), (0.8...2.5).contains(parsed) {
                    theme.lineSpacing = parsed
                }
            case "tracking":
                if let parsed = Double(value), (-1...4).contains(parsed) {
                    theme.letterSpacing = parsed
                }
            case "guides":
                theme.guide = PaperGuide(rawValue: value.lowercased()) ?? theme.guide
            default:
                break  // unknown keys are commentary, not errors
            }
        }
        return theme
    }

    /// The active theme from a stack of notes, or nil when none of them is a
    /// theme note. The bottom-most wins: later in the array is lower in the
    /// stack, and the last decision made should be the one in force.
    static func active(in notes: [Note]) -> Theme? {
        notes.lazy.reversed().compactMap { parse($0.text) }.first
    }

    // MARK: - Derived palettes

    /// Relative luminance of an sRGB colour, roughly WCAG-weighted.
    static func luminance(of color: NSColor) -> CGFloat {
        guard let s = color.usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
    }

    private static func clamp(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(v, low), high)
    }

    /// Builds a colour that shares the paper's hue but sits at a given
    /// brightness — how every derived tone below keeps a custom paper looking
    /// intentional instead of pasted-on (the lesson Cream taught the hard way).
    private static func hueMate(of paper: NSColor, brightness: CGFloat, saturationScale: CGFloat = 0.5) -> NSColor {
        let hsb = hsb(paper)
        return NSColor(
            hue: hsb.hue,
            saturation: clamp(hsb.saturation * saturationScale, 0, 0.5),
            brightness: clamp(brightness, 0.05, 0.98),
            alpha: 1
        )
    }

    /// Ink for a custom paper that did not specify any: light papers get dark
    /// warm-neutral ink, dark papers get light ink, both carrying a whisper of
    /// the paper's own hue.
    static func derivedInk(for paper: NSColor) -> InkTheme {
        let lightPaper = luminance(of: paper) > 0.5
        let text = hueMate(of: paper, brightness: lightPaper ? 0.13 : 0.90, saturationScale: 0.6)
        let secondary = hueMate(of: paper, brightness: lightPaper ? 0.52 : 0.58, saturationScale: 0.45)
        let link = lightPaper
            ? NSColor(srgbRed: 0.100, green: 0.360, blue: 0.720, alpha: 1)
            : NSColor(srgbRed: 0.520, green: 0.720, blue: 0.930, alpha: 1)
        return InkTheme(
            text: text,
            secondary: secondary,
            accent: .controlAccentColor,
            link: link,
            guide: hueMate(of: paper, brightness: lightPaper ? 0.38 : 0.72)
        )
    }

    /// Card and chrome neighbours for a custom opaque paper: the card lifts a
    /// step off the page and chrome sinks one, so each strip separates by tone
    /// without a hairline doing all the work.
    static func derivedCardColor(for paper: NSColor) -> NSColor {
        hueMate(of: paper, brightness: hsb(paper).brightness + (luminance(of: paper) > 0.5 ? 0.03 : 0.06))
    }

    static func derivedChromeColor(for paper: NSColor) -> NSColor {
        hueMate(of: paper, brightness: hsb(paper).brightness - (luminance(of: paper) > 0.5 ? 0.04 : -0.03))
    }

    private static func hsb(_ color: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        guard let s = color.usingColorSpace(.sRGB) else { return (0, 0, 0.5) }
        return (s.hueComponent, s.saturationComponent, s.brightnessComponent)
    }
}
