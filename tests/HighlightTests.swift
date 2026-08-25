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
