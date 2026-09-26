import Foundation
import CoreGraphics

/// Which of the Screen Edge sidebar's show/hide animations is still in charge.
///
/// Both directions animate, and either can be interrupted by the other: the
/// pointer leaves mid-slide, or the hot key is pressed again while it slides
/// away. AppKit still fires an interrupted animation's completion handler, so
/// without this the reveal's completion focused and keyed a panel that
/// `hideInterface()` had already sent away (design review H5). Every start
/// bumps `generation`; a completion carrying an older number is stale and
/// does nothing.
struct EdgeRevealState {
    enum Phase: Equatable {
        case hidden
        case revealing
        case shown
        case concealing
    }

    private(set) var phase: Phase = .hidden
    private(set) var generation = 0

    /// Coming out or already out. Concealing counts as gone: a hide has been
    /// asked for, so another toggle means show.
    var isArrivingOrShown: Bool {
        phase == .revealing || phase == .shown
    }

    /// Starts (or reverses into) a reveal. Returns the token its completion
    /// must hand to `finish`.
    mutating func beginReveal() -> Int {
        generation += 1
        phase = .revealing
        return generation
    }

    /// Starts (or reverses into) a hide. Nil when there is nothing to hide
    /// or a hide is already under way.
    mutating func beginConceal() -> Int? {
        guard isArrivingOrShown else { return nil }
        generation += 1
        phase = .concealing
        return generation
    }

    /// Called from an animation's completion. True only when that animation
    /// is still the current one, in which case its phase lands.
    mutating func finish(_ token: Int) -> Bool {
        guard token == generation else { return false }
        switch phase {
        case .revealing:  phase = .shown
        case .concealing: phase = .hidden
        case .hidden, .shown: return false
        }
        return true
    }

    /// Hidden at once, no animation (a display mode switch). Every pending
    /// completion becomes stale.
    mutating func reset() {
        generation += 1
        phase = .hidden
    }
}

/// Where the edge sidebar sits and how long it takes to get there.
enum EdgeRevealGeometry {
    /// One full slide or fade, in either direction.
    static let duration: TimeInterval = 0.18

    /// Docked flush against the edge at full visible height, and the same
    /// rectangle pushed just past that edge. In and out travel the straight
    /// line between the two.
    static func frames(visible: CGRect, width: CGFloat, edge: ScreenEdge) -> (docked: CGRect, hidden: CGRect) {
        let dockedX = edge == .right ? visible.maxX - width : visible.minX
        let hiddenX = edge == .right ? visible.maxX : visible.minX - width
        return (
            docked: CGRect(x: dockedX, y: visible.minY, width: width, height: visible.height),
            hidden: CGRect(x: hiddenX, y: visible.minY, width: width, height: visible.height)
        )
    }

    /// The time for the distance left, so a slide reversed halfway takes half
    /// the time and keeps the same speed instead of lurching.
    static func slideDuration(fromX: CGFloat, toX: CGFloat, frames: (docked: CGRect, hidden: CGRect)) -> TimeInterval {
        let path = abs(frames.docked.minX - frames.hidden.minX)
        guard path > 0 else { return 0 }
        let fraction = min(1, abs(toX - fromX) / path)
        return duration * Double(fraction)
    }

    /// The same rule for the Reduce Motion fade, over alpha instead of x.
    static func fadeDuration(fromAlpha: CGFloat, toAlpha: CGFloat) -> TimeInterval {
        duration * Double(min(1, abs(toAlpha - fromAlpha)))
    }
}

extension DisplayMode {
    /// Whether the user may drag the window around. A sidebar docked to a
    /// screen edge is a surface, not a window: dragging it off its edge left
    /// it floating somewhere the next reveal would snap it back from.
    var allowsWindowDrag: Bool {
        !isEdgeDocked
    }
}
