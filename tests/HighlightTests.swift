import AppKit
import Foundation

// Coverage for `==highlighted==` spans: the pure parser in Highlight.swift,
// and the two places ChecklistTextView acts on it — background painting and
// the Cmd+Shift+H toggle.

func runHighlightTests() {

    // MARK: - Parsing

    suite("finds a single highlight span") {
        let matches = Highlight.matches(in: "some ==important== text" as NSString)
        equal(matches.count, 1, "exactly one span")
        let match = matches[0]
        equal(match.range, NSRange(location: 5, length: 13), "whole span, markers included")
        equal(match.contentRange, NSRange(location: 7, length: 9), "content excludes both marker pairs")
        equal(match.markerRanges, [NSRange(location: 5, length: 2), NSRange(location: 16, length: 2)],
              "both `==` pairs are captured, opening then closing")
    }

    suite("finds more than one span per line") {
        let matches = Highlight.matches(in: "==one== and ==two==" as NSString)
        equal(matches.count, 2, "two spans on one line")
        equal(("==one== and ==two==" as NSString).substring(with: matches[0].contentRange), "one", "first span's content")
        equal(("==one== and ==two==" as NSString).substring(with: matches[1].contentRange), "two", "second span's content")
    }

    suite("spans do not cross a line boundary") {
        let matches = Highlight.matches(in: "==open\nclose==" as NSString)
        check(matches.isEmpty, "a `==` pair split across two lines is not a highlight")
    }

    suite("rejects an empty pair") {
        check(Highlight.matches(in: "one ==== rule" as NSString).isEmpty,
              "==== with nothing between the marks is not a highlight — some notes use it as a rule")
    }

    suite("does not match across an interior ==") {
        // Three consecutive marker-looking runs: the parser should not pair
        // the first and third `==` and swallow the middle one as content.
        let matches = Highlight.matches(in: "==a==b==c==" as NSString)
        check(!matches.isEmpty, "still finds well-formed pairs")
        for match in matches {
            let content = ("==a==b==c==" as NSString).substring(with: match.contentRange)
            check(!content.contains("="), "content never itself contains a marker character")
        }
    }

    // MARK: - The view layer

    suite("Cmd+Shift+H wraps a plain selection") {
        let view = makeTextView("remember this")
        view.setSelectedRange(NSRange(location: 9, length: 4))  // "this"
        view.toggleHighlight(nil)

        equal(view.string, "remember ==this==", "the selection is wrapped in place")
        equal(view.selectedRange(), NSRange(location: 11, length: 4), "selection lands back on the word, markers excluded")
    }

    suite("Cmd+Shift+H unwraps an already-highlighted selection") {
        let view = makeTextView("remember ==this==")
        view.setSelectedRange(NSRange(location: 9, length: 8))  // "==this=="
        view.toggleHighlight(nil)

        equal(view.string, "remember this", "the markers are stripped back off")
    }

    // Regression coverage for a real bug: toggling twice in a row (an actual
    // click, then a second actual click) kept nesting instead of round-
    // tripping, because the first toggle deliberately leaves the selection
    // over just the content, markers excluded, and the old unwrap check
    // was a plain string comparison against the *selected text* — which
    // never included the markers on a second pass. Every case below feeds
    // the toggle whatever selection state the previous call actually left
    // behind, or a selection/caret shape a real click could produce,
    // rather than a hand-picked range chosen to make the assertion easy.
    suite("Cmd+Shift+H twice in a row — real click, then real click again — round-trips, does not nest") {
        let view = makeTextView("remember this")
        view.setSelectedRange(NSRange(location: 9, length: 4))  // "this"
        view.toggleHighlight(nil)
        equal(view.string, "remember ==this==", "first click wraps")

        // No manual re-selection here — this is exactly the selection the
        // first call left behind, the same as what a real second click
        // would see.
        view.toggleHighlight(nil)
        equal(view.string, "remember this", "second click round-trips back to plain text, not a nested ====this====")
    }

    suite("Cmd+Shift+H with the caret merely inside an existing highlight (no selection) unwraps it") {
        let view = makeTextView("remember ==this== please")
        view.setSelectedRange(NSRange(location: 13, length: 0))  // caret inside "this", nothing selected
        view.toggleHighlight(nil)

        equal(view.string, "remember this please", "unwraps the highlight the caret is sitting in")
    }

    suite("Cmd+Shift+H with a selection over the markers themselves still unwraps cleanly") {
        // A manual drag-select (rather than the toggle's own follow-up
        // selection) could easily include a marker but not its pair, or
        // land mid-marker — the real span from `Highlight.matches` is what
        // actually gets replaced, not the selection's own bounds.
        let view = makeTextView("remember ==this== please")
        view.setSelectedRange(NSRange(location: 9, length: 3))  // "==t" — inside the span, ragged edge
        view.toggleHighlight(nil)

        equal(view.string, "remember this please", "the whole real span is stripped regardless of exactly what was selected")
    }

    // Regression coverage for the second half of the same story: a selection
    // the `==...==` syntax simply cannot express. `Highlight.regex` refuses a
    // span that contains an `=` of its own or crosses a line, so wrapping one
    // of those used to emit markers no parser could read back — they showed up
    // as literal `==` on screen, the next toggle found no span to unwrap, and
    // every further click nested another pair. Each case below chains real
    // repeated toggles, feeding each call the selection the previous one
    // actually left behind, which is what a second and third real click do.
    suite("Cmd+Shift+H refuses a selection containing an `=`, and keeps refusing it") {
        let view = makeTextView("total = 40")
        view.setSelectedRange(NSRange(location: 0, length: 10))
        view.toggleHighlight(nil)
        equal(view.string, "total = 40", "the line is left exactly as it was, not wrapped into markers nothing can read back")
        equal(view.selectedRange(), NSRange(location: 0, length: 10), "and the selection is left alone too")

        // No re-selection between clicks: this is the state the previous call
        // left behind, the same as a real second and third click.
        view.toggleHighlight(nil)
        view.toggleHighlight(nil)
        equal(view.string, "total = 40", "two more clicks still change nothing, rather than nesting ====total = 40====")
    }

    suite("Cmd+Shift+H refuses a selection spanning more than one line, and keeps refusing it") {
        let view = makeTextView("foo\nbar")
        view.setSelectedRange(NSRange(location: 0, length: 7))
        view.toggleHighlight(nil)
        equal(view.string, "foo\nbar", "a highlight cannot cross a line, so nothing is wrapped")

        view.toggleHighlight(nil)
        equal(view.string, "foo\nbar", "a second click does not nest a further pair either")
    }

    suite("Cmd+Shift+H refuses a selection spanning two adjacent highlights, and keeps refusing it") {
        // The selection covers both spans whole, so it sits inside neither and
        // falls through to the wrap branch — where `====a== ==b====` would be
        // literal text no parser reads as anything.
        let view = makeTextView("==a== ==b==")
        view.setSelectedRange(NSRange(location: 0, length: 11))
        view.toggleHighlight(nil)
        equal(view.string, "==a== ==b==", "both existing highlights survive untouched")

        view.toggleHighlight(nil)
        equal(view.string, "==a== ==b==", "and a second click still leaves them alone")
    }

    suite("a refused wrap does not stop the next, legal one from working") {
        // The refusal is per-call, not a latched state: narrowing the
        // selection to something the syntax can represent must still wrap, and
        // toggling that again must still round-trip.
        let view = makeTextView("total = 40")
        view.setSelectedRange(NSRange(location: 0, length: 10))
        view.toggleHighlight(nil)
        equal(view.string, "total = 40", "the whole-line selection is refused")

        view.setSelectedRange(NSRange(location: 0, length: 5))  // "total"
        view.toggleHighlight(nil)
        equal(view.string, "==total== = 40", "a selection the syntax can express still wraps")

        view.toggleHighlight(nil)
        equal(view.string, "total = 40", "and round-trips off again on the selection that wrap left behind")
    }

    suite("Cmd+Shift+H with nothing selected opens an empty pair") {
        let view = makeTextView("note: ")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.toggleHighlight(nil)

        equal(view.string, "note: ====", "an empty pair is inserted")
        equal(view.selectedRange(), NSRange(location: 8, length: 0), "the caret lands between the two marker pairs")
    }

    suite("highlighted content gets a background attribute, markers do not fold into visible glyphs") {
        let view = makeTextView("see ==this== here")
        guard let background = view.textStorage?.attribute(.backgroundColor, at: 6, effectiveRange: nil) as? NSColor else {
            check(false, "the highlighted content carries a background colour")
            return
        }
        equal(background, Highlight.backgroundColor, "using the app's one highlight colour")

        guard let plainBackground = view.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor else {
            check(true, "text outside the span has no background attribute at all")
            return
        }
        check(plainBackground != Highlight.backgroundColor, "text outside the span is not painted")
    }
}
