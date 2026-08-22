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

/// How the note's surface is rendered.
enum Appearance: String, CaseIterable, Identifiable {
    /// The standard popover material: translucent but muted.
    case frosted
    /// Heavy pass-through of whatever is behind, with a lit edge.
    case glass
    /// Opaque window background, for when the desktop underneath is noisy.
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frosted: return "Frosted"
        case .glass:   return "Glass"
        case .solid:   return "Solid"
        }
    }

    var detail: String {
        switch self {
        case .frosted: return "Translucent, with the desktop softened behind it."
        case .glass:   return "The desktop shows through clearly, with a lit edge."
        case .solid:   return "Opaque. Easiest to read over a busy desktop."
        }
    }

    /// Matches NSVisualEffectView.Material.
    var materialRawValue: Int {
        switch self {
        case .frosted: return 6  // .popover
        case .glass:   return 13 // .hudWindow
        case .solid:   return 12 // .windowBackground
        }
    }

    var wantsLitEdge: Bool { self == .glass }
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
        static let showsFooter    = "showsFooter"
        static let screenEdge     = "screenEdge"
        static let edgeWidth      = "edgeWidth"
        static let appearance     = "appearance"
        static let showsHeader    = "showsHeader"
        static let lineSpacing    = "lineSpacing"
        static let windowFrame    = "windowFrame"
        static let syncsToNotes   = "syncsToAppleNotes"
        static let listKeyword    = "listKeyword"
        static let fetchesLiveRates = "fetchesLiveCurrencyRates"
        static let checksForUpdates = "checksForUpdates"

        /// Every key this type persists, for the one-time migration below.
        /// Kept as a literal list rather than reflection: `UserDefaults`
        /// domains accumulate unrelated system-set keys over time, and only
        /// the app's own keys should ever cross a bundle-ID migration.
        static let all: Set<String> = [
            displayMode, hotKeyCode, hotKeyMods, timerKeyword, showsFooter,
            screenEdge, edgeWidth, appearance, showsHeader, lineSpacing,
            windowFrame, syncsToNotes, listKeyword, fetchesLiveRates, checksForUpdates,
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

    @Published var showsFooter: Bool {
        didSet { defaults.set(showsFooter, forKey: Key.showsFooter) }
    }

    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateFromPreviousBundleIDIfNeeded(into: defaults)

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
        self.showsFooter = defaults.object(forKey: Key.showsFooter) as? Bool ?? true

        let rawAppearance = defaults.string(forKey: Key.appearance) ?? Appearance.frosted.rawValue
        self.appearance = Appearance(rawValue: rawAppearance) ?? .frosted
        self.showsHeader = defaults.object(forKey: Key.showsHeader) as? Bool ?? true
        self.lineSpacing = defaults.object(forKey: Key.lineSpacing) as? Double ?? 1.0

        self.syncsToAppleNotes = defaults.object(forKey: Key.syncsToNotes) as? Bool ?? false
        self.listKeyword = defaults.string(forKey: Key.listKeyword) ?? "list"
        self.fetchesLiveCurrencyRates = defaults.object(forKey: Key.fetchesLiveRates) as? Bool ?? false
        self.checksForUpdates = defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true

        let rawEdge = defaults.string(forKey: Key.screenEdge) ?? ScreenEdge.right.rawValue
        self.screenEdge = ScreenEdge(rawValue: rawEdge) ?? .right
        self.edgeWidth = defaults.object(forKey: Key.edgeWidth) as? Double ?? 340
    }
}
