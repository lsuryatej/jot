import Foundation
import Combine
import AppKit

/// How the app presents itself. The user scored this the highest-priority
/// remaining feature.
enum DisplayMode: String, CaseIterable, Identifiable {
    /// Always-on-top panel, no Dock icon. The original behaviour.
    case floating
    /// Ordinary window level, shown and hidden from the menu bar icon.
    case menuBar
    /// NSPopover anchored under the menu bar icon.
    case dropdown
    /// Regular app with a Dock icon and a standard window.
    case dock
    /// Docked to a screen edge, revealed by pushing the cursor into that edge
    /// or clicking the bar that sits there.
    case edge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floating: return "Floating"
        case .menuBar:  return "Menu Bar"
        case .dropdown: return "Menu Bar Dropdown"
        case .dock:     return "Dock"
        case .edge:     return "Screen Edge"
        }
    }

    var detail: String {
        switch self {
        case .floating: return "Always on top of other windows. No Dock icon."
        case .menuBar:  return "Behaves like a normal window. Toggle it from the menu bar."
        case .dropdown: return "Drops down from the menu bar icon and closes when you click away."
        case .dock:     return "Appears in the Dock and the app switcher like a normal app."
        case .edge:     return "Slides out when you push the cursor into the edge of the screen."
        }
    }

    /// Dock mode is the only one that wants a Dock icon and a main menu.
    var wantsRegularActivationPolicy: Bool {
        self == .dock
    }

    /// Dropdown mode pins the note under the menu bar icon and hides it as
    /// soon as focus moves elsewhere.
    var anchorsToStatusItem: Bool {
        self == .dropdown
    }

    var hidesOnDeactivate: Bool {
        // Edge mode is deliberately excluded: it reveals without activating the
        // app, so there is no deactivation to hide on. It auto-hides when the
        // pointer leaves instead.
        self == .dropdown
    }

    /// Docked full-height against a screen edge, with a trigger strip.
    var isEdgeDocked: Bool {
        self == .edge
    }

    var wantsFloatingLevel: Bool {
        self == .floating || self == .dropdown || self == .edge
    }
}

/// What text is painted with on a surface.
///
/// Opaque papers need their own ink because the system label colors follow
/// macOS's light/dark mode rather than the paper: a light-mode user picking
/// True Dark would otherwise get black text on a near-black page.
struct InkTheme: Equatable {
    let text: NSColor
    /// Checkboxes' markers, the keyword line, struck-through items, "Note N
    /// of M", footer counts, math hints. Small text, so it must clear 4.5:1
    /// on the paper, the chrome, and the edge cards (tested per paper).
    let secondary: NSColor
    /// Checked markers, math results.
    let accent: NSColor
    let link: NSColor
    /// Dot and square guides, drawn at low opacity by the editor.
    let guide: NSColor

    /// The system palette, for the translucent appearances where macOS's own
    /// light/dark resolution is exactly right.
    static let system = InkTheme(
        text: .labelColor,
        secondary: AdaptiveInk.systemSecondary.color,
        accent: .controlAccentColor,
        link: .linkColor,
        guide: .labelColor
    )
}

/// WCAG 2.x contrast, so ink choices are measured rather than eyeballed.
enum Contrast {
    /// Relative luminance per WCAG 2.x, from linearised sRGB.
    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let s = color.usingColorSpace(.sRGB) else { return 0.5 }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(s.redComponent)
            + 0.7152 * linear(s.greenComponent)
            + 0.0722 * linear(s.blueComponent)
    }

    /// The contrast ratio between two opaque colours, 1...21.
    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `foreground` flattened onto an opaque `background`, which is what the
    /// eye actually sees when a translucent ink sits on a surface.
    static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let f = foreground.usingColorSpace(.sRGB) ?? foreground
        let b = background.usingColorSpace(.sRGB) ?? background
        let a = f.alphaComponent
        return NSColor(
            srgbRed: f.redComponent * a + b.redComponent * (1 - a),
            green: f.greenComponent * a + b.greenComponent * (1 - a),
            blue: f.blueComponent * a + b.blueComponent * (1 - a),
            alpha: 1
        )
    }

    /// A dynamic colour pinned to concrete sRGB components under `appearance`.
    static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }
}

/// The countdown chip's colours.
///
/// Opaque, so the chip reads the same on every paper, and dark enough that
/// white text clears 4.5:1: none of the chip's text (10pt title and phase,
/// 13pt clock) is large enough for the 3:1 allowance. The old
/// `green.opacity(0.8)` measured 1.8:1 over White and red 2.8:1. #248A3D,
/// Apple's high-contrast green, is 4.4:1 with white, just short, so Break
/// takes a step deeper.
enum TimerChipPalette {
    enum State: CaseIterable {
        /// A plain timer, or a Pomodoro work phase.
        case work
        /// A Pomodoro break.
        case rest
    }

    static let text = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    static func background(for state: State) -> NSColor {
        switch state {
        case .work: return NSColor(srgbRed: 0xD7 / 255, green: 0x00 / 255, blue: 0x15 / 255, alpha: 1) // #D70015, 5.4:1
        case .rest: return NSColor(srgbRed: 0x1F / 255, green: 0x7A / 255, blue: 0x35 / 255, alpha: 1) // #1F7A35, 5.4:1
        }
    }
}

/// An ink with a stronger variant for Increase Contrast, and separate light
/// and dark variants where the surface follows the system mode.
///
/// Built once as a shared `NSColor(name:dynamicProvider:)`: AppKit resolves
/// it against whatever appearance is drawing, and a shared instance keeps
/// `InkTheme`'s equality cheap (the editor re-styles when its ink changes).
struct AdaptiveInk {
    let light: NSColor
    let lightHighContrast: NSColor
    let dark: NSColor
    let darkHighContrast: NSColor
    let color: NSColor

    init(light: NSColor, lightHighContrast: NSColor, dark: NSColor? = nil, darkHighContrast: NSColor? = nil) {
        let dark = dark ?? light
        let darkHighContrast = darkHighContrast ?? lightHighContrast
        self.light = light
        self.lightHighContrast = lightHighContrast
        self.dark = dark
        self.darkHighContrast = darkHighContrast
        self.color = NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]) {
            case .accessibilityHighContrastDarkAqua: return darkHighContrast
            case .accessibilityHighContrastAqua:     return lightHighContrast
            case .darkAqua:                          return dark
            default:                                 return light
            }
        }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    /// Secondary ink on the translucent papers.
    ///
    /// Not `.secondaryLabelColor`: on current macOS that is black at 50% in
    /// light mode, 3.95:1 on white and worse on a grey material. 62% clears
    /// 4.5:1 over every light material and tint wash, and the dark side
    /// clears it over a lighter-than-usual dark material. Alpha rather than
    /// grey, so it keeps sitting in whatever wash is under it.
    static let systemSecondary = AdaptiveInk(
        light: NSColor(white: 0, alpha: 0.62),
        lightHighContrast: NSColor(white: 0, alpha: 0.80),
        dark: NSColor(white: 1, alpha: 0.62),
        darkHighContrast: NSColor(white: 1, alpha: 0.86)
    )

    /// White's secondary: Apple's secondary grey, 6.0:1 on the page.
    static let whiteSecondary = AdaptiveInk(light: hex(0x636366), lightHighContrast: hex(0x48484A))

    /// Cream's secondary: a warm brown in Cream's own hue, 5.6:1 on the page.
    static let creamSecondary = AdaptiveInk(light: hex(0x6B5E4A), lightHighContrast: hex(0x4A4032))

    /// True Dark's secondary already cleared 5:1; only its stronger variant is new.
    static let trueDarkSecondary = AdaptiveInk(light: hex(0x8F8C87), lightHighContrast: hex(0xB5B1AB))

    /// Every adaptive ink with the paper it is painted on, for the tests.
    static let catalogue: [(String, AdaptiveInk, Appearance)] = [
        ("system secondary", systemSecondary, .frosted),
        ("white secondary", whiteSecondary, .white),
        ("cream secondary", creamSecondary, .cream),
        ("true dark secondary", trueDarkSecondary, .trueDark),
    ]
}

extension NSAppearanceCustomization {
    /// Pins the appearance to the paper's (nil hands it back to the system).
    /// Skips a no-op assignment: every set invalidates the whole view tree's
    /// appearance, and theme notes re-derive on every keystroke.
    func adoptPaperAppearance(_ name: NSAppearance.Name?) {
        guard appearance?.name != name else { return }
        appearance = name.flatMap { NSAppearance(named: $0) }
    }
}

/// How the note's surface is rendered: three translucent window materials,
/// or an opaque paper that carries its own ink.
enum Appearance: String, CaseIterable, Identifiable {
    /// The standard popover material: translucent but muted.
    case frosted
    /// Heavy pass-through of whatever is behind, with a lit edge.
    case glass
    /// Opaque window background, for when the desktop underneath is noisy.
    case solid
    /// Near-black paper, warmer than system dark mode and independent of it.
    case trueDark
    /// Warm off-white, the long-writing-session paper.
    case cream
    /// Plain white, for daylight and screenshots.
    case white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frosted:  return "Frosted"
        case .glass:    return "Glass"
        case .solid:    return "Solid"
        case .trueDark: return "True Dark"
        case .cream:    return "Cream"
        case .white:    return "White"
        }
    }

    var detail: String {
        switch self {
        case .frosted:  return "Translucent, with the desktop softened behind it."
        case .glass:    return "The desktop shows through clearly, with a lit edge."
        case .solid:    return "Opaque. Easiest to read over a busy desktop."
        case .trueDark: return "Near-black paper with its own light ink, whatever mode the system is in."
        case .cream:    return "Warm off-white stock, easier on the eyes over a long session."
        case .white:    return "Plain white paper with dark ink."
        }
    }

    /// The opaque paper color, or nil for the translucent appearances, which
    /// render through `NSVisualEffectView` instead (see `materialRawValue`).
    var paperColor: NSColor? {
        switch self {
        case .frosted, .glass, .solid:
            return nil
        case .trueDark:
            // Tinted near-black rather than pure black, so it reads as
            // paper rather than a void.
            return NSColor(srgbRed: 0.075, green: 0.074, blue: 0.080, alpha: 1)
        case .cream:
            return NSColor(srgbRed: 0.969, green: 0.941, blue: 0.882, alpha: 1)
        case .white:
            return .white
        }
    }

    /// Only meaningful when `paperColor` is nil.
    ///
    /// Matches NSVisualEffectView.Material.
    var materialRawValue: Int {
        switch self {
        case .frosted: return 6  // .popover
        case .glass:   return 13 // .hudWindow
        case .solid:   return 12 // .windowBackground
        default:       return 12
        }
    }

    var ink: InkTheme {
        switch self {
        case .frosted, .glass, .solid:
            // Translucent surfaces sit inside whatever mode the system is
            // in, so the system palette is exactly right for them.
            return .system
        case .white:
            // Forced light even in dark mode, or a dark-mode user would get
            // white text on white paper.
            return InkTheme(
                text: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1),
                secondary: AdaptiveInk.whiteSecondary.color,
                accent: .controlAccentColor,
                link: NSColor(srgbRed: 0.100, green: 0.360, blue: 0.720, alpha: 1),
                guide: .black
            )
        case .trueDark:
            return InkTheme(
                text: NSColor(srgbRed: 0.910, green: 0.898, blue: 0.878, alpha: 1),
                secondary: AdaptiveInk.trueDarkSecondary.color,
                accent: NSColor(srgbRed: 0.480, green: 0.780, blue: 0.560, alpha: 1),
                link: NSColor(srgbRed: 0.520, green: 0.720, blue: 0.930, alpha: 1),
                guide: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
            )
        case .cream:
            return InkTheme(
                text: NSColor(srgbRed: 0.180, green: 0.153, blue: 0.110, alpha: 1),
                secondary: AdaptiveInk.creamSecondary.color,
                accent: .controlAccentColor,
                link: NSColor(srgbRed: 0.100, green: 0.360, blue: 0.720, alpha: 1),
                guide: NSColor(srgbRed: 0.400, green: 0.340, blue: 0.240, alpha: 1)
            )
        }
    }

    /// The hairline around edge cards and the window edge.
    var hairlineColor: NSColor {
        switch self {
        case .trueDark: return .white
        case .cream, .white: return .black
        default: return .white
        }
    }

    /// Edge cards sit directly on the surface; on an opaque paper they read
    /// as a second sheet of similar stock rather than a system-white chip.
    ///
    /// Cream lifts its cards lighter than the page; White has nothing lighter
    /// than white to go to, so its cards step down into a faint cool grey —
    /// either way the card separates from the page by tone, not just by the
    /// hairline around it.
    var cardColor: NSColor {
        switch self {
        case .trueDark: return NSColor(srgbRed: 0.125, green: 0.124, blue: 0.133, alpha: 1)
        case .cream:    return NSColor(srgbRed: 0.992, green: 0.976, blue: 0.937, alpha: 1)
        case .white:    return NSColor(srgbRed: 0.957, green: 0.957, blue: 0.969, alpha: 1)
        default:        return .controlBackgroundColor
        }
    }

    /// Cards on opaque papers are fully opaque; on glass they stay partly
    /// transparent so the desktop keeps coming through.
    var wantsOpaqueCards: Bool {
        paperColor != nil || self == .solid
    }

    /// Background for chrome strips (header, footer) sitting on the surface.
    ///
    /// An opaque paper can't reuse its own color here — a cream strip on cream
    /// paper is invisible, which shipped. Each opaque paper gets a
    /// neighbouring tone instead: a lift off the near-black for True Dark, a
    /// deeper warm shade for Cream, a cooler grey for White.
    var chromeColor: NSColor {
        switch self {
        case .trueDark: return NSColor(srgbRed: 0.110, green: 0.109, blue: 0.118, alpha: 1)
        case .cream:    return NSColor(srgbRed: 0.922, green: 0.882, blue: 0.808, alpha: 1)
        case .white:    return NSColor(srgbRed: 0.945, green: 0.945, blue: 0.961, alpha: 1)
        default:        return .windowBackgroundColor
        }
    }

    var wantsLitEdge: Bool {
        self == .glass
    }
}

/// Writing guides drawn faintly under the text. Edge cards skip them: on a
/// card a few lines tall a repeating pattern reads as noise, not structure.
enum PaperGuide: String, CaseIterable, Identifiable {
    case none
    case dots
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .dots: return "Dot Grid"
        case .grid: return "Square Grid"
        }
    }
}

/// Which side of the screen the edge-docked note lives on.
enum ScreenEdge: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
}

/// User preferences. These are small and non-critical, so UserDefaults is the
/// right home for them — unlike the notes themselves, which moved to a file.
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    /// Renaming the app changed the bundle ID this app's `UserDefaults.standard`
    /// resolves to, which is a completely separate on-disk domain — so without
    /// this, every setting silently resets to its default the first time
    /// someone launches the renamed build. Copied once, guarded by a sentinel
    /// in the *new* domain so it never re-runs and never clobbers a choice
    /// made after the migration already happened.
    private static func migrateFromPreviousBundleIDIfNeeded(into defaults: UserDefaults) {
        let sentinel = "migratedSettingsFromStickyNotesBundle"
        guard defaults.object(forKey: sentinel) == nil else { return }
        defaults.set(true, forKey: sentinel)

        guard let previous = UserDefaults(suiteName: "com.suryatejlalam.StickyNotes") else { return }
        for key in Key.all {
            guard defaults.object(forKey: key) == nil, let value = previous.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
        }
    }

    private enum Key {
        static let displayMode    = "displayMode"
        static let hotKeyCode     = "hotKeyCode"
        static let hotKeyMods     = "hotKeyModifiers"
        static let timerKeyword   = "timerKeyword"
        static let pomodoroKeyword = "pomodoroKeyword"
        static let reminderKeyword = "reminderKeyword"
        static let showsFooter    = "showsFooter"
        static let screenEdge     = "screenEdge"
        static let edgeWidth      = "edgeWidth"
        static let appearance     = "appearance"
        static let appearanceTint = "appearanceTint"
        static let showsHeader    = "showsHeader"
        static let lineSpacing    = "lineSpacing"
        static let windowFrame    = "windowFrame"
        static let syncsToNotes   = "syncsToAppleNotes"
        static let listKeyword    = "listKeyword"
        static let codeKeyword    = "codeKeyword"
        static let fetchesLiveRates = "fetchesLiveCurrencyRates"
        static let checksForUpdates = "checksForUpdates"
        static let noteFontName   = "noteFontName"
        static let noteFontSize   = "noteFontSize"
        static let letterSpacing  = "letterSpacing"
        static let guide          = "paperGuide"
        static let celebrationStyle = "celebrationStyle"
        static let timerSound     = "timerSound"

        /// Every key this type persists, for the one-time migration below.
        /// Kept as a literal list rather than reflection: `UserDefaults`
        /// domains accumulate unrelated system-set keys over time, and only
        /// the app's own keys should ever cross a bundle-ID migration.
        static let all: Set<String> = [
            displayMode, hotKeyCode, hotKeyMods, timerKeyword, pomodoroKeyword, reminderKeyword, showsFooter,
            screenEdge, edgeWidth, appearance, appearanceTint, showsHeader, lineSpacing,
            windowFrame, syncsToNotes, listKeyword, codeKeyword, fetchesLiveRates, checksForUpdates,
            noteFontName, noteFontSize, letterSpacing, guide,
            celebrationStyle, timerSound,
        ]
    }

    private let defaults: UserDefaults

    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }

    @Published var hotKey: KeyCombo {
        didSet {
            defaults.set(Int(hotKey.keyCode), forKey: Key.hotKeyCode)
            defaults.set(Int(hotKey.carbonModifiers), forKey: Key.hotKeyMods)
        }
    }

    /// The word that turns "5m <keyword>" into a countdown.
    @Published var timerKeyword: String {
        didSet {
            let trimmed = timerKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty keyword would make every "5m" anywhere in a note start a
            // timer, so fall back rather than store it.
            defaults.set(trimmed.isEmpty ? "timer" : trimmed, forKey: Key.timerKeyword)
        }
    }

    /// The word that turns "<keyword> 25/5" into a work/break Pomodoro cycle.
    @Published var pomodoroKeyword: String {
        didSet {
            let trimmed = pomodoroKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "pomodoro" : trimmed, forKey: Key.pomodoroKeyword)
        }
    }

    /// The word that turns "<keyword> 3pm" into a wall-clock reminder.
    @Published var reminderKeyword: String {
        didSet {
            let trimmed = reminderKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "remind" : trimmed, forKey: Key.reminderKeyword)
        }
    }

    @Published var showsFooter: Bool {
        didSet { defaults.set(showsFooter, forKey: Key.showsFooter) }
    }

    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// A colour wash over the translucent papers (see `GlassTint`). Opaque
    /// papers ignore it; the picker hides the row rather than storing a value
    /// that does nothing.
    @Published var glassTint: GlassTint {
        didSet { defaults.set(glassTint.rawValue, forKey: Key.appearanceTint) }
    }

    /// Glassnote's "buttons can even be hidden completely": with the header off
    /// the window is nothing but text.
    @Published var showsHeader: Bool {
        didSet { defaults.set(showsHeader, forKey: Key.showsHeader) }
    }

    /// Line height multiple for the editor.
    @Published var lineSpacing: Double {
        didSet { defaults.set(lineSpacing, forKey: Key.lineSpacing) }
    }

    /// The note's font, by curated name (see `NoteFont`).
    @Published var noteFontName: String {
        didSet { defaults.set(noteFontName, forKey: Key.noteFontName) }
    }

    /// The note's font size in points.
    ///
    /// The clamp lives in `init`, not here: assigning to a property from
    /// inside its own didSet re-fires the observer, which recurses forever —
    /// every pass re-publishes and re-writes defaults, hanging the app the
    /// moment the size slider moves. (Verified headlessly: a scratch class
    /// with this exact shape prints its didSet until killed.) Property
    /// observers don't fire during init either, so a didSet clamp never
    /// guarded the actual threat anyway — a wild value from an old or
    /// hand-edited default entered through the init read.
    @Published var noteFontSize: Double {
        didSet { defaults.set(noteFontSize, forKey: Key.noteFontSize) }
    }

    /// The bounds `noteFontSize` is held to.
    static let fontSizeRange: ClosedRange<Double> = 11...24

    /// Font sizes arriving from anywhere (theme notes included) pass through
    /// the same clamp the slider does.
    static func clampedFontSize(_ value: Double) -> Double {
        clamped(value, to: fontSizeRange)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Extra tracking between characters, in points. Zero is the font's own
    /// spacing.
    @Published var letterSpacing: Double {
        didSet { defaults.set(letterSpacing, forKey: Key.letterSpacing) }
    }

    /// Writing guides under the text.
    @Published var guide: PaperGuide {
        didSet { defaults.set(guide.rawValue, forKey: Key.guide) }
    }

    /// The editor's font, resolved from the stored name. Unknown names
    /// resolve to the default inside `NoteFont`, so this never fails.
    var editorFont: NSFont {
        NoteFont.resolved(noteFontName, size: CGFloat(noteFontSize))
    }

    /// A bare keyword on the first line turns the note into a checklist.
    @Published var listKeyword: String {
        didSet {
            let trimmed = listKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "list" : trimmed, forKey: Key.listKeyword)
        }
    }

    var effectiveListKeyword: String {
        let trimmed = listKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "list" : trimmed
    }

    /// A bare keyword on the first line turns the note into a code block.
    @Published var codeKeyword: String {
        didSet {
            let trimmed = codeKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? CodeBlock.defaultKeyword : trimmed, forKey: Key.codeKeyword)
        }
    }

    var effectiveCodeKeyword: String {
        let trimmed = codeKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CodeBlock.defaultKeyword : trimmed
    }

    /// The only network call this app makes by default is none at all.
    /// Off means every currency conversion uses the last cached rate (or the
    /// built-in snapshot, on a fresh install) and nothing is ever fetched.
    @Published var fetchesLiveCurrencyRates: Bool {
        didSet { defaults.set(fetchesLiveCurrencyRates, forKey: Key.fetchesLiveRates) }
    }

    /// A single GET to GitHub's public releases API, at most once a day.
    /// No note content, no identifiers, nothing but "is there a newer tag"
    /// leaves the machine. On by default, unlike currency rates: a stale app
    /// silently missing your fixes is the failure mode this exists to avoid,
    /// and the request carries nothing to protect.
    @Published var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Key.checksForUpdates) }
    }

    /// Push notes into an Apple Notes folder as they are saved.
    @Published var syncsToAppleNotes: Bool {
        didSet { defaults.set(syncsToAppleNotes, forKey: Key.syncsToNotes) }
    }

    @Published var screenEdge: ScreenEdge {
        didSet { defaults.set(screenEdge.rawValue, forKey: Key.screenEdge) }
    }

    /// How wide the note is when docked to an edge.
    @Published var edgeWidth: Double {
        didSet { defaults.set(edgeWidth, forKey: Key.edgeWidth) }
    }

    /// What happens when a timer finishes. Confetti plus a sound by default:
    /// the old behaviour was a single Glass ping, which undersold the moment.
    @Published var celebrationStyle: CelebrationStyle {
        didSet { defaults.set(celebrationStyle.rawValue, forKey: Key.celebrationStyle) }
    }

    /// The sound played alongside (or instead of) the confetti.
    @Published var timerSound: CelebrationSound {
        didSet { defaults.set(timerSound.rawValue, forKey: Key.timerSound) }
    }

    /// The last size and position the note had in a windowed mode.
    ///
    /// Edge mode rewrites the panel frame to fill the screen height, so without
    /// remembering this, leaving edge mode left the window stuck at full size.
    var windowedFrame: NSRect? {
        get {
            guard let raw = defaults.string(forKey: Key.windowFrame) else { return nil }
            let rect = NSRectFromString(raw)
            return rect.width > 100 && rect.height > 100 ? rect : nil
        }
        set {
            guard let newValue else { return }
            defaults.set(NSStringFromRect(newValue), forKey: Key.windowFrame)
        }
    }

    /// The keyword actually used for matching, never empty.
    var effectiveTimerKeyword: String {
        let trimmed = timerKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "timer" : trimmed
    }

    var effectivePomodoroKeyword: String {
        let trimmed = pomodoroKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "pomodoro" : trimmed
    }

    var effectiveReminderKeyword: String {
        let trimmed = reminderKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "remind" : trimmed
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Only the app's own defaults: an injected suite (every test) would
        // otherwise start from whatever the old domain holds on this machine.
        if defaults === UserDefaults.standard {
            Self.migrateFromPreviousBundleIDIfNeeded(into: defaults)
        }

        let rawMode = defaults.string(forKey: Key.displayMode) ?? DisplayMode.floating.rawValue
        self.displayMode = DisplayMode(rawValue: rawMode) ?? .floating

        let storedCode = defaults.object(forKey: Key.hotKeyCode) as? Int
        let storedMods = defaults.object(forKey: Key.hotKeyMods) as? Int
        if let storedCode, let storedMods, storedMods != 0 {
            self.hotKey = KeyCombo(keyCode: UInt32(storedCode), carbonModifiers: UInt32(storedMods))
        } else {
            self.hotKey = .default
        }

        self.timerKeyword = defaults.string(forKey: Key.timerKeyword) ?? "timer"
        self.pomodoroKeyword = defaults.string(forKey: Key.pomodoroKeyword) ?? "pomodoro"
        self.reminderKeyword = defaults.string(forKey: Key.reminderKeyword) ?? "remind"
        self.showsFooter = defaults.object(forKey: Key.showsFooter) as? Bool ?? true

        let rawAppearance = defaults.string(forKey: Key.appearance) ?? Appearance.frosted.rawValue
        self.appearance = Appearance(rawValue: rawAppearance) ?? .frosted
        self.glassTint = GlassTint(rawValue: defaults.string(forKey: Key.appearanceTint) ?? "") ?? .none
        self.showsHeader = defaults.object(forKey: Key.showsHeader) as? Bool ?? true
        self.lineSpacing = defaults.object(forKey: Key.lineSpacing) as? Double ?? 1.0
        self.noteFontName = defaults.string(forKey: Key.noteFontName) ?? NoteFont.defaultName
        self.noteFontSize = Self.clamped(
            defaults.object(forKey: Key.noteFontSize) as? Double ?? 13,
            to: Self.fontSizeRange
        )
        self.letterSpacing = defaults.object(forKey: Key.letterSpacing) as? Double ?? 0
        self.guide = PaperGuide(rawValue: defaults.string(forKey: Key.guide) ?? "") ?? .none

        self.syncsToAppleNotes = defaults.object(forKey: Key.syncsToNotes) as? Bool ?? false
        self.listKeyword = defaults.string(forKey: Key.listKeyword) ?? "list"
        self.codeKeyword = defaults.string(forKey: Key.codeKeyword) ?? CodeBlock.defaultKeyword
        self.fetchesLiveCurrencyRates = defaults.object(forKey: Key.fetchesLiveRates) as? Bool ?? false
        self.checksForUpdates = defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true

        let rawEdge = defaults.string(forKey: Key.screenEdge) ?? ScreenEdge.right.rawValue
        self.screenEdge = ScreenEdge(rawValue: rawEdge) ?? .right
        self.edgeWidth = defaults.object(forKey: Key.edgeWidth) as? Double ?? 340

        self.celebrationStyle =
            CelebrationStyle(rawValue: defaults.string(forKey: Key.celebrationStyle) ?? "") ?? .cannons
        self.timerSound =
            CelebrationSound(rawValue: defaults.string(forKey: Key.timerSound) ?? "") ?? .hero
    }

    // MARK: - Theme notes

    /// The appearance a `theme` note is imposing right now, or nil. Set at
    /// runtime from the note stack and never persisted — the theme lives only
    /// as long as its text does, which is the whole point of editing it live.
    @Published var themeOverride: ThemeNote.Theme?

    /// The paper actually on screen: a theme note's hex when one is active,
    /// otherwise the picked appearance's paper (nil meaning translucent).
    var effectivePaperColor: NSColor? {
        themeOverride?.paperHex ?? appearance.paperColor
    }

    /// The appearance the note's window must adopt so everything AppKit and
    /// SwiftUI colour for themselves (header buttons, the font menu, the
    /// stepper, scrollers, the find bar) agrees with the paper under them.
    ///
    /// An opaque paper forces its own ink whatever mode macOS is in; without
    /// this the controls kept the system's colours and vanished on a
    /// mismatched paper (True Dark in Light Mode measured about 1.1:1).
    /// Translucent papers return nil: they sit inside the system mode, which
    /// is exactly right for them. A theme's ink on a translucent paper is the
    /// one exception, since light ink needs a dark material under it.
    ///
    /// Light versus dark uses the same luminance rule `derivedInk` does, so a
    /// theme paper's derived ink and its controls always flip together.
    static func windowAppearanceName(for appearance: Appearance, theme: ThemeNote.Theme?) -> NSAppearance.Name? {
        func name(forSurface surface: NSColor) -> NSAppearance.Name {
            ThemeNote.luminance(of: surface) > 0.5 ? .aqua : .darkAqua
        }
        if let paper = theme?.paperHex ?? appearance.paperColor {
            return name(forSurface: paper)
        }
        if let ink = theme?.inkHex {
            return ThemeNote.luminance(of: ink) > 0.5 ? .darkAqua : .aqua
        }
        return nil
    }

    var effectiveWindowAppearanceName: NSAppearance.Name? {
        Self.windowAppearanceName(for: appearance, theme: themeOverride)
    }

    var effectiveMaterialRawValue: Int {
        appearance.materialRawValue
    }

    var effectiveInk: InkTheme {
        guard let override = themeOverride else { return appearance.ink }
        if let paper = override.paperHex {
            return override.inkHex.map {
                Self.ink(fromText: $0, on: [paper, effectiveChromeColor, effectiveCardColor])
            } ?? ThemeNote.derivedInk(for: paper)
        }
        // A tint or accent-only theme leaves the system ink alone unless the
        // user explicitly asked for different text.
        if let text = override.inkHex {
            // The window adopts the mode opposite the ink (see
            // `windowAppearanceName`), so that mode's backgrounds are the
            // surfaces its secondary has to read on.
            guard let mode = Self.windowAppearanceName(for: appearance, theme: override)
                .flatMap({ NSAppearance(named: $0) })
            else { return Self.ink(fromText: text) }
            let surfaces = [NSColor.windowBackgroundColor, .controlBackgroundColor]
                .map { Contrast.resolved($0, in: mode) }
            return Self.ink(fromText: text, on: surfaces)
        }
        return appearance.ink
    }

    /// Builds an InkTheme around one explicit text colour; the companions are
    /// neutral greys of it. When the paper is known the secondary is pushed
    /// toward the text until it clears 4.5:1 on it; the text itself is the
    /// user's explicit choice and is left alone.
    private static func ink(fromText text: NSColor, on surfaces: [NSColor] = []) -> InkTheme {
        func greyed(_ t: CGFloat) -> NSColor {
            let s = text.usingColorSpace(.sRGB)!
            let light = ThemeNote.luminance(of: text) > 0.5
            return NSColor(
                srgbRed: light ? s.redComponent * t : s.redComponent * t + (1 - t),
                green: light ? s.greenComponent * t : s.greenComponent * t + (1 - t),
                blue: light ? s.blueComponent * t : s.blueComponent * t + (1 - t),
                alpha: 1
            )
        }
        return InkTheme(
            text: text,
            secondary: surfaces.isEmpty ? greyed(0.55) : ThemeNote.ensuringContrast(greyed(0.55), toward: text, on: surfaces),
            accent: .controlAccentColor,
            link: NSColor(srgbRed: 0.100, green: 0.360, blue: 0.720, alpha: 1),
            guide: greyed(0.75)
        )
    }

    var effectiveChromeColor: NSColor {
        if let paper = themeOverride?.paperHex {
            return ThemeNote.derivedChromeColor(for: paper)
        }
        return appearance.chromeColor
    }

    var effectiveCardColor: NSColor {
        if let paper = themeOverride?.paperHex {
            return ThemeNote.derivedCardColor(for: paper)
        }
        return appearance.cardColor
    }

    var effectiveHairlineColor: NSColor {
        if themeOverride?.paperHex != nil {
            return ThemeNote.luminance(of: effectivePaperColor!) > 0.5 ? NSColor.black : NSColor.white
        }
        return appearance.hairlineColor
    }

    var effectiveWantsLitEdge: Bool {
        themeOverride?.paperHex == nil && appearance.wantsLitEdge
    }

    var effectiveWantsOpaqueCards: Bool {
        effectivePaperColor != nil || appearance == .solid
    }

    var effectiveTint: GlassTint {
        themeOverride?.tint ?? glassTint
    }

    // Typography: a theme note may carry its own font, size, spacing, and
    // tracking; anything it omits falls through to the picked values.

    var effectiveEditorFont: NSFont {
        NoteFont.resolved(effectiveNoteFontName, size: CGFloat(effectiveFontSize))
    }

    /// The stored font name, which may be curated or arbitrary — resolution
    /// happens in `NoteFont`.
    var effectiveNoteFontName: String {
        themeOverride?.fontName ?? noteFontName
    }

    var effectiveFontSize: Double {
        themeOverride?.fontSize ?? noteFontSize
    }

    var effectiveLineSpacing: Double {
        themeOverride?.lineSpacing ?? lineSpacing
    }

    var effectiveLetterSpacing: Double {
        themeOverride?.letterSpacing ?? letterSpacing
    }

    var effectiveGuide: PaperGuide {
        themeOverride?.guide ?? guide
    }

    // MARK: - Per-note typography

    /// Same precedence `effectiveNoteFontName`/`effectiveFontSize` already use,
    /// with one more rung: a theme note still wins outright (it is a
    /// deliberate whole-app statement), but between that and the picked
    /// default, a note's own choice now sits in the middle. `perNote` is
    /// `Note.fontName`/`fontSize` — nil for any note that has never had its
    /// own font set, which falls straight through to the old behaviour.
    func resolvedFontName(perNote: String?) -> String {
        themeOverride?.fontName ?? perNote ?? noteFontName
    }

    func resolvedFontSize(perNote: Double?) -> Double {
        themeOverride?.fontSize ?? perNote ?? noteFontSize
    }

    func resolvedEditorFont(perNoteName: String?, perNoteSize: Double?) -> NSFont {
        NoteFont.resolved(resolvedFontName(perNote: perNoteName), size: CGFloat(resolvedFontSize(perNote: perNoteSize)))
    }
}
