import AppKit

/// The strip that lives against a screen edge and reveals the note.
///
/// One window serves both reveal paths: the whole strip is the hot side, so
/// pushing the cursor into the edge triggers it, and a handle is drawn in the
/// middle so there is something visible to aim at and click.
final class EdgeTriggerView: NSView {
    /// `activating` is false for the hot side and true for a deliberate click.
    var onReveal: ((_ activating: Bool) -> Void)?

    /// How long the cursor must rest against the edge before the note appears.
    /// Without this, merely sweeping the pointer across the screen fires it.
    private static let dwell: TimeInterval = 0.25
    private var dwellTimer: Timer?
    var edge: ScreenEdge = .right {
        didSet { needsDisplay = true }
    }

    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // .activeAlways so the strip works while another app is frontmost,
        // which is the entire point of a hot side.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: Self.dwell, repeats: false) { [weak self] _ in
            // Revealed without activating: the note appears, but whatever the
            // user is typing in keeps the keyboard.
            self?.onReveal?(false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    override func mouseDown(with event: NSEvent) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        // Clicking the bar is deliberate, so this one does take focus.
        onReveal?(true)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A short capsule at the vertical midpoint: visible enough to find,
        // quiet enough to forget. As wide as the strip, which is all there
        // is to draw in; the pointer stops against the edge, so a thin
        // target there is as easy to hit as a wide one.
        let handleHeight: CGFloat = 64
        let handleWidth = min(4, bounds.width)
        let x = edge == .right ? bounds.maxX - handleWidth : bounds.minX
        let handle = NSRect(
            x: x,
            y: bounds.midY - handleHeight / 2,
            width: handleWidth,
            height: handleHeight
        )

        let color = isHighlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.85)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.35)
        color.setFill()
        NSBezierPath(roundedRect: handle, xRadius: handleWidth / 2, yRadius: handleWidth / 2).fill()
    }
}

/// Borderless always-on-top window holding the trigger strip.
final class EdgeTriggerWindow: NSPanel {
    private let triggerView = EdgeTriggerView()

    init(onReveal: @escaping (_ activating: Bool) -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        // Present on every Space and over fullscreen apps, and never a
        // Cmd-Tab or Mission Control participant.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        isMovable = false

        triggerView.onReveal = onReveal
        contentView = triggerView
    }

    /// Places the strip at `frame`, one of `EdgeTriggerGeometry.strips`.
    func position(at frame: CGRect, edge: ScreenEdge) {
        triggerView.edge = edge
        guard self.frame != frame else { return }
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the trigger strips go, and which display a reveal belongs on.
///
/// Pure functions over screen rectangles (AppKit's global, bottom-left
/// origin coordinates), so the rules are testable without a window server.
enum EdgeTriggerGeometry {
    /// Thin enough that a window flush with the edge keeps its scroller:
    /// the old 6pt strip sat over the outer 6pt of it and took its clicks.
    /// The pointer stops on the screen's last column of pixels, which a
    /// 2pt strip still covers, so pushing into the edge still finds it.
    static let stripWidth: CGFloat = 2

    /// A stretch of open edge shorter than this gets no strip: too short to
    /// aim at, and too short for the handle drawn in its middle.
    static let minimumStripLength: CGFloat = 80

    /// One strip for every stretch of `edge` that really is the edge of the
    /// desktop, on every display.
    ///
    /// Where another display continues past that edge the pointer does not
    /// stop there, it crosses into the neighbour, so a strip on the seam
    /// would fire on every pass and only steal clicks. A display that is
    /// only partly flanked keeps a strip along the stretch that is open.
    static func strips(screens: [(frame: CGRect, visible: CGRect)], edge: ScreenEdge) -> [CGRect] {
        var result: [CGRect] = []
        for (index, screen) in screens.enumerated() {
            var open = [screen.visible.minY...screen.visible.maxY]
            for (otherIndex, other) in screens.enumerated() where otherIndex != index {
                let touches = edge == .right
                    ? abs(other.frame.minX - screen.frame.maxX) < 1
                    : abs(other.frame.maxX - screen.frame.minX) < 1
                guard touches else { continue }
                open = open.flatMap { subtract(other.frame.minY...other.frame.maxY, from: $0) }
            }
            let x = edge == .right ? screen.visible.maxX - stripWidth : screen.visible.minX
            for span in open where span.upperBound - span.lowerBound >= minimumStripLength {
                result.append(CGRect(
                    x: x, y: span.lowerBound,
                    width: stripWidth, height: span.upperBound - span.lowerBound
                ))
            }
        }
        return result
    }

    /// The display under `point` (the pointer), so a reveal from the hot
    /// key or the menu bar lands where the user is looking. A point on a
    /// display's top or right boundary belongs to no half-open rectangle,
    /// and the pointer can sit there, so failing an exact hit the nearest
    /// display wins.
    static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        if let hit = frames.firstIndex(where: { $0.contains(point) }) { return hit }
        func distance(_ rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
    }

    private static func subtract(
        _ cut: ClosedRange<CGFloat>, from span: ClosedRange<CGFloat>
    ) -> [ClosedRange<CGFloat>] {
        guard cut.lowerBound < span.upperBound, cut.upperBound > span.lowerBound else { return [span] }
        var pieces: [ClosedRange<CGFloat>] = []
        if cut.lowerBound > span.lowerBound { pieces.append(span.lowerBound...cut.lowerBound) }
        if cut.upperBound < span.upperBound { pieces.append(cut.upperBound...span.upperBound) }
        return pieces
    }
}
