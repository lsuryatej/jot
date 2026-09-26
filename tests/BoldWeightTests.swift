import AppKit
import Foundation

// Issue #12, "bold is too thin". `NSFontManager.convert(_:toHaveTrait:
// .boldFontMask)` lands on Semibold for SF Mono (the default note font),
// New York and SF Rounded, which reads as barely heavier than Regular at
// note sizes, and on Monaco, which has no bold cut, it hands back the
// regular face unchanged so `**bold**` looks like nothing at all.
// `NoteFont.bold(of:)` picks a real Bold, and a synthetic stroke only when
// the family has nothing heavier.

private func weightTrait(_ font: NSFont) -> CGFloat {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
    return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
}

func runBoldWeightTests() {
    let manager = NSFontManager.shared

    suite("every offered font resolves bold to a clearly heavier face, or a stroke") {
        for name in NoteFont.all {
            let base = NoteFont.resolved(name, size: 13)
            let bold = NoteFont.bold(of: base)
            if name == "Monaco" {
                check(bold.needsSyntheticStroke, "\(name): no bold cut exists, so the stroke carries it")
                equal(bold.font.fontName, base.fontName, "\(name): the face itself is left alone")
                continue
            }
            check(!bold.needsSyntheticStroke, "\(name): a real bold face exists, no stroke")
            check(weightTrait(bold.font) >= NSFont.Weight.bold.rawValue - 0.01,
                  "\(name): at least Bold (got \(bold.font.fontName), weight \(weightTrait(bold.font)))")
            check(weightTrait(bold.font) <= NSFont.Weight.heavy.rawValue + 0.01, "\(name): never past Heavy")
            check(manager.weight(of: bold.font) >= manager.weight(of: base) + 2,
                  "\(name): at least two NSFontManager weight steps above regular")
            equal(bold.font.familyName, base.familyName, "\(name): same family, not a substitute")
            equal(bold.font.pointSize, base.pointSize, "\(name): same size")
            equal(bold.font.isFixedPitch, base.isFixedPitch, "\(name): a mono note stays mono")
        }
    }

    suite("bold inside something already bold goes heavier still") {
        let heading = NSFont.systemFont(ofSize: 19, weight: .bold)
        let bold = NoteFont.bold(of: heading)
        check(weightTrait(bold.font) > weightTrait(heading) + 0.05,
              "`## a **word**` still shows the word as emphasised (got \(weightTrait(bold.font)))")
        check(weightTrait(bold.font) <= NSFont.Weight.heavy.rawValue + 0.01, "capped at Heavy")
        check(!bold.needsSyntheticStroke, "SF has a Heavy cut, so no stroke is needed")
    }

    suite("**bold** in a default SF Mono note renders at Bold, not Semibold") {
        let view = makeTextView("some **bold** text")
        guard let font = view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont else {
            check(false, "the content carries a font")
            return
        }
        check(weightTrait(font) >= NSFont.Weight.bold.rawValue - 0.01,
              "got \(font.fontName) at weight \(weightTrait(font))")
        check(font.isFixedPitch, "still monospaced")
    }

    suite("**bold** in a Monaco note is stroked, and only the content") {
        let view = makeTextView("some **bold** text")
        view.baseFont = NoteFont.resolved("Monaco", size: 13)
        let stroke = view.textStorage?.attribute(.strokeWidth, at: 7, effectiveRange: nil) as? NSNumber
        check((stroke?.doubleValue ?? 0) < 0, "a negative stroke width fills and thickens the glyphs")
        check(view.textStorage?.attribute(.strokeWidth, at: 0, effectiveRange: nil) == nil, "text before is not stroked")
        check(view.textStorage?.attribute(.strokeWidth, at: 14, effectiveRange: nil) == nil, "text after is not stroked")

        // The stroke must not outlive the markers: unbolding clears it.
        view.setSelectedRange(NSRange(location: 7, length: 4))
        view.toggleBold(nil)
        equal(view.string, "some bold text", "unwrapped")
        check(view.textStorage?.attribute(.strokeWidth, at: 6, effectiveRange: nil) == nil,
              "no stale stroke once the word is plain again")
    }

    suite("bolding a word leaves its line fragment the same height") {
        for name in NoteFont.all {
            let view = makeTextView("plain line\nmake this bold")
            view.baseFont = NoteFont.resolved(name, size: 13)
            guard let lm = view.layoutManager, let tc = view.textContainer else { continue }
            lm.ensureLayout(for: tc)
            let before = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: 12), effectiveRange: nil)
            view.setSelectedRange(NSRange(location: 21, length: 4))
            view.toggleBold(nil)
            lm.ensureLayout(for: tc)
            let after = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: 12), effectiveRange: nil)
            // Helvetica Neue and American Typewriter draw Bold a point taller
            // than Regular; the styling pass caps the line back to its
            // natural height. What remains is the bold face's own leading,
            // which TextKit adds after the cap: 0.013pt for Helvetica Neue,
            // about a fortieth of a Retina pixel. Hence 0.02, not zero.
            check(abs(after.height - before.height) < 0.02,
                  "\(name): no vertical jump when the word turns bold (\(before.height) -> \(after.height))")
            check(abs(after.origin.y - before.origin.y) < 0.01, "\(name): the line stays put")
        }
    }
}
