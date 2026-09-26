import AppKit

/// The curated set of fonts a note can be set in.
///
/// A menu of system fonts rather than the full font panel: every entry here
/// ships with macOS, which keeps the zero-dependency stance intact and keeps
/// the Settings window from growing a second TextEdit inside it. The SF
/// design-based entries resolve through the font descriptor's design axis so
/// they always track the system's own family; the rest are named lookups.
enum NoteFont {
    static let all: [String] = [
        "SF Mono",
        "SF Pro",
        "New York",
        "SF Rounded",
        "Menlo",
        "Monaco",
        "American Typewriter",
        "Helvetica Neue",
    ]

    static let defaultName = "SF Mono"

    /// Resolves a curated name at `size`. Unknown names fall back to the
    /// default rather than returning nil, so a preference written by an older
    /// or newer version can never leave the editor without a font — and a
    /// renamed system font degrades to readable instead of crashing.
    static func resolved(_ name: String, size: CGFloat) -> NSFont {
        switch name {
        case "SF Mono":
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case "SF Pro":
            return .systemFont(ofSize: size, weight: .regular)
        case "New York":
            return systemFont(design: .serif, size: size)
        case "SF Rounded":
            return systemFont(design: .rounded, size: size)
        default:
            return NSFont(name: name, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// The face `**bold**` renders in, and whether the family had nothing
    /// heavy enough, in which case the caller thickens the regular glyphs
    /// with a stroke instead.
    struct Bold {
        let font: NSFont
        let needsSyntheticStroke: Bool
    }

    /// A clearly heavier member of `font`'s own family.
    ///
    /// Not `NSFontManager.convert(_:toHaveTrait: .boldFontMask)`: that asks
    /// for "the next face with the bold trait", which for SF Mono (the
    /// default note font), New York and SF Rounded is Semibold, barely
    /// distinguishable from Regular at note sizes, and for Monaco, which has
    /// no bold cut, is the regular face handed back unchanged, so the
    /// markers fold away and nothing marks the word at all.
    ///
    /// The target is Bold (NSFontManager weight 9), or three steps above
    /// the current weight when that is already heavier, so bold inside a
    /// bold heading still shows. Never past Heavy (10), and at least two
    /// steps above the current weight (one, when that one step reaches
    /// Heavy); among members in that band the
    /// one nearest the target wins, heavier on a tie. Italic, condensed and
    /// similar traits are kept, so the result is the same kind of face, only
    /// heavier. With no member in the band the stroke takes over.
    static func bold(of font: NSFont) -> Bold {
        let manager = NSFontManager.shared
        let current = manager.weight(of: font)
        let target = min(10, max(9, current + 3))
        // Two steps above the current weight, except that Heavy is the
        // ceiling: bold inside a Bold heading settles for the one step to
        // Heavy rather than going synthetic.
        let minimum = min(current + 2, 10)
        let shape: NSFontTraitMask = [.italicFontMask, .condensedFontMask, .narrowFontMask, .expandedFontMask]
        let keep = manager.traits(of: font).intersection(shape)

        if let family = font.familyName, let members = manager.availableMembers(ofFontFamily: family) {
            let weights = members.compactMap { member -> Int? in
                guard member.count > 3,
                      let weight = (member[2] as? NSNumber)?.intValue,
                      let raw = (member[3] as? NSNumber)?.uintValue,
                      NSFontTraitMask(rawValue: raw).intersection(shape) == keep,
                      weight >= minimum, weight > current, weight <= 10
                else { return nil }
                return weight
            }
            let ordered = Set(weights).sorted { (abs($0 - target), -$0) < (abs($1 - target), -$1) }
            for weight in ordered {
                // By family and weight rather than by PostScript name: the
                // system families' members have private dot-prefixed names
                // that `NSFont(name:size:)` will not reliably resolve.
                if let candidate = manager.font(withFamily: family, traits: keep, weight: weight, size: font.pointSize),
                   candidate.familyName == family,
                   manager.weight(of: candidate) >= minimum,
                   manager.weight(of: candidate) > current {
                    return Bold(font: candidate, needsSyntheticStroke: false)
                }
            }
        }
        return Bold(font: font, needsSyntheticStroke: true)
    }

    /// Stroke width for a synthetic bold, as `NSAttributedString.Key.strokeWidth`
    /// takes it: a percentage of the point size, negative so the glyph is
    /// filled as well as outlined. Thickens without changing any metric.
    static let syntheticBoldStrokeWidth: CGFloat = -4

    /// SF along its design axis: `.serif` is New York, `.rounded` is SF
    /// Rounded. Unlike iOS, AppKit has no factory taking a design, so this
    /// re-describes the system font instead.
    private static func systemFont(design: NSFontDescriptor.SystemDesign, size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        guard let redesigned = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: redesigned, size: size) ?? base
    }
}
