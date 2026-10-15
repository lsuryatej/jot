import AppKit
import Foundation

// "Highlight current line" (issue #12, item 1): a faint band behind the whole
// logical line the caret is on, every wrapped fragment of it, across the text
// container's full width, drawn under the text and the selection.
//
// The residue rule from SelectionResidueTests applies here too: whatever is
// painted must be exactly what is invalidated when the caret leaves, so both
// edges of the band sit on device pixels and the band is invalidated as drawn.

@MainActor
private struct LineFixture {
    let view: ChecklistTextView
    let manager: NSLayoutManager
    let container: NSTextContainer

    init(text: String, multiple: Double = 1.3, size: CGFloat = 13, width: CGFloat = 440,
         installsBackgroundManager: Bool = true) {
        let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        view.isRichText = false
        if installsBackgroundManager { view.installBackgroundLayoutManager() }
        view.textContainerInset = NSSize(width: 20, height: 38)
        view.baseFont = .systemFont(ofSize: size)
        view.lineHeightMultiple = multiple
        view.textStorage?.delegate = view
        view.drawsBackground = false
        view.string = text
        view.applyChecklistStyling()
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        self.view = view
        self.manager = view.layoutManager!
        self.container = view.textContainer!
    }

    /// The fragments of the paragraph holding `location`, in view coordinates.
    func fragments(at location: Int) -> [NSRect] {
        let ns = view.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
        let glyphs = manager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        var out: [NSRect] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            out.append(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y))
        }
        return out
    }
}

private func onPixels(_ value: CGFloat, scale: CGFloat) -> Bool {
    abs((value * scale).rounded() - value * scale) < 0.0001
}

/// The pixel at a point of a rendered view, as sRGB.
private func pixel(_ rep: NSBitmapImageRep, at point: NSPoint, height: CGFloat) -> NSColor? {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    // Flipped view: y grows downward, which is also the bitmap's row order.
    return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
}

private func writeCurrentLineScratchImage() -> String {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jot-current-line-\(UUID().uuidString)")
    let attachments = directory.appendingPathComponent("Attachments", isDirectory: true)
    try! FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
    let image = NSImage(size: NSSize(width: 200, height: 100))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 200, height: 100).fill()
    image.unlockFocus()
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let name = "\(UUID().uuidString).png"
    try! png.write(to: attachments.appendingPathComponent(name))
    setenv("JOT_NOTES_FILE", directory.appendingPathComponent("notes.json").path, 1)
    return "Attachments/\(name)"
}

func runCurrentLineHighlightTests() {
    suite("current line: the band spans every fragment, at full container width, on device pixels") {
        let fragments = [NSRect(x: 0, y: 20.8, width: 400, height: 20.8),
                         NSRect(x: 0, y: 41.6, width: 400, height: 20.8),
                         NSRect(x: 0, y: 62.4, width: 400, height: 20.8)]
        for scale in [CGFloat(1), 2, 3] {
            let rect = ChecklistTextView.currentLineRect(
                lineFragments: fragments, containerOrigin: NSPoint(x: 20, y: 38.3),
                containerWidth: 400.25, scale: scale
            )
            guard let rect else { check(false, "\(Int(scale))x: a rect"); continue }
            check(abs(rect.minY - (38.3 + 20.8)) <= 0.5 / scale + 0.0001, "\(Int(scale))x: starts at the first fragment's top")
            check(abs(rect.maxY - (38.3 + 83.2)) <= 0.5 / scale + 0.0001, "\(Int(scale))x: ends at the last one's bottom")
            check(abs(rect.minX - 20) <= 0.5 / scale + 0.0001, "\(Int(scale))x: from the container's left edge")
            check(abs(rect.maxX - 420.25) <= 0.5 / scale + 0.0001, "\(Int(scale))x: to its right edge")
            for (name, value) in [("top", rect.minY), ("bottom", rect.maxY), ("left", rect.minX), ("right", rect.maxX)] {
                check(onPixels(value, scale: scale), "\(Int(scale))x: \(name) edge \(value) is on a device pixel")
            }
        }
        equal(ChecklistTextView.currentLineRect(lineFragments: [], containerOrigin: .zero, containerWidth: 400, scale: 2),
              nil, "no fragments: nothing to draw")
        equal(ChecklistTextView.currentLineRect(
            lineFragments: [NSRect(x: 0, y: 0, width: 0, height: 0)],
            containerOrigin: .zero, containerWidth: 400, scale: 2), nil, "a zero-height fragment: nothing to draw")
    }

    suite("current line: two adjacent lines meet on one pixel edge, no overlap and no gap") {
        let a = ChecklistTextView.currentLineRect(lineFragments: [NSRect(x: 0, y: 10.4, width: 300, height: 20.8)],
                                                  containerOrigin: NSPoint(x: 20, y: 38), containerWidth: 300, scale: 2)!
        let b = ChecklistTextView.currentLineRect(lineFragments: [NSRect(x: 0, y: 31.2, width: 300, height: 20.8)],
                                                  containerOrigin: NSPoint(x: 20, y: 38), containerWidth: 300, scale: 2)!
        equal(a.maxY, b.minY, "line one's bottom is line two's top")
    }

    suite("current line: shown only with a bare caret in a focused view, and only when on") {
        let caret = [NSRange(location: 4, length: 0)]
        check(ChecklistTextView.showsCurrentLine(enabled: true, selections: caret, isFocused: true), "on, focused, a caret")
        check(!ChecklistTextView.showsCurrentLine(enabled: false, selections: caret, isFocused: true), "off by setting")
        check(!ChecklistTextView.showsCurrentLine(enabled: true, selections: caret, isFocused: false),
              "hidden when the view is not first responder")
        check(!ChecklistTextView.showsCurrentLine(enabled: true, selections: [NSRange(location: 4, length: 3)], isFocused: true),
              "hidden with a selection: the selection is the thing to see")
        check(!ChecklistTextView.showsCurrentLine(
            enabled: true, selections: [NSRange(location: 1, length: 0), NSRange(location: 9, length: 0)], isFocused: true),
              "hidden with more than one range")
    }

    suite("current line: a caret move invalidates exactly the old and the new band") {
        let old = NSRect(x: 20, y: 59, width: 400, height: 21)
        let new = NSRect(x: 20, y: 101, width: 400, height: 42)
        equal(ChecklistTextView.currentLineInvalidation(from: old, to: new), [old, new], "moved: both bands")
        equal(ChecklistTextView.currentLineInvalidation(from: old, to: old), [], "same line: nothing, so typing never repaints it")
        equal(ChecklistTextView.currentLineInvalidation(from: old, to: nil), [old], "hidden: only the old one")
        equal(ChecklistTextView.currentLineInvalidation(from: nil, to: new), [new], "shown: only the new one")
        equal(ChecklistTextView.currentLineInvalidation(from: nil, to: nil), [], "never shown: nothing")
    }

    suite("current line: the colour is the ink, faint, a little stronger under Increase Contrast") {
        let papers: [(String, NSColor, NSColor)] = [
            ("white", Appearance.white.paperColor!, Appearance.white.ink.text),
            ("cream", Appearance.cream.paperColor!, Appearance.cream.ink.text),
            ("true dark", Appearance.trueDark.paperColor!, Appearance.trueDark.ink.text),
            ("theme #223038", ThemeNote.color(fromHex: "#223038")!,
             ThemeNote.derivedInk(for: ThemeNote.color(fromHex: "#223038")!).text),
            ("theme #f4ecd8", ThemeNote.color(fromHex: "#f4ecd8")!,
             ThemeNote.derivedInk(for: ThemeNote.color(fromHex: "#f4ecd8")!).text),
        ]
        for (name, paper, ink) in papers {
            let normal = Contrast.composite(ChecklistTextView.currentLineColor(ink: ink, increaseContrast: false), over: paper)
            let strong = Contrast.composite(ChecklistTextView.currentLineColor(ink: ink, increaseContrast: true), over: paper)
            let r = Contrast.ratio(normal, paper), rs = Contrast.ratio(strong, paper)
            check(r > 1.03 && r < 1.2, "\(name): visible but faint (\(String(format: "%.3f", r)):1)")
            check(rs > r && rs < 1.4, "\(name): stronger under Increase Contrast (\(String(format: "%.3f", rs)):1)")
            let textOnBand = Contrast.ratio(ink, strong)
            check(textOnBand >= 4.5, "\(name): the text still reads on the band (\(String(format: "%.1f", textOnBand)):1)")
        }
        let system = ChecklistTextView.currentLineColor(ink: .labelColor, increaseContrast: false)
        for mode in [NSAppearance.Name.aqua, .darkAqua] {
            let resolved = Contrast.resolved(system, in: NSAppearance(named: mode)!)
            check(resolved.alphaComponent > 0.03 && resolved.alphaComponent < 0.09,
                  "translucent papers: the system label colour, resolved per mode, at low alpha (\(mode.rawValue))")
        }
    }

    MainActor.assumeIsolated {
        let text = """
        # A heading line
        Short line.
        A paragraph long enough to wrap onto several lines inside this narrow column, so the band must cover every one of its fragments and not only the first.
        last
        """

        suite("current line: the caret's band covers its whole logical line, wrapped fragments included") {
            let fixture = LineFixture(text: text, width: 260)
            let ns = text as NSString
            let wrapped = ns.range(of: "A paragraph").location + 20
            let fragments = fixture.fragments(at: wrapped)
            check(fragments.count >= 3, "the paragraph wraps (\(fragments.count) fragments)")
            fixture.view.setSelectedRange(NSRange(location: wrapped, length: 0))
            guard let band = fixture.view.caretLineRect(scale: 2) else { check(false, "a band"); return }
            check(abs(band.minY - fragments.first!.minY) <= 0.25 + 0.0001, "from the first fragment's top")
            check(abs(band.maxY - fragments.last!.maxY) <= 0.25 + 0.0001, "to the last fragment's bottom")
            equal(band.minX, fixture.view.textContainerOrigin.x, "from the container's left edge")
            check(abs(band.width - fixture.container.size.width) <= 0.5, "across its full width")

            let heading = fixture.fragments(at: 2)
            fixture.view.setSelectedRange(NSRange(location: 2, length: 0))
            let headingBand = fixture.view.caretLineRect(scale: 2)!
            check(abs(headingBand.height - heading[0].height) <= 0.5, "a heading's band is the heading's own height")
            check(headingBand.maxY <= band.minY, "and does not reach into the next line")
        }

        suite("current line: a caret at the end, after a trailing newline, lights the empty last line") {
            let fixture = LineFixture(text: "one\ntwo\n")
            fixture.view.setSelectedRange(NSRange(location: 8, length: 0))
            let band = fixture.view.caretLineRect(scale: 2)
            let extra = fixture.manager.extraLineFragmentRect.offsetBy(dx: fixture.view.textContainerOrigin.x,
                                                                       dy: fixture.view.textContainerOrigin.y)
            check(band != nil && abs(band!.minY - extra.minY) <= 0.25 + 0.0001, "the band sits on the empty line")
            let empty = LineFixture(text: "")
            check(empty.view.caretLineRect(scale: 2) != nil, "an empty note has a line to light")
        }

        suite("current line: an image line lights its full, tall fragment") {
            let path = writeCurrentLineScratchImage()
            let markdown = Attachments.markdown(path: path, width: 240)
            let text = "above\n\(markdown)\nbelow"
            let fixture = LineFixture(text: text, installsBackgroundManager: false)
            let imageLine = (text as NSString).range(of: markdown).location
            fixture.view.setSelectedRange(NSRange(location: imageLine, length: 0))
            let fragments = fixture.fragments(at: imageLine)
            guard let band = fixture.view.caretLineRect(scale: 2), let tall = fragments.first else {
                check(false, "a band on the image line")
                return
            }
            check(tall.height > 60, "the image makes its line tall (\(tall.height)pt)")
            check(abs(band.minY - tall.minY) <= 0.25 + 0.0001 && abs(band.maxY - fragments.last!.maxY) <= 0.25 + 0.0001,
                  "the band covers the whole image line, top to bottom")
        }

        suite("current line: caret moves invalidate the old and new bands; typing on the line does not") {
            let fixture = LineFixture(text: text, width: 260)
            let view = fixture.view
            view.currentLineFocusOverride = true
            view.highlightsCurrentLine = true
            view.setSelectedRange(NSRange(location: 2, length: 0))
            let first = view.displayedCurrentLineRect
            check(first != nil, "a band is shown on the first line")

            let second = (text as NSString).range(of: "Short").location + 2
            view.setSelectedRange(NSRange(location: second, length: 0))
            let moved = view.displayedCurrentLineRect
            check(moved != nil && moved != first, "it moved to the second line")
            equal(view.lastCurrentLineInvalidation, [first!, moved!], "and invalidated exactly the two bands")

            view.setSelectedRange(NSRange(location: second + 1, length: 0))
            equal(view.lastCurrentLineInvalidation, [], "along the same line: nothing is invalidated")

            view.insertText("x", replacementRange: view.selectedRange())
            equal(view.displayedCurrentLineRect, moved, "typing a character keeps the band where it is")

            view.setSelectedRange(NSRange(location: second, length: 4))
            equal(view.displayedCurrentLineRect, nil, "a selection hides it")
            equal(view.lastCurrentLineInvalidation, [moved!], "and only the band it hid is invalidated")

            view.setSelectedRange(NSRange(location: second, length: 0))
            check(view.displayedCurrentLineRect != nil, "collapsing the selection brings it back")
            view.currentLineFocusOverride = false
            view.refreshCurrentLineHighlight()
            equal(view.displayedCurrentLineRect, nil, "losing focus hides it")
            view.currentLineFocusOverride = true
            view.highlightsCurrentLine = false
            equal(view.displayedCurrentLineRect, nil, "turning the setting off hides it")
        }

        suite("current line: unfocused by default, so a view outside a window draws nothing") {
            let fixture = LineFixture(text: text)
            fixture.view.highlightsCurrentLine = true
            fixture.view.setSelectedRange(NSRange(location: 2, length: 0))
            equal(fixture.view.displayedCurrentLineRect, nil, "no window, no first responder, no band")
        }

        suite("current line: drawn in the view's background, under the text") {
            let fixture = LineFixture(text: "first line\nsecond line\nthird line", multiple: 1.0, size: 13)
            let view = fixture.view
            view.ink = Appearance.white.ink
            view.currentLineFocusOverride = true
            view.highlightsCurrentLine = true
            view.setSelectedRange(NSRange(location: 14, length: 0))
            guard let band = view.displayedCurrentLineRect,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                check(false, "rendered")
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            // Far right of the band, where there is no glyph.
            let inside = pixel(rep, at: NSPoint(x: band.maxX - 4, y: band.midY), height: view.bounds.height)
            let outside = pixel(rep, at: NSPoint(x: band.maxX - 4, y: band.minY - 6), height: view.bounds.height)
            check((inside?.alphaComponent ?? 0) > 0.02, "the band is painted (alpha \(inside?.alphaComponent ?? 0))")
            check((outside?.alphaComponent ?? 1) < 0.01, "and nothing above it (alpha \(outside?.alphaComponent ?? 1))")
            let glyph = pixel(rep, at: NSPoint(x: band.minX + 8, y: band.midY + 2), height: view.bounds.height)
            check((glyph?.alphaComponent ?? 0) > (inside?.alphaComponent ?? 1),
                  "the text is drawn over it, not under it")
        }
    }

    suite("current line: the setting is off by default and persists") {
        let name = "JotTests.currentLine-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        check(!settings.highlightsCurrentLine, "off for a fresh install")
        settings.highlightsCurrentLine = true
        check(SettingsManager(defaults: defaults).highlightsCurrentLine, "on survives a relaunch")
        settings.highlightsCurrentLine = false
        check(!SettingsManager(defaults: defaults).highlightsCurrentLine, "and so does off")
    }
}
