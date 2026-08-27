import AppKit
import Foundation

// Real repro attempt for the backlog's open bug: "Dragging an inline image
// to resize it does not reliably work." The whole mechanism —
// `handleSpecialClick` hit-testing the image, `beginResize` tracking the drag
// via `window?.trackEvents(matching:)`, and the mouse-up rewrite through
// `Attachments.settingWidth` — depends on a real window and a real drag
// sequence delivered to that specific window's local event queue, which is
// exactly what `./test.sh`'s pure-logic suite cannot create. This drives an
// actual mouseDown/mouseDragged/mouseUp sequence through a real key window.

@MainActor
private func writeTestImage(width: Int = 200, height: Int = 100) -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jot-ui-tests-\(UUID().uuidString)")
    let attachmentsDir = directory.appendingPathComponent("Attachments", isDirectory: true)
    try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()

    let tiff = image.tiffRepresentation!
    let bitmap = NSBitmapImageRep(data: tiff)!
    let png = bitmap.representation(using: .png, properties: [:])!
    try! png.write(to: attachmentsDir.appendingPathComponent("test.png"))

    // `placedImages()` resolves `Attachments.image(at:)` through its default
    // base, derived from `NoteStore.defaultFileURL()` — ChecklistTextView
    // carries no store reference of its own to inject one directly.
    // `JOT_NOTES_FILE` is the same override NoteStore's own default already
    // honours, repointed here at this scratch directory for the rest of the
    // process so this never touches a real Attachments folder.
    setenv("JOT_NOTES_FILE", directory.appendingPathComponent("notes.json").path, 1)

    return directory
}

@MainActor
private func makeHostedImageView(_ text: String) -> (window: NSWindow, view: ChecklistTextView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    view.baseFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.textStorage?.delegate = view
    view.string = text
    view.applyChecklistStyling()

    window.contentView = view
    window.center()
    bringUpAndWaitUntilKey(window)
    window.makeFirstResponder(view)
    pump(0.2)
    return (window, view)
}

/// A real left-button drag: down at `from`, a few intermediate drag events
/// toward `to`, then up at `to`. The drag/up events are queued via
/// `NSApp.postEvent` *before* mouseDown fires, because `beginResize`'s
/// `window.trackEvents` pulls matching events off the window's own queue in
/// a nested, synchronous local event loop — a different mechanism from the
/// plain `NSApp.sendEvent` dispatch `click()` in UIHarness.swift uses, which
/// only delivers whatever is sent to it directly.
@MainActor
private func drag(_ window: NSWindow, from: NSPoint, to: NSPoint, steps: Int = 4) {
    let app = NSApplication.shared
    func makeEvent(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: number,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        if let dragEvent = makeEvent(.leftMouseDragged, point, 100 + i) {
            app.postEvent(dragEvent, atStart: false)
        }
    }
    if let upEvent = makeEvent(.leftMouseUp, to, 200) {
        app.postEvent(upEvent, atStart: false)
    }

    if let downEvent = makeEvent(.leftMouseDown, from, 1) {
        app.sendEvent(downEvent)
    }
    pump(0.3)
}

func runImageResizeTests() {
    MainActor.assumeIsolated {
        suite("dragging an inline image resizes it and rewrites the markdown") {
            _ = writeTestImage(width: 200, height: 100)
            let text = "before\n![](Attachments/test.png)\nafter"
            let (window, view) = makeHostedImageView(text)
            defer { window.close() }

            let placedBefore = view.placedImages()
            equal(placedBefore.count, 1, "the image is found on layout")
            guard let before = placedBefore.first else { return }

            // Drag from the middle of the image, 80pt to the right — the
            // whole-image hit test in `handleSpecialClick` means a drag can
            // start anywhere on the image, not just an edge.
            let startInView = NSPoint(x: before.rect.midX, y: before.rect.midY)
            let startInWindow = view.convert(startInView, to: nil)
            let endInWindow = NSPoint(x: startInWindow.x + 80, y: startInWindow.y)

            drag(window, from: startInWindow, to: endInWindow)

            let updatedText = view.string
            check(updatedText != text, "the note text changed after the drag")

            let updatedReferences = Attachments.references(in: updatedText)
            equal(updatedReferences.count, 1, "still exactly one image reference")
            let widenedWidth = updatedReferences.first?.width
            check(widenedWidth != nil, "the markdown now carries an explicit width")
            if let widenedWidth {
                check(widenedWidth > before.rect.width,
                      "recorded width (\(widenedWidth)) grew from the rendered width (\(before.rect.width)), matching the rightward drag")
            }
        }
    }
}
