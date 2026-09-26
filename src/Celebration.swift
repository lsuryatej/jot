import AppKit
import QuartzCore

/// What happens when a timer runs out, beyond the bare ping it used to be.
///
/// A finished timer is a small victory — the note said you would do a thing
/// and you did — so the app treats it like one: a sound and a short burst of
/// confetti over everything else on screen. The window takes no input and
/// closes itself, so the celebration costs the user nothing but three
/// seconds of joy.
enum CelebrationStyle: String, CaseIterable, Identifiable {
    /// Two jets firing up from the bottom corners.
    case cannons
    /// A slow drift down from the top edge.
    case rain
    /// One radial pop from the centre of the screen.
    case burst
    /// Sound only.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cannons: return "Cannons"
        case .rain:    return "Rain"
        case .burst:   return "Burst"
        case .none:    return "Sound only"
        }
    }

    var detail: String {
        switch self {
        case .cannons: return "Two jets of confetti fire up from the bottom corners."
        case .rain:    return "Confetti drifts down from the top of the screen."
        case .burst:   return "A single pop of confetti from the middle of the screen."
        case .none:    return "Just the sound."
        }
    }
}

/// The sounds offered alongside the confetti, all shipping with macOS.
///
/// Curated rather than every sound on disk: a picker of fourteen near-identical
/// pings is not a choice, it is homework.
enum CelebrationSound: String, CaseIterable, Identifiable {
    case hero
    case funk
    case purr
    case pop
    case bottle
    case submarine
    case glass
    case ping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hero:      return "Hero"
        case .funk:      return "Funk"
        case .purr:      return "Purr"
        case .pop:       return "Pop"
        case .bottle:    return "Bottle"
        case .submarine: return "Submarine"
        case .glass:     return "Glass"
        case .ping:      return "Ping"
        }
    }

    /// The NSSound name this maps to, by system convention lowercase title.
    var systemName: String { title }
}

/// Everything about a celebration except actually showing it, so the rules
/// are testable headlessly.
enum Celebration {

    /// The confetti palette. Warm-leaning and slightly desaturated so it
    /// reads as paper scraps, not casino lights.
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.000, green: 0.820, blue: 0.400, alpha: 1),
        NSColor(srgbRed: 0.937, green: 0.278, blue: 0.435, alpha: 1),
        NSColor(srgbRed: 0.024, green: 0.839, blue: 0.627, alpha: 1),
        NSColor(srgbRed: 0.067, green: 0.541, blue: 0.698, alpha: 1),
        NSColor(srgbRed: 1.000, green: 0.973, blue: 0.925, alpha: 1),
    ]

    /// Emitter birthplaces for a style, as fractions of screen size —
    /// (x, y, spread across that axis). The presentation layer turns these
    /// into points.
    struct Origin: Equatable {
        var xFraction: CGFloat
        var yFraction: CGFloat
        var xSpread: CGFloat
        var ySpread: CGFloat
    }

    static func origins(for style: CelebrationStyle) -> [Origin] {
        switch style {
        case .cannons:
            // Two corners, aimed inward and up.
            return [
                Origin(xFraction: 0.02, yFraction: 0.98, xSpread: 0.05, ySpread: 0.04),
                Origin(xFraction: 0.98, yFraction: 0.98, xSpread: 0.05, ySpread: 0.04),
            ]
        case .rain:
            // A line across the whole top edge.
            return [Origin(xFraction: 0.5, yFraction: 1.0, xSpread: 1.0, ySpread: 0.02)]
        case .burst:
            // Dead centre, one hole.
            return [Origin(xFraction: 0.5, yFraction: 0.5, xSpread: 0.02, ySpread: 0.02)]
        case .none:
            // No window is ever built for this style, so there is nowhere
            // to emit from.
            return []
        }
    }

    /// Initial speed in points per second, and how much it varies.
    static func velocity(for style: CelebrationStyle) -> (base: CGFloat, range: CGFloat) {
        switch style {
        case .cannons: return (900, 260)
        case .rain:    return (60, 30)
        case .burst:   return (700, 400)
        case .none:    return (0, 0)
        }
    }

    /// Downward pull. Rain barely falls under gravity because it is already
    /// falling; a burst needs almost none because it is over too fast.
    static func gravity(for style: CelebrationStyle) -> CGFloat {
        switch style {
        case .cannons: return 1200
        case .rain:    return 90
        case .burst:   return 500
        case .none:    return 0
        }
    }

    /// How long the particles live, and therefore roughly how long the
    /// window stays up.
    static func lifetime(for style: CelebrationStyle) -> (base: Double, range: Double) {
        switch style {
        case .cannons: return (2.4, 0.8)
        case .rain:    return (3.2, 0.6)
        case .burst:   return (1.8, 0.5)
        case .none:    return (0, 0)
        }
    }

    /// Seconds the celebration window remains on screen: the longest particle
    /// life plus a beat of fade-out.
    static func duration(for style: CelebrationStyle) -> TimeInterval {
        let life = lifetime(for: style)
        return life.base + life.range + 0.4
    }

    // MARK: - Reduce Motion

    /// What actually goes on screen when a celebration fires.
    enum Presentation: Equatable {
        /// The sound and nothing else.
        case soundOnly
        /// The sound plus the style's full-screen confetti.
        case particles
        /// The sound plus a small, still badge near the note that fades in
        /// and out. Reduce Motion's replacement for confetti: the moment is
        /// still marked, without anything flying across the screen.
        case badge
    }

    static func presentation(for style: CelebrationStyle, reduceMotion: Bool) -> Presentation {
        guard style != .none else { return .soundOnly }
        return reduceMotion ? .badge : .particles
    }

    /// The badge's words, which the confetti never needed: without the
    /// motion, a plain checkmark alone does not say which timer just ended.
    /// `endingPhase` is the Pomodoro phase that ran out, nil for a plain timer.
    static func badgeTitle(endingPhase: PomodoroPhase?) -> String {
        switch endingPhase {
        case .work: return "Time for a break"
        case .rest: return "Back to work"
        case nil:   return "Time's up"
        }
    }

    static let reminderBadgeTitle = "Reminder"

    /// Seconds for each part of the badge's life: fade in, hold, fade out.
    static let badgeTiming: (fadeIn: TimeInterval, hold: TimeInterval, fadeOut: TimeInterval) = (0.2, 1.8, 0.35)

    /// Where the badge sits: centred across the note's panel, a little below
    /// its top edge, when the panel is on screen; otherwise centred near the
    /// top of the screen. Always clamped inside the visible frame, so a panel
    /// pushed half off screen never takes the badge with it.
    static func badgeFrame(size: CGSize, panelFrame: CGRect?, visibleFrame: CGRect) -> CGRect {
        let anchorMidX = panelFrame?.midX ?? visibleFrame.midX
        let topY = panelFrame.map { $0.maxY - 52 } ?? (visibleFrame.maxY - 80)
        var x = anchorMidX - size.width / 2
        var y = topY - size.height
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        y = min(max(y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Plays the chosen sound. Safe to call with any style; only the sound is
    /// this function's business.
    static func play(sound: CelebrationSound) {
        NSSound(named: sound.systemName)?.play()
    }
}
