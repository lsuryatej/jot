import AppKit
import SwiftUI
import Foundation

// Cmd+Shift+F keyboard navigation (design review M6): Up/Down move a
// selection through the results, Return opens the selected one rather than
// always the first, Escape closes, and the query is shown bold where it
// matched. The SwiftUI list is a thin shell over the pieces tested here: the
// selection model, the field's command routing, the bold runs and the
// VoiceOver announcement.

private func results(_ count: Int) -> [GlobalSearchResult] {
    (0..<count).map { index in
        GlobalSearchResult(noteID: UUID(), noteIndex: index, lineNumber: 1, snippet: "row \(index)",
                           matchRange: NSRange(location: 0, length: 3))
    }
}

/// The text of every run marked strongly emphasized, in order.
private func boldRuns(_ string: AttributedString) -> [String] {
    string.runs.compactMap { run in
        run.inlinePresentationIntent == .stronglyEmphasized ? String(string[run.range].characters) : nil
    }
}

func runGlobalSearchKeyboardTests() {
    suite("global search selection: starts on the first result") {
        equal(GlobalSearchSelection(count: 5).index, 0, "five results: the first is selected")
        equal(GlobalSearchSelection(count: 0).index, nil, "no results: nothing is selected")
    }

    suite("global search selection: Down and Up move one row and stop at the ends") {
        var selection = GlobalSearchSelection(count: 3)
        selection.moveDown(count: 3)
        equal(selection.index, 1, "Down moves to the second result")
        selection.moveDown(count: 3)
        equal(selection.index, 2, "and to the third")
        selection.moveDown(count: 3)
        equal(selection.index, 2, "Down on the last result stays there instead of wrapping")
        selection.moveUp(count: 3)
        equal(selection.index, 1, "Up moves back one")
        selection.moveUp(count: 3)
        selection.moveUp(count: 3)
        equal(selection.index, 0, "Up on the first result stays there")

        var empty = GlobalSearchSelection(count: 0)
        empty.moveDown(count: 0)
        empty.moveUp(count: 0)
        equal(empty.index, nil, "moving through no results selects nothing")
    }

    suite("global search selection: a new query starts over on the first result") {
        var selection = GlobalSearchSelection(count: 10)
        selection.moveDown(count: 10)
        selection.moveDown(count: 10)
        equal(selection.index, 2, "moved to the third result")
        selection.reset(count: 4)
        equal(selection.index, 0, "the query changed: back on the first result")
        selection.reset(count: 0)
        equal(selection.index, nil, "the new query matches nothing: no selection")
        selection.reset(count: 2)
        equal(selection.index, 0, "and matches again: the first result")
    }

    suite("global search selection: a shrinking list never leaves the selection past its end") {
        var selection = GlobalSearchSelection(count: 10)
        for _ in 0..<7 { selection.moveDown(count: 10) }
        equal(selection.index, 7, "on the eighth result")
        selection.clamp(count: 3)
        equal(selection.index, 2, "the list shrank to three: the last one is selected")
        selection.clamp(count: 0)
        equal(selection.index, nil, "the list emptied: nothing")
        selection.clamp(count: 2)
        equal(selection.index, 0, "results came back: the first")
    }

    suite("global search selection: Return opens the selected result, not always the first") {
        let list = results(4)
        var selection = GlobalSearchSelection(count: list.count)
        equal(selection.selected(in: list)?.noteIndex, 0, "untouched, Return opens the first")
        selection.moveDown(count: list.count)
        selection.moveDown(count: list.count)
        equal(selection.selected(in: list)?.noteIndex, 2, "after Down twice, Return opens the third")
        equal(GlobalSearchSelection(count: 0).selected(in: []), nil, "no results: Return opens nothing")
    }

    suite("global search field: the arrow, Return and Escape commands are routed, everything else is not") {
        equal(GlobalSearchKey(command: #selector(NSResponder.moveUp(_:))), .up, "Up arrow")
        equal(GlobalSearchKey(command: #selector(NSResponder.moveDown(_:))), .down, "Down arrow")
        equal(GlobalSearchKey(command: #selector(NSResponder.insertNewline(_:))), .open, "Return")
        equal(GlobalSearchKey(command: #selector(NSResponder.cancelOperation(_:))), .close, "Escape")
        equal(GlobalSearchKey(command: #selector(NSResponder.complete(_:))), .close,
              "Escape bound to completion closes too: a search field has nothing to complete")
        equal(GlobalSearchKey(command: #selector(NSResponder.moveLeft(_:))), nil, "Left stays with the field's caret")
        equal(GlobalSearchKey(command: #selector(NSResponder.deleteBackward(_:))), nil, "Delete stays with the field")
    }

    MainActor.assumeIsolated {
        suite("global search field: the field editor's commands reach the list") {
            var received: [GlobalSearchKey] = []
            let coordinator = GlobalSearchField.Coordinator(text: .constant(""), onKey: { received.append($0) })
            let field = NSTextField()
            let editor = NSTextView()
            check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))),
                  "Down is consumed, so the field's caret does not jump to the end")
            check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))),
                  "Up is consumed")
            check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                  "Return is consumed")
            check(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
                  "Escape is consumed")
            check(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))),
                  "Left is left to the field")
            equal(received, [.down, .up, .open, .close], "each one reached the list, in order")
        }
    }

    suite("global search: the matched text is bold, every occurrence, in any case") {
        equal(boldRuns(GlobalSearch.highlighted("Budget for the budget meeting", matching: "budget")),
              ["Budget", "budget"], "both occurrences, each in its own case")
        equal(String(GlobalSearch.highlighted("Budget for the budget meeting", matching: "budget").characters),
              "Budget for the budget meeting", "the text itself is untouched")
        equal(boldRuns(GlobalSearch.highlighted("Groceries", matching: "  cer ")),
              ["cer"], "the query is trimmed the same way the search trims it")
        equal(boldRuns(GlobalSearch.highlighted("Groceries", matching: "milk")), [],
              "a title that does not contain the query has nothing bold")
        equal(boldRuns(GlobalSearch.highlighted("Groceries", matching: "")), [], "an empty query bolds nothing")
        equal(boldRuns(GlobalSearch.highlighted("naïve café ☕️ café", matching: "café")), ["café", "café"],
              "ranges survive characters outside ASCII")
    }

    suite("global search: a long line is cut so the match stays in view") {
        let line = String(repeating: "lorem ipsum ", count: 12) + "the needle is here and then more text follows"
        let excerpt = GlobalSearch.excerpt(of: line, around: "needle")
        check(excerpt.hasPrefix("…"), "the cut is marked: \(excerpt)")
        check(excerpt.contains("needle"), "the match is kept")
        let distance = (excerpt as NSString).range(of: "needle").location
        check(distance <= GlobalSearch.excerptLead + 2, "and sits near the start, where one line can show it (\(distance))")
        equal(GlobalSearch.excerpt(of: "short line with needle", around: "needle"), "short line with needle",
              "a match already near the start is left alone")
        equal(GlobalSearch.excerpt(of: "no match here", around: "needle"), "no match here",
              "no match: the line is left alone")
    }

    suite("global search: VoiceOver hears the selected row and where it is in the list") {
        equal(GlobalSearch.announcement(title: "Groceries", snippet: "oat milk", position: 1, count: 14),
              "Groceries: oat milk, 2 of 14", "title, snippet, and a 1-based position")
        equal(GlobalSearch.announcement(title: "Trip", snippet: "budget = 45000", position: 0, count: 1),
              "Trip: budget = 45000, 1 of 1", "a single result")
    }
}
