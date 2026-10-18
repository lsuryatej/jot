import AppKit
import Foundation

// Draws the app icon into an .iconset directory; build.sh turns it into
// AppIcon.icns with iconutil. A script rather than a committed binary, as in
// Jot, so the icon can be changed and regenerated.
//
//   swift scripts/make-icon.swift <output.iconset>

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let scale = size / 1024
    let inset = 80 * scale
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.99, green: 0.55, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.84, green: 0.16, blue: 0.30, alpha: 1),
    ])?.draw(in: shape, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: 560 * scale, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let flameSize = flame.size
        let origin = NSPoint(x: body.midX - flameSize.width / 2, y: body.midY - flameSize.height / 2 - 10 * scale)
        flame.draw(in: NSRect(origin: origin, size: flameSize))
    }
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = points * factor
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(drawIcon(size: CGFloat(pixels)), pixels: pixels, to: output.appendingPathComponent(name))
    }
}
print("Wrote \(output.path)")
