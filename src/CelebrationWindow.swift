import AppKit
import QuartzCore

/// Puts a celebration on screen: a borderless, click-through window above
/// everything (screen-saver level, all spaces), `CAEmitterLayer`s inside it
/// running the chosen style's particles, and timers to take it all down.
///
/// This file is deliberately absent from the test binary's sources — building
/// an NSWindow headlessly hangs, so everything with rules to test lives in
/// `Celebration` instead. This is only the plumbing that turns the numbers
/// into pixels.
final class CelebrationWindowController {
    private let window: NSWindow
    private let duration: TimeInterval
    /// Kept alive while its window is on screen; replaced when a new
    /// celebration starts mid-flight.
    nonisolated(unsafe) private static var current: CelebrationWindowController?
    private var stopEmittingItem: DispatchWorkItem?
    private var dismissItem: DispatchWorkItem?
    private var reduceMotionObserver: NSObjectProtocol?

    /// Plays the sound and shows the confetti. The sound fires even when the
    /// style is "sound only"; the confetti does not.
    ///
    /// Under Reduce Motion there is no confetti at all: full-screen particles
    /// at screen-saver level, repeated at every Pomodoro phase, are exactly
    /// the peripheral, repetitive motion the setting exists to stop. A small
    /// still badge near the note marks the moment instead, fading in and out
    /// by opacity alone. `title` is what that badge says.
    static func fire(style: CelebrationStyle, sound: CelebrationSound, title: String = Celebration.badgeTitle(endingPhase: nil)) {
        Celebration.play(sound: sound)
        switch Celebration.presentation(for: style, reduceMotion: ReduceMotion.isEnabled) {
        case .soundOnly:
            return
        case .badge:
            current?.dismiss()
            CelebrationBadgeController.show(title: title)
        case .particles:
            guard let screen = NSScreen.main else { return }
            current?.dismiss()
            current = CelebrationWindowController(style: style, screen: screen)
            current?.run()
        }
    }

    private init(style: CelebrationStyle, screen: NSScreen) {
        duration = Celebration.duration(for: style)

        let frame = screen.frame
        window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // A celebration must never steal focus or eat a click meant for
        // whatever is underneath — including the note that started the timer.
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(frame, display: false)

        window.contentView = EmitterView(style: style, screenBounds: frame)
    }

    private func run() {
        window.orderFrontRegardless()

        // Reduce Motion switched on mid-celebration takes the confetti down
        // at once rather than letting it finish flying.
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: .jotReduceMotionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard ReduceMotion.isEnabled else { return }
            self?.dismiss()
        }

        // Stop emitting halfway so the tail of the celebration tapers instead
        // of being cut off by the dismiss.
        let stop = DispatchWorkItem { [weak self] in
            self?.emitterLayers.forEach { $0.birthRate = 0 }
        }
        stopEmittingItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + duration / 2, execute: stop)

        let dismiss = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    func dismiss() {
        stopEmittingItem?.cancel()
        dismissItem?.cancel()
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
            self.reduceMotionObserver = nil
        }
        window.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    private var emitterLayers: [CAEmitterLayer] {
        (window.contentView as? EmitterView)?.emitterLayers ?? []
    }
}

/// Reduce Motion's celebration: a small HUD badge with a checkmark and a few
/// words, placed near the note, that fades in, holds, and fades out. Nothing
/// on it moves; only its opacity changes. Like the confetti window it takes no
/// clicks and never becomes key, so it cannot steal focus or a keystroke.
final class CelebrationBadgeController {
    nonisolated(unsafe) private static var current: CelebrationBadgeController?

    private let window: NSPanel
    private var holdItem: DispatchWorkItem?
    /// Bumped by every fade, so a fade-out that finishes after a newer badge
    /// has taken over does not order that newer badge out.
    private var generation = 0

    static func show(title: String) {
        current?.window.orderOut(nil)
        current?.holdItem?.cancel()
        let badge = CelebrationBadgeController(title: title)
        current = badge
        badge.run()
    }

    private init(title: String) {
        let content = BadgeView(title: title)
        let size = content.fittingSize
        let panel = NSApp.windows.first { $0 is FloatingPanel && $0.isVisible && $0.alphaValue > 0 }
        let panelFrame = panel?.frame
        let screen = panel?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Celebration.badgeFrame(size: size, panelFrame: panelFrame, visibleFrame: visible)

        window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the note's own floating panel, below the menu bar's menus.
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = content
        window.alphaValue = 0
    }

    private func run() {
        window.orderFrontRegardless()
        let timing = Celebration.badgeTiming
        fade(to: 1, duration: timing.fadeIn) { [weak self] in
            guard let self else { return }
            let hold = DispatchWorkItem { [weak self] in
                self?.fade(to: 0, duration: timing.fadeOut) { [weak self] in
                    guard let self else { return }
                    self.window.orderOut(nil)
                    if Self.current === self { Self.current = nil }
                }
            }
            self.holdItem = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + timing.hold, execute: hold)
        }
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, then completion: @escaping () -> Void) {
        generation += 1
        let mine = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            guard let self, self.generation == mine else { return }
            completion()
        }
    }
}

/// The badge's content: SF Symbol checkmark and a short title on HUD glass.
private final class BadgeView: NSVisualEffectView {
    init(title: String) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        icon.contentTintColor = .labelColor
        icon.setAccessibilityElement(false)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layoutSubtreeIfNeeded()
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { nil }
}

/// One view holding every emitter layer the style needs — two for Cannons
/// (one per bottom corner), one otherwise.
private final class EmitterView: NSView {
    fileprivate private(set) var emitterLayers: [CAEmitterLayer] = []

    init(style: CelebrationStyle, screenBounds: CGRect) {
        super.init(frame: screenBounds)
        wantsLayer = true
        emitterLayers = Self.makeEmitterLayers(style: style, screenBounds: screenBounds)
        for layer in emitterLayers {
            self.layer?.addSublayer(layer)
        }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Emitter construction

    /// A small white scrap of paper; each emitter cell tints its own copy.
    private static let templateImage: CGImage? = {
        let size = CGSize(width: 13, height: 9)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()

    private static func makeEmitterLayers(style: CelebrationStyle, screenBounds: CGRect) -> [CAEmitterLayer] {
        switch style {
        case .cannons:
            return [
                cannonLayer(cornerXFraction: 0.02, screenBounds: screenBounds),
                cannonLayer(cornerXFraction: 0.98, screenBounds: screenBounds),
            ]
        case .rain:
            let layer = baseLayer(screenBounds: screenBounds)
            // A line across the whole top edge.
            place(layer, xFraction: 0.5, yFraction: 1.0, xSpread: 1.0, ySpread: 0.02,
                  screenBounds: screenBounds)
            layer.emitterMode = .surface
            layer.emitterCells = cells(
                birthPerCell: 9,
                velocity: Celebration.velocity(for: style),
                lifetime: Celebration.lifetime(for: style),
                gravity: Celebration.gravity(for: style),
                longitude: -.pi / 2, longitudeRange: 0.22, sway: true
            )
            return [layer]
        case .burst:
            let layer = baseLayer(screenBounds: screenBounds)
            // Dead centre, full circle.
            place(layer, xFraction: 0.5, yFraction: 0.5, xSpread: 0.02, ySpread: 0.02,
                  screenBounds: screenBounds)
            layer.emitterMode = .points
            layer.emitterCells = cells(
                birthPerCell: 34,
                velocity: Celebration.velocity(for: style),
                lifetime: Celebration.lifetime(for: style),
                gravity: Celebration.gravity(for: style),
                longitude: 0, longitudeRange: .pi * 2, sway: false
            )
            return [layer]
        case .none:
            return []
        }
    }

    /// One jet firing up from near a bottom corner.
    private static func cannonLayer(cornerXFraction: CGFloat, screenBounds: CGRect) -> CAEmitterLayer {
        let layer = baseLayer(screenBounds: screenBounds)
        place(layer, xFraction: cornerXFraction, yFraction: 0.98, xSpread: 0.05, ySpread: 0.04,
              screenBounds: screenBounds)
        layer.emitterMode = .points
        layer.emitterCells = cells(
            birthPerCell: 12,
            velocity: Celebration.velocity(for: .cannons),
            lifetime: Celebration.lifetime(for: .cannons),
            gravity: Celebration.gravity(for: .cannons),
            longitude: .pi / 2, longitudeRange: 0.32, sway: false
        )
        return layer
    }

    private static func baseLayer(screenBounds: CGRect) -> CAEmitterLayer {
        let layer = CAEmitterLayer()
        layer.frame = CGRect(origin: .zero, size: screenBounds.size)
        layer.emitterShape = .rectangle
        return layer
    }

    /// Positions a layer from screen fractions whose y grows upward,
    /// NSScreen style; layers grow y downward, hence the flip.
    private static func place(
        _ layer: CAEmitterLayer, xFraction: CGFloat, yFraction: CGFloat,
        xSpread: CGFloat, ySpread: CGFloat, screenBounds: CGRect
    ) {
        layer.emitterPosition = CGPoint(
            x: xFraction * screenBounds.width,
            y: (1 - yFraction) * screenBounds.height
        )
        layer.emitterSize = CGSize(
            width: xSpread * screenBounds.width,
            height: ySpread * screenBounds.height
        )
    }

    private static func cells(
        birthPerCell: Float,
        velocity: (base: CGFloat, range: CGFloat),
        lifetime: (base: Double, range: Double),
        gravity: CGFloat,
        longitude: CGFloat, longitudeRange: CGFloat,
        sway: Bool
    ) -> [CAEmitterCell] {
        guard let template = templateImage else { return [] }
        return Celebration.colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = template
            cell.color = color.cgColor
            cell.birthRate = birthPerCell
            cell.velocity = velocity.base
            cell.velocityRange = velocity.range
            cell.lifetime = Float(lifetime.base)
            cell.lifetimeRange = Float(lifetime.range)
            cell.yAcceleration = gravity
            cell.spin = 6
            cell.spinRange = 12
            cell.scaleRange = 0.6
            cell.scale = 1.1
            // Fade out over roughly the particle's life rather than vanish.
            cell.alphaSpeed = Float(-1.2 / max(lifetime.base, 0.001))
            cell.emissionLongitude = longitude
            cell.emissionRange = longitudeRange
            if sway { cell.xAcceleration = 60 }  // rain drifts lazily sideways
            return cell
        }
    }
}
