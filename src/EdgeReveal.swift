import AppKit

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

    // MARK: - One motion, two directions

    /// A frame and alpha the panel sits at, before or after a slide or fade.
    struct Pose: Equatable {
        var frame: CGRect
        var alpha: CGFloat
    }

    /// Where a hide leaves the panel: just past the edge at full alpha for a
    /// slide, docked and transparent for the Reduce Motion fade.
    static func concealTarget(style: MotionPolicy.EdgeReveal, frames: (docked: CGRect, hidden: CGRect)) -> Pose {
        switch style {
        case .slide: return Pose(frame: frames.hidden, alpha: 1)
        case .fade:  return Pose(frame: frames.docked, alpha: 0)
        }
    }

    /// Where a reveal lands: docked, fully opaque, whichever style.
    static func revealTarget(frames: (docked: CGRect, hidden: CGRect)) -> Pose {
        Pose(frame: frames.docked, alpha: 1)
    }

    /// Where a reveal starts. A fresh one starts exactly where a hide ends,
    /// so in and out are one path; one that reverses a hide still under way
    /// starts from wherever that hide has got to. A slide always runs at
    /// full alpha and a fade always stays docked, whatever an earlier,
    /// interrupted animation of the other style left behind.
    static func revealStart(
        style: MotionPolicy.EdgeReveal, interrupting: Bool,
        currentFrame: CGRect, currentAlpha: CGFloat,
        frames: (docked: CGRect, hidden: CGRect)
    ) -> Pose {
        let fresh = concealTarget(style: style, frames: frames)
        guard interrupting else { return fresh }
        switch style {
        case .slide: return Pose(frame: currentFrame, alpha: 1)
        case .fade:  return Pose(frame: frames.docked, alpha: currentAlpha)
        }
    }

    enum Direction {
        case reveal
        case conceal
    }

    /// The timing curve's two control points. The hide eases in (the
    /// system ease-in: slow to leave, then gone); the reveal is that exact
    /// curve reversed in time, so the sidebar arrives the way it leaves,
    /// played backwards, rather than on an unrelated curve.
    static func timing(_ direction: Direction) -> (c1: CGPoint, c2: CGPoint) {
        let hide = (c1: CGPoint(x: 0.42, y: 0), c2: CGPoint(x: 1, y: 1))
        switch direction {
        case .conceal:
            return hide
        case .reveal:
            return (c1: CGPoint(x: 1 - hide.c2.x, y: 1 - hide.c2.y),
                    c2: CGPoint(x: 1 - hide.c1.x, y: 1 - hide.c1.y))
        }
    }

    static func timingFunction(_ direction: Direction) -> CAMediaTimingFunction {
        let points = timing(direction)
        return CAMediaTimingFunction(
            controlPoints: Float(points.c1.x), Float(points.c1.y), Float(points.c2.x), Float(points.c2.y)
        )
    }

    /// How far along the path the curve is at time fraction `t`, the same
    /// way Core Animation evaluates it: solve the Bezier's x for t, read y.
    static func progress(_ direction: Direction, at t: Double) -> Double {
        let (c1, c2) = timing(direction)
        func bezier(_ a: Double, _ b: Double, _ s: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if bezier(Double(c1.x), Double(c2.x), mid) < t { lo = mid } else { hi = mid }
        }
        return bezier(Double(c1.y), Double(c2.y), (lo + hi) / 2)
    }

    /// When a reveal hands the panel the keyboard.
    enum KeyTiming: Equatable {
        /// Made key and first responder while still off screen (or fully
        /// transparent), so the redraw that key status and the caret cause
        /// is done before a single frame of the slide is visible. Keying it
        /// on landing redrew the note at the exact moment it came to rest.
        case beforeFirstFrame
        /// Never: the pointer brushed the edge; the keyboard stays put.
        case never
    }

    static func keyTiming(activating: Bool) -> KeyTiming {
        activating ? .beforeFirstFrame : .never
    }
}

/// Drives the edge sidebar's slide (or fade) one display frame at a time.
///
/// `NSAnimationContext` + `animator().setFrame` started in the same run-loop
/// turn as `orderFront` for a window that had just been off screen: AppKit
/// skipped the opening frames and the sidebar appeared most of the way in,
/// a pop, while the hide (started on a window already on screen) played in
/// full. Here both directions run the same per-frame code, and the first
/// display-link tick only records the start time, so frame one is drawn at
/// the starting pose after the window is really on screen.
@MainActor
final class EdgeSlideAnimator: NSObject {
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval?
    private weak var window: NSWindow?
    private var from = EdgeRevealGeometry.Pose(frame: .zero, alpha: 1)
    private var to = EdgeRevealGeometry.Pose(frame: .zero, alpha: 1)
    private var duration: TimeInterval = 0
    private var direction: EdgeRevealGeometry.Direction = .reveal
    private var completion: (() -> Void)?

    var isRunning: Bool { link != nil }

    /// Moves `window` from `from` to `to`. Starting another run, or calling
    /// `cancel()`, drops the pending completion: whatever took over owns the
    /// window now.
    func run(
        _ window: NSWindow,
        from: EdgeRevealGeometry.Pose, to: EdgeRevealGeometry.Pose,
        duration: TimeInterval, direction: EdgeRevealGeometry.Direction,
        completion: @escaping () -> Void
    ) {
        cancel()
        self.window = window
        self.from = from
        self.to = to
        self.duration = duration
        self.direction = direction
        self.completion = completion
        apply(from)

        guard duration > 0, let screen = window.screen ?? NSScreen.main else {
            apply(to)
            finish()
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func cancel() {
        link?.invalidate()
        link = nil
        startTime = nil
        completion = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let startTime else {
            // First tick: the window has now been composited at `from`.
            // Time starts here, not when `run` was called.
            self.startTime = link.timestamp
            return
        }
        let t = min(1, (link.targetTimestamp - startTime) / duration)
        let p = CGFloat(EdgeRevealGeometry.progress(direction, at: t))
        apply(EdgeRevealGeometry.Pose(
            frame: CGRect(
                x: from.frame.minX + (to.frame.minX - from.frame.minX) * p,
                y: from.frame.minY + (to.frame.minY - from.frame.minY) * p,
                width: from.frame.width + (to.frame.width - from.frame.width) * p,
                height: from.frame.height + (to.frame.height - from.frame.height) * p
            ),
            alpha: from.alpha + (to.alpha - from.alpha) * p
        ))
        if t >= 1 { finish() }
    }

    private func apply(_ pose: EdgeRevealGeometry.Pose) {
        guard let window else { return }
        // Same size: move only, so the SwiftUI content never re-lays out
        // mid-slide.
        if window.frame.size == pose.frame.size {
            window.setFrameOrigin(pose.frame.origin)
        } else {
            window.setFrame(pose.frame, display: true)
        }
        window.alphaValue = pose.alpha
    }

    private func finish() {
        let done = completion
        link?.invalidate()
        link = nil
        startTime = nil
        completion = nil
        done?()
    }
}

extension DisplayMode {
    /// Whether the user may drag the window around. A sidebar docked to a
    /// screen edge is a surface, not a window: dragging it off its edge left
    /// it floating somewhere the next reveal would snap it back from.
    var allowsWindowDrag: Bool {
        !isEdgeDocked
    }

    /// AppKit's own order-front animation. For a titled panel the system
    /// plays a short appear effect on `orderFront`, on top of whatever the
    /// app animates. Screen Edge brings the sidebar in with its own slide or
    /// fade, and the two together made the arrival pop, while the hide
    /// (which orders out only once the panel is already off screen) never
    /// showed it. Windowed modes keep the system's animation.
    var windowAnimationBehavior: NSWindow.AnimationBehavior {
        isEdgeDocked ? .none : .default
    }
}
