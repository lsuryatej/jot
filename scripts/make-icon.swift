import AppKit
import Foundation

// Draws the app icon and writes resources/AppIcon.icns.
//
// Committed as a script rather than a binary asset so the icon can be adjusted
// and regenerated rather than being an opaque blob nobody can edit.

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let scale = size / 1024
    let inset = 80 * scale
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = 180 * scale

    // Warm paper tones rather than pure white, which reads as a hole on a
    // light desktop.
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.45, alpha: 1),
            NSColor(calibratedRed: 0.98, green: 0.71, blue: 0.25, alpha: 1),
        ]
    )
    let shape = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
    gradient?.draw(in: shape, angle: -90)

    // A folded corner reads as "note" at small sizes better than any glyph.
    let fold = 210 * scale
    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: body.maxX - fold, y: body.maxY))
    foldPath.line(to: NSPoint(x: body.maxX, y: body.maxY - fold))
    foldPath.line(to: NSPoint(x: body.maxX - fold, y: body.maxY - fold))
    foldPath.close()
    NSColor(calibratedRed: 0.80, green: 0.52, blue: 0.12, alpha: 0.85).setFill()
    foldPath.fill()

    // Ruled lines, shortened near the fold.
    NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.05, alpha: 0.72).setFill()
    let lineHeight = 54 * scale
    let lineSpacing = 132 * scale
    let left = body.minX + 130 * scale
    var y = body.maxY - 330 * scale
    var index = 0
    while y > body.minY + 120 * scale {
        let shortened: CGFloat = index == 0 ? 260 * scale : 0
        let width = body.width - 260 * scale - shortened
        let line = NSRect(x: left, y: y, width: width, height: lineHeight)
        NSBezierPath(roundedRect: line, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        y -= lineSpacing
        index += 1
    }

    return image
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Jot-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects, each in 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let image = drawIcon(size: pixels)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { continue }
        let suffix = scale == 1 ? "" : "@2x"
        try png.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("resources/AppIcon.icns")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
