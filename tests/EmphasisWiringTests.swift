import AppKit
import Foundation

// Coverage for what ChecklistTextView does with the spans Emphasis.swift
// finds. The parser has its own tests next door; nothing here re-checks
// offsets for their own sake. What matters here is the three things the view
// layer owns and the parser cannot know about: which characters get put on
// the fold list, whether the trait lands on the content and nowhere else,
// and whether the trait is *added* to the font a run already carries instead
// of replacing it.

/// A view whose base font is proportional.
///
/// `makeTextView` hands back a monospaced note, which is the wrong instrument
/// for most of this file: SF Mono ships no true italic, so an italic trait
/// conversion silently returns the same font, and `applyEmphasis` leaves a
/// code span's font untouched when the note is already fixed-pitch. Both make
/// a passing assertion meaningless. The system font has real bold and italic
/// cuts and is not fixed-pitch, so every branch actually has to do work.
private func makeEmphasisView(_ text: String) -> ChecklistTextView {
    let view = makeTextView(text)
    view.baseFont = .systemFont(ofSize: 13)  // didSet restyles
    return view
}

private func font(in view: ChecklistTextView, at location: Int) -> NSFont? {
    view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
}

private func background(in view: ChecklistTextView, at location: Int) -> NSColor? {
    view.textStorage?.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
}

private func hasTrait(_ trait: NSFontTraitMask, _ font: NSFont?) -> Bool {
    guard let font else { return false }
    return NSFontManager.shared.traits(of: font).contains(trait)
}

func runEmphasisWiringTests() {

    // MARK: - Markers reach the fold list

    suite("a strong span registers both markers for folding") {
        let view = makeEmphasisView("some **bold** text")
        equal(view.emphasisMarkers, [NSRange(location: 5, length: 2), NSRange(location: 11, length: 2)],
              "the two `**` runs, and nothing else, are what glyph generation will hide")
    }

    suite("an emphasis span registers both markers for folding") {
        let view = makeEmphasisView("an *italic* word")
        equal(view.emphasisMarkers, [NSRange(location: 3, length: 1), NSRange(location: 10, length: 1)],
              "single-character markers land at the right offsets")
    }

    suite("a code span registers both backticks for folding") {
        let view = makeEmphasisView("run `ls` now")
        equal(view.emphasisMarkers, [NSRange(location: 4, length: 1), NSRange(location: 7, length: 1)],
              "both backticks fold, leaving the wash to carry the signal")
    }

    suite("a note with no emphasis leaves the fold list empty") {
        let view = makeEmphasisView("nothing to see here")
        check(view.emphasisMarkers.isEmpty, "no spans means no folded characters")
    }

    // MARK: - The content is styled, the markers are not

    suite("bold lands on the content and stops there") {
        let view = makeEmphasisView("some **bold** text")
        check(hasTrait(.boldFontMask, font(in: view, at: 7)), "the wrapped word is bold")
        check(!hasTrait(.boldFontMask, font(in: view, at: 0)), "text before the span is untouched")
        check(!hasTrait(.boldFontMask, font(in: view, at: 14)), "text after the span is untouched")
        check(!hasTrait(.boldFontMask, font(in: view, at: 5)),
              "the marker itself stays body weight, so a caret sitting on it does not look bold")
    }

    suite("italic lands on the content and stops there") {
        let view = makeEmphasisView("an *italic* word")
        check(hasTrait(.italicFontMask, font(in: view, at: 4)), "the wrapped word is italic")
        check(!hasTrait(.italicFontMask, font(in: view, at: 0)), "text before the span is untouched")
        check(!hasTrait(.italicFontMask, font(in: view, at: 12)), "text after the span is untouched")
    }

    // MARK: - The trait composes rather than replaces

    suite("bold inside a heading keeps the heading's size") {
        // The reason applyEmphasis enumerates the existing .font instead of
        // starting from baseFont. Get this wrong and a bold word inside a
        // heading visibly drops to body size mid-line, which is the kind of
        // thing nobody notices until a note looks broken.
        let view = makeEmphasisView("## Section with **bold**")
        let headingSize = font(in: view, at: 3)?.pointSize ?? 0
        let boldSize = font(in: view, at: 18)?.pointSize ?? 0

        check(headingSize > view.baseFont.pointSize, "the heading is lifted above body size at all")
        equal(boldSize, headingSize, "the bold run is still heading-sized, not knocked back to body")
        check(hasTrait(.boldFontMask, font(in: view, at: 18)), "and it did gain the weight")
    }

    suite("italic inside a heading keeps the heading's size") {
        let view = makeEmphasisView("### Notes on *why*")
        let headingSize = font(in: view, at: 4)?.pointSize ?? 0
        let italicSize = font(in: view, at: 14)?.pointSize ?? 0

        check(headingSize > view.baseFont.pointSize, "level 3 still gets a lift")
        equal(italicSize, headingSize, "the italic run inherits the heading's size")
        check(hasTrait(.italicFontMask, font(in: view, at: 14)), "and it did gain the slant")
    }

    // MARK: - Code mode switches the whole thing off

    suite("a code block folds nothing") {
        // An asterisk in real code is a character somebody typed. Folding it
        // would corrupt the line on screen while the file on disk still held
        // it, which is the worst possible version of this feature.
        let view = makeTextView("code\nlet x = a **b** c")
        check(view.isCodeMode, "the note is a code block")
        check(view.emphasisMarkers.isEmpty, "nothing in a code block is treated as a marker")
    }

    suite("leaving code mode brings emphasis back") {
        let view = makeTextView("code\nsome **bold** text")
        check(view.emphasisMarkers.isEmpty, "no markers while the keyword is there")

        view.string = "notes\nsome **bold** text"
        view.applyChecklistStyling()
        equal(view.emphasisMarkers.count, 2, "the same line's markers are picked up once it is prose again")
    }

    // MARK: - Inline code

    suite("inline code gets the wash and a monospaced face") {
        let view = makeEmphasisView("run `ls` now")
        equal(background(in: view, at: 5), Emphasis.codeBackgroundColor, "the content carries the tint")
        check(background(in: view, at: 0) == nil, "text before the span has no background at all")
        check(background(in: view, at: 9) == nil, "nor does text after it")
        check(font(in: view, at: 5)?.isFixedPitch == true, "a proportional note switches to mono inside the span")
        check(font(in: view, at: 0)?.isFixedPitch == false, "the rest of the note keeps its own face")
    }

    // MARK: - Coexistence with highlights

    suite("emphasis and a highlight on one line keep their own markers") {
        let view = makeEmphasisView("==remember== the **rule**")
        equal(view.highlightMarkers, [NSRange(location: 0, length: 2), NSRange(location: 10, length: 2)],
              "the highlight's markers survive the emphasis pass that runs after it")
        equal(view.emphasisMarkers, [NSRange(location: 17, length: 2), NSRange(location: 23, length: 2)],
              "and the emphasis markers are recorded alongside them")
        equal(background(in: view, at: 2), Highlight.backgroundColor, "the highlight is still painted")
        check(hasTrait(.boldFontMask, font(in: view, at: 19)), "and the bold word is still bold")
    }

    suite("a math line registers no emphasis markers") {
        let view = makeEmphasisView("2*3*4")
        equal(view.emphasisMarkers, [], "nothing on a math line folds, so the asterisks stay visible")
    }

    // MARK: - An earlier edit can change a later line's classification

    suite("undefining a variable on an earlier line restyles the emphasis it creates downstream") {
        let view = makeEmphasisView("b = 2\n5*b*5")
        // While b = 2, "5*b*5" parses and evaluates as math (5*2*5), so it
        // shows no emphasis at all: no folded markers, "b" in the plain font.
        check(view.emphasisMarkers.isEmpty, "sanity: 5*b*5 is math, not emphasis, while b is defined")
        check(!hasTrait(.italicFontMask, font(in: view, at: 8)), "sanity: b starts in the plain font")

        // In place on line 1 only: deletes the "2", leaving "b = " (an
        // incomplete assignment) without touching line 2 at all or changing
        // the line count. `didProcessEditing`'s incremental `range` covers
        // only this edit, not "5*b*5" two characters later.
        view.replace(range: NSRange(location: 4, length: 1), with: "", selecting: nil)
        equal(view.string, "b = \n5*b*5", "sanity: only the \"2\" was removed")

        // b is now undefined, so "5*b*5" fails to evaluate as math and *b* is
        // read as emphasis: its markers fold, so "b" alone becomes visible
        // between them, and it must be in the italic font to render as
        // anything other than a plain, unstyled "b" with no asterisks.
        check(!view.emphasisMarkers.isEmpty, "the two asterisks around b are now markers to fold")
        check(hasTrait(.italicFontMask, font(in: view, at: 7)),
              "and b — one character earlier now the line is a character shorter — must pick up italic to match")
    }
}
