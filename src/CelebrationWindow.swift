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

    /// Plays the sound and shows the confetti. The sound fires even when the
    /// style is "sound only"; the confetti does not.
    static func fire(style: CelebrationStyle, sound: CelebrationSound) {
        Celebration.play(sound: sound)
        guard style != .none, let screen = NSScreen.main else { return }
        current?.dismiss()
        current = CelebrationWindowController(style: style, screen: screen)
        current?.run()
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
        window.orderOut(nil)
        Self.current = nil
    }

    private var emitterLayers: [CAEmitterLayer] {
        (window.contentView as? EmitterView)?.emitterLayers ?? []
    }
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
