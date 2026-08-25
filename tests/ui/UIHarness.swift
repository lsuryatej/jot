import AppKit
import CryptoKit
import Foundation

// The window harness. Separate binary from ./test.sh's suite, with its own
// pass/fail counters, because these tests need a real NSApplication, a real
// window, and a real run loop — all of which cost seconds rather than
// milliseconds and are exactly what the fast suite is built to avoid.
//
// The old claim in tests/UILayerTests.swift that constructing an NSWindow in a
// swiftc-built CLI binary hangs indefinitely is wrong. It hangs only if you
// skip the NSApplication startup dance below. With that in place, windows come
// up, hit-testing works, and synthetic events sent via NSApp.sendEvent route
// through real AppKit dispatch into real SwiftUI button actions. No
// accessibility permission is involved, because nothing leaves the process.

// MARK: - Assertions

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)  (\(file):\(line))")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if actual == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
        print("         expected: \(expected)")
        print("         actual:   \(actual)")
    }
}

func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

// MARK: - Application lifetime

/// Brings up an NSApplication suitable for hosting real windows from a plain
/// command-line binary. `.accessory` keeps the run out of the Dock and out of
/// the user's way; `finishLaunching()` is the piece whose absence makes window
/// creation appear to hang.
@MainActor
func startApplication() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
}

/// Runs the real run loop for `seconds`, dispatching whatever events are
/// waiting. Needed after ordering a window front (so it can actually become
/// key) and after every synthetic interaction (so SwiftUI can re-render before
/// anything is measured).
@MainActor
func pump(_ seconds: Double = 0.3) {
    let app = NSApplication.shared
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        while let event = app.nextEvent(matching: .any,
                                        until: Date(timeIntervalSinceNow: 0.005),
                                        inMode: .default,
                                        dequeue: true) {
            app.sendEvent(event)
        }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
}

// MARK: - Interaction

/// A real left click at `point`, in window coordinates (bottom-left origin).
/// Goes through NSApp.sendEvent, so AppKit hit-tests it exactly as it would a
/// click from a human, and a SwiftUI Button underneath it genuinely fires.
@MainActor
func click(_ window: NSWindow, at point: NSPoint) {
    let app = NSApplication.shared
    let phases: [(NSEvent.EventType, Int, Float)] = [
        (.leftMouseDown, 1, 1),
        (.leftMouseUp, 2, 0)
    ]
    for (kind, number, pressure) in phases {
        if let event = NSEvent.mouseEvent(
            with: kind,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: number,
            clickCount: 1,
            pressure: pressure
        ) {
            app.sendEvent(event)
        }
    }
    pump(0.25)
}

// MARK: - Observing rendered state

/// SwiftUI does not vend its child elements through the accessibility tree
/// unless a real assistive client is attached, so there is no way to ask "which
/// pane is showing" structurally. Hashing the rendered pixels answers the same
/// question and is stable run to run.
@MainActor
func renderHash(_ view: NSView) -> String {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "norep" }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return "nopng" }
    return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
}

/// Directory for failure artifacts. A failing layout test is far easier to
/// diagnose from a PNG than from a hash mismatch, so failures leave one behind
/// and print the path.
let artifactDirectory: URL = {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jot-ui-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

/// Writes the view's current rendering to a PNG under `artifactDirectory` and
/// returns the path, or nil if it could not be captured.
@MainActor
@discardableResult
func saveRender(_ view: NSView, named name: String) -> String? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = artifactDirectory.appendingPathComponent("\(name).png")
    do {
        try data.write(to: url)
        return url.path
    } catch {
        return nil
    }
}

/// The rendered bitmap of a view, in its own points, with a scale factor for
/// converting point coordinates into bitmap pixels on a Retina backing.
@MainActor
func renderBitmap(_ view: NSView) -> (rep: NSBitmapImageRep, scaleX: CGFloat, scaleY: CGFloat)? {
    guard view.bounds.width > 0, view.bounds.height > 0,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return (rep, CGFloat(rep.pixelsWide) / view.bounds.width, CGFloat(rep.pixelsHigh) / view.bounds.height)
}

/// Measures where the settings sidebar actually ends, by finding the vertical
/// `Divider()` between the sidebar and the pane in the rendered pixels.
///
/// This is deliberately a pixel measurement rather than a read of the declared
/// `.frame(width: 172)`: the whole point is to catch the case where SwiftUI
/// declares one width and lays out another because a pane's intrinsic content
/// overflows the window and squeezes the sidebar. `yFromTop` should sit in the
/// empty region below the last sidebar row, so nothing but the two backgrounds
/// and the divider is on that scanline.
@MainActor
func measuredSidebarWidth(_ view: NSView, yFromTop: CGFloat) -> CGFloat? {
    guard let (rep, scaleX, scaleY) = renderBitmap(view) else { return nil }
    let row = Int((yFromTop * scaleY).rounded())
    guard row >= 0, row < rep.pixelsHigh else { return nil }

    func luminance(_ x: Int) -> CGFloat? {
        guard let color = rep.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { return nil }
        return 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
    }

    // Scan a generous window either side of the declared sidebar width and take
    // the sharpest column-to-column contrast step as the divider.
    let limit = min(rep.pixelsWide - 1, Int(320 * scaleX))
    var bestX = 0
    var bestDelta: CGFloat = 0
    var previous = luminance(0)
    for x in 1...max(1, limit) {
        guard let current = luminance(x), let before = previous else { previous = luminance(x); continue }
        let delta = abs(current - before)
        if delta > bestDelta {
            bestDelta = delta
            bestX = x
        }
        previous = current
    }
    guard bestDelta > 0.02 else { return nil }
    return CGFloat(bestX) / scaleX
}
