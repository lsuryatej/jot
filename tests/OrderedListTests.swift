import AppKit
import Foundation

// Coverage for ordered-list markers: the pure parser in OrderedList.swift,
// its coexistence rules inside Checklist, and the two places ChecklistTextView
// acts on it — marker painting and Return continuation.

func runOrderedListTests() {

    // MARK: - Parsing

    suite("parses a plain numbered item") {
        let parsed = OrderedList.item(in: "1. eggs")
        check(parsed != nil, "1. eggs is an ordered item")
        equal(parsed?.kind, OrderedMarkerKind.number(1), "the value is parsed, not just matched")
        equal(parsed?.body, "eggs", "the body is what follows the separator")
        equal(parsed?.markerRange, NSRange(location: 0, length: 2), "marker range covers '1.' dot included")
    }

    suite("parses indent, letters, and romans") {
        let indented = OrderedList.item(in: "    2. flour")
        equal(indented?.indent, "    ", "leading whitespace is captured")
        equal(indented?.kind, .number(2), "indentation does not disturb the kind")
        equal(indented?.markerRange, NSRange(location: 4, length: 2), "range starts after the indent, dot included")

        equal(OrderedList.item(in: "a. x")?.kind, .letter("a"), "single letters are alphabet items")
        equal(OrderedList.item(in: "B. x")?.kind, .letter("B"), "case is kept, not normalised")
        equal(OrderedList.item(in: "i. x")?.kind, .roman(1), "single i reads roman, not letter")
        equal(OrderedList.item(in: "v. x")?.kind, .roman(5), "v was never an alphabet item here")
        equal(OrderedList.item(in: "x. x")?.kind, .roman(10), "x is roman as well — the third stolen letter")
        equal(OrderedList.item(in: "iv. x")?.kind, .roman(4), "the classic subtractive pair")
        equal(OrderedList.item(in: "IV. x")?.kind, .roman(4), "uppercase romans classify too")
    }

    suite("rejects prose that merely looks numeric") {
        check(OrderedList.item(in: "3.14 is pi") == nil, "no space after the dot means it stays prose")
        check(OrderedList.item(in: "hello world") == nil, "plain prose")
        check(OrderedList.item(in: "1") == nil, "a bare number with no dot")
        check(OrderedList.item(in: "12345. x") == nil, "five digits exceeds the four-digit cap")
        check(OrderedList.item(in: "- [ ] task") == nil, "checkbox lines are not ordered items")
        check(OrderedList.item(in: "# Heading") == nil, "headings are their own structure")
        check(OrderedList.item(in: "5m timer") == nil, "timer directives stay timers")
        check(OrderedList.item(in: "") == nil, "the empty line")
    }

    suite("accepts bare markers with no body") {
        let bare = OrderedList.item(in: "1.")
        equal(bare?.kind, .number(1), "1. on its own still parses")
        equal(bare?.body, "", "with nothing after it")
        let tabbed = OrderedList.item(in: "2.\tstart")
        equal(tabbed?.body, "start", "a tab separates as well as a space")
    }

    // MARK: - Successors

    suite("successors continue each sequence") {
        equal(OrderedMarkerKind.number(1).successor, .number(2), "numbers count up")
        equal(OrderedMarkerKind.number(9999).successor, nil, "numbers stop at 9999")
        equal(OrderedMarkerKind.letter("a").successor, .letter("b"), "letters advance")
        equal(OrderedMarkerKind.letter("A").successor, .letter("B"), "uppercase advances within its case")
        equal(OrderedMarkerKind.letter("z").successor, nil, "z has nowhere ordinary to go")
        equal(OrderedMarkerKind.letter("Z").successor, nil, "uppercase stops at Z, not '['")
        equal(OrderedMarkerKind.roman(4).successor, .roman(5), "successors count in value, not glyphs")
        equal(OrderedMarkerKind.roman(3999).successor, nil, "romans stop where they always have")
        equal(OrderedMarkerKind.roman(5).text, "v", "roman successors render as numerals")
        equal(OrderedMarkerKind.letter("b").text, "b", "letters render as themselves")
    }

    suite("roman conversion round-trips") {
        equal(OrderedMarkerKind.romanString(9), "ix", "the subtractive form, not viiii")
        equal(OrderedMarkerKind.romanString(14), "xiv", "subtractive pairs nest")
        equal(OrderedMarkerKind.romanString(40), "xl", "tens subtract from fifties")
        equal(OrderedMarkerKind.romanString(90), "xc", "hundreds too")
        equal(OrderedMarkerKind.romanString(400), "cd", "five-hundreds as well")
        equal(OrderedMarkerKind.romanString(1998), "mcmxcviii", "a long one, the way years come out")
        equal(OrderedMarkerKind.romanString(3999), "mmmcmxcix", "the ceiling itself")
        equal(OrderedMarkerKind.romanValue("mcmxcviii"), 1998, "and back again")
        check(OrderedMarkerKind.romanValue("mmmm") == nil, "mmmm totals 4000, past the roman ceiling")
        check(OrderedMarkerKind.isRomanText("ivxlcdm") && !OrderedMarkerKind.isRomanText("abc"), "only roman digits count as roman text")
    }

    // MARK: - Return behaviour

    suite("newline continues the sequence") {
        equal(OrderedList.newline(inLine: "1. eggs"), OrderedList.Newline.continueList("\n2. "), "numbers increment")
        equal(OrderedList.newline(inLine: "a. x"), OrderedList.Newline.continueList("\nb. "), "letters advance")
        equal(OrderedList.newline(inLine: "A. x"), OrderedList.Newline.continueList("\nB. "), "case carries forward")
        equal(OrderedList.newline(inLine: "iv. x"), OrderedList.Newline.continueList("\nv. "), "romans advance as numerals")
        equal(
            OrderedList.newline(inLine: "    3. deep"),
            OrderedList.Newline.continueList("\n    4. "),
            "the new line keeps the item's indent"
        )
    }

    suite("newline exits on empty items and passes prose through") {
        equal(OrderedList.newline(inLine: "3. "), OrderedList.Newline.exitList(""), "an empty item exits")
        equal(OrderedList.newline(inLine: "3."), OrderedList.Newline.exitList(""), "even with the space missing")
        check(OrderedList.newline(inLine: "z. done") == nil, "after z Return inserts an ordinary newline")
        check(OrderedList.newline(inLine: "plain text") == nil, "prose keeps its ordinary newline")
    }

    // MARK: - Coexistence with checkboxes

    suite("Checklist leaves ordered lines alone") {
        equal(Checklist.toggled(block: "1. eggs\nplain"), "1. eggs\n- [ ] plain",
              "toggling a mixed selection converts only the convertible line")
        equal(Checklist.toggled(block: "1. eggs\n2. flour"), "1. eggs\n2. flour",
              "a selection of nothing but ordered items never becomes checkboxes")
        equal(Checklist.itemized(line: "1. x"), "1. x", "an ordered line is already shaped")
        equal(Checklist.itemized(line: "iv. x"), "iv. x", "romans too")

        let note = "list\nmilk\n1. eggs"
        equal(Checklist.convertedToList(note, keyword: "list"),
              "list\n- [ ] milk\n1. eggs",
              "list-mode conversion preserves existing ordered items")

        if let pasted = Checklist.pastedAsListItems("step one\n1. already numbered", into: "list", keyword: "list") {
            equal(pasted, "- [ ] step one\n1. already numbered", "ordered lines survive pasting into a list note")
        } else {
            check(false, "multi-line paste into a list note should be itemised")
        }
    }

    // MARK: - The view layer

    suite("markers are painted bold secondary while bodies stay ordinary") {
        let view = makeTextView("1. eggs")

        guard let markerFont = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            check(false, "a font exists on the marker")
            return
        }
        check(markerFont.fontDescriptor.symbolicTraits.contains(.bold),
              "the marker itself is bold — the number IS the content here")

        guard let bodyFont = view.textStorage?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont,
              let markerColor = view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
              let bodyColor = view.textStorage?.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        else {
            check(false, "body attributes exist")
            return
        }
        check(!bodyFont.fontDescriptor.symbolicTraits.contains(.bold), "the body is not bold")
        check(markerColor != bodyColor, "the marker reads as secondary ink against the body")
    }

    suite("Return at the end of an item continues it through the real editor") {
        let view = makeTextView("note\n1. eggs")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)

        equal(view.string, "note\n1. eggs\n2. ", "the next marker is generated, not typed")
        equal(view.selectedRange(), NSRange(location: (view.string as NSString).length, length: 0),
              "the caret lands ready for the item body")
    }

    suite("Return on an empty item leaves the list through the real editor") {
        let view = makeTextView("3. ")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertNewline(nil)

        equal(view.string, "", "no stacked empty markers; the line empties out")
    }

    suite("Return after z falls through to an ordinary newline") {
        let view = makeTextView("z. done")
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.insertNewline(nil)

        equal(view.string, "z. done\n", "nothing invented past z")
    }

    suite("typing 1. inside a checklist note survives Return") {
        // List mode would wrap any plain line as `- [ ] …` when you leave it;
        // the ordered branch must win so `1.` keeps its own shape.
        let view = makeTextView("list\n1. eggs")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)

        equal(view.string, "list\n1. eggs\n2. ", "the ordered branch outranks list-mode wrapping")
    }
}
