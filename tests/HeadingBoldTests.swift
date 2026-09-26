import AppKit
import Foundation

// Follow-up to #12. `NoteFont.bold(of:)` gave `**bold**` a real Bold, but
// headings and ordered-list markers still went through
// `NSFontManager.convert(_:toHaveTrait: .boldFontMask)`: Semibold in SF Mono
// (the default note font), New York and SF Rounded, and in Monaco, which has
// no bold cut, the regular face unchanged. They now resolve bold the same
// way, keeping each heading level's size, and keep their line exactly as
// tall as the non-bold face at that size would make it.

private func headingWeight(_ font: NSFont) -> CGFloat {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
    return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
}

private func fragment(_ view: ChecklistTextView, at index: Int) -> NSRect {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return .zero }
    lm.ensureLayout(for: tc)
    return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil)
}

func runHeadingBoldTests() {
    let manager = NSFontManager.shared
    let lifts: [CGFloat] = [6.0, 3.5, 1.5, 0.0, 0.0, 0.0]
    let spacing: [CGFloat] = [18, 12, 8, 6, 6, 6]

    suite("headings: every offered font renders bold levels at a real Bold, at the level's size") {
        for name in NoteFont.all {
            for level in 1...6 {
                let view = makeTextView("body\n\(String(repeating: "#", count: level)) Heading")
                view.baseFont = NoteFont.resolved(name, size: 13)
                let content = 5 + level + 1
                guard let font = view.textStorage?.attribute(.font, at: content, effectiveRange: nil) as? NSFont else {
                    check(false, "\(name) h\(level): the heading carries a font")
                    continue
                }
                let base = NoteFont.resolved(name, size: 13)
                let stroke = (view.textStorage?.attribute(.strokeWidth, at: content, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                check(abs(font.pointSize - (13 + lifts[level - 1])) < 0.01,
                      "\(name) h\(level): size \(font.pointSize) keeps the level's lift")
                equal(font.familyName, base.familyName, "\(name) h\(level): same family")
                equal(font.isFixedPitch, base.isFixedPitch, "\(name) h\(level): a mono note keeps mono headings")
                if level == 3 {
                    check(manager.weight(of: font) == manager.weight(of: base) && stroke == 0,
                          "\(name) h3: stays regular weight, the hinge level (got \(font.fontName))")
                } else if name == "Monaco" {
                    check(stroke < 0, "\(name) h\(level): no bold cut, so the stroke carries the weight")
                } else {
                    check(headingWeight(font) >= NSFont.Weight.bold.rawValue - 0.01,
                          "\(name) h\(level): at least Bold (got \(font.fontName), weight \(headingWeight(font)))")
                    check(stroke == 0, "\(name) h\(level): a real face, no stroke")
                }
            }
        }
    }

    suite("headings: a heading line is exactly as tall as its size's regular face, bold or not") {
        for multiple in [1.0, 1.4] {
            for name in NoteFont.all {
                for level in 1...6 {
                    let hashes = String(repeating: "#", count: level)
                    let view = makeTextView("body\n\(hashes) Heading\nbelow")
                    view.lineHeightMultiple = multiple
                    view.baseFont = NoteFont.resolved(name, size: 13)
                    let reference = makeTextView("body\nHeading\nbelow")
                    reference.lineHeightMultiple = multiple
                    reference.baseFont = NoteFont.resolved(name, size: 13 + lifts[level - 1])
                    let heading = fragment(view, at: 5 + level + 1).height
                    let expected = fragment(reference, at: 5).height + spacing[level - 1]
                    check(abs(heading - expected) < 0.03,
                          "\(name) h\(level) at \(multiple)x: \(heading) vs regular \(expected)")
                }
            }
        }
    }

    suite("headings: Monaco's heading stroke covers the heading only, and leaves with the marker") {
        let view = makeTextView("body\n## Heading\nafter")
        view.baseFont = NoteFont.resolved("Monaco", size: 13)
        check(((view.textStorage?.attribute(.strokeWidth, at: 9, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0) < 0,
              "the heading is stroked")
        check(view.textStorage?.attribute(.strokeWidth, at: 1, effectiveRange: nil) == nil, "the line above is not")
        check(view.textStorage?.attribute(.strokeWidth, at: 17, effectiveRange: nil) == nil, "the line below is not")
        view.setSelectedRange(NSRange(location: 5, length: 3))
        view.insertText("", replacementRange: NSRange(location: 5, length: 3))
        equal(view.string, "body\nHeading\nafter", "marker removed")
        check(view.textStorage?.attribute(.strokeWidth, at: 6, effectiveRange: nil) == nil,
              "no stale stroke once the line is plain again")
    }

    suite("ordered lists: every offered font draws the marker at a real Bold") {
        for name in NoteFont.all {
            let view = makeTextView("body\n12. item\nafter")
            view.baseFont = NoteFont.resolved(name, size: 13)
            guard let font = view.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont else {
                check(false, "\(name): the marker carries a font")
                continue
            }
            let base = NoteFont.resolved(name, size: 13)
            let stroke = (view.textStorage?.attribute(.strokeWidth, at: 6, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
            equal(font.pointSize, 13, "\(name): body size")
            equal(font.familyName, base.familyName, "\(name): same family")
            if name == "Monaco" {
                check(stroke < 0, "\(name): stroked, since there is no bold cut")
            } else {
                check(headingWeight(font) >= NSFont.Weight.bold.rawValue - 0.01,
                      "\(name): at least Bold (got \(font.fontName), weight \(headingWeight(font)))")
            }
            check(view.textStorage?.attribute(.strokeWidth, at: 10, effectiveRange: nil) == nil,
                  "\(name): the item text is not stroked")
            let itemFont = view.textStorage?.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
            equal(itemFont?.fontName, base.fontName, "\(name): the item text stays regular")
        }
    }

    suite("ordered lists: a numbered line is as tall as a plain one in every font") {
        for name in NoteFont.all {
            let view = makeTextView("plain line\n1. item\nafter")
            view.baseFont = NoteFont.resolved(name, size: 13)
            let plain = fragment(view, at: 2)
            let numbered = fragment(view, at: 12)
            check(abs(numbered.height - plain.height) < 0.02,
                  "\(name): numbered \(numbered.height) vs plain \(plain.height)")
        }
    }
}
