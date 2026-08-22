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

    /// SF along its design axis: `.serif` is New York, `.rounded` is SF
    /// Rounded. Unlike iOS, AppKit has no factory taking a design, so this
    /// re-describes the system font instead.
    private static func systemFont(design: NSFontDescriptor.SystemDesign, size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        guard let redesigned = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: redesigned, size: size) ?? base
    }
}
