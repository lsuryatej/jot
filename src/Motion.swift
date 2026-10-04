import AppKit
import SwiftUI

extension Notification.Name {
    /// Reposted from NSWorkspace whenever the system's display accessibility
    /// options change, so anything with motion already on screen (a
    /// half-finished slide) can stand down the moment Reduce Motion turns
    /// on, not just the next time it starts.
    static let jotReduceMotionDidChange = Notification.Name("JotReduceMotionDidChange")
}

/// System Settings › Accessibility › Display › Reduce motion, decided in one
/// place.
///
/// AppKit call sites read `isEnabled` at the moment they animate, which keeps
/// them live without caching anything. SwiftUI views read
/// `@Environment(\.accessibilityReduceMotion)` instead, which SwiftUI already
/// keeps current, and hand that bool to `MotionPolicy` so the rule itself
/// stays in one testable place.
enum ReduceMotion {
    /// Set by tests to decide the answer without touching the real setting.
    /// Nil means ask the system.
    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        override ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    /// Forwards the system's change notification onto the default centre as
    /// `.jotReduceMotionDidChange`. Idempotent; called once at launch.
    static func startObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .jotReduceMotionDidChange, object: nil)
        }
    }
}

/// What each piece of motion becomes when Reduce Motion is on.
///
/// Apple's guidance is specific: keep fades, replace movement along x, y and
/// z with a fade, and drop automatic, repeated and peripheral motion. Opacity
/// changes therefore stay exactly as they were; anything that travels, scales
/// or scrolls by itself either becomes a fade or happens without animating.
enum MotionPolicy {

    /// How a transient chip (swipe feedback, reminder toast) enters and leaves.
    enum ToastTransition: Equatable {
        /// Fades while dropping in from the top edge.
        case slideAndFade
        /// Fades in place.
        case fade
    }

    static func toastTransition(reduceMotion: Bool) -> ToastTransition {
        reduceMotion ? .fade : .slideAndFade
    }

    /// The animation for a change that moves something across the screen:
    /// a scroll, a reorder, a scale. Nil under Reduce Motion, so
    /// `withAnimation(nil)` applies the change in one step.
    static func movement(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// The scale a card being dragged shrinks to. It is a depth cue, which is
    /// exactly the z-axis motion Reduce Motion asks to avoid; the carried
    /// card's dimming already says which one is moving.
    static func carriedCardScale(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : 0.985
    }

    /// How the Screen Edge sidebar arrives and leaves.
    enum EdgeReveal: Equatable {
        /// Travels in from beyond the screen edge, and back out the same way.
        case slide
        /// Sits docked in place and fades its alpha in and out.
        case fade
    }

    static func edgeReveal(reduceMotion: Bool) -> EdgeReveal {
        reduceMotion ? .fade : .slide
    }
}

extension AnyTransition {
    /// The toast chips' transition, per `MotionPolicy.toastTransition`.
    static func jotToast(reduceMotion: Bool) -> AnyTransition {
        switch MotionPolicy.toastTransition(reduceMotion: reduceMotion) {
        case .slideAndFade: return .opacity.combined(with: .move(edge: .top))
        case .fade:         return .opacity
        }
    }
}
