import Foundation
import Combine

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

    private enum Key {
        static let displayMode    = "displayMode"
        static let hotKeyCode     = "hotKeyCode"
        static let hotKeyMods     = "hotKeyModifiers"
        static let timerKeyword   = "timerKeyword"
        static let showsFooter    = "showsFooter"
        static let screenEdge     = "screenEdge"
        static let edgeWidth      = "edgeWidth"
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

    @Published var screenEdge: ScreenEdge {
        didSet { defaults.set(screenEdge.rawValue, forKey: Key.screenEdge) }
    }

    /// How wide the note is when docked to an edge.
    @Published var edgeWidth: Double {
        didSet { defaults.set(edgeWidth, forKey: Key.edgeWidth) }
    }

    /// The keyword actually used for matching, never empty.
    var effectiveTimerKeyword: String {
        let trimmed = timerKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "timer" : trimmed
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

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

        let rawEdge = defaults.string(forKey: Key.screenEdge) ?? ScreenEdge.right.rawValue
        self.screenEdge = ScreenEdge(rawValue: rawEdge) ?? .right
        self.edgeWidth = defaults.object(forKey: Key.edgeWidth) as? Double ?? 340
    }
}
