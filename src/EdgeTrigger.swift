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
        // quiet enough to forget.
        let handleHeight: CGFloat = 64
        let handleWidth: CGFloat = 4
        let x = edge == .right ? bounds.maxX - handleWidth - 1 : 1
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

    /// Full height of the usable screen, a few points wide.
    func position(on edge: ScreenEdge, screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let width: CGFloat = 6
        let x = edge == .right ? visible.maxX - width : visible.minX
        triggerView.edge = edge
        setFrame(
            NSRect(x: x, y: visible.minY, width: width, height: visible.height),
            display: true
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
