import AppKit
import Foundation

// Coverage for the `code` keyword: the pure parser in CodeBlock.swift, and
// what ChecklistTextView does with it — monospaced rendering, every other
// parser switched off, and Cmd+C copying the whole block.

/// A code note ready to inspect. Separate from `makeTextView` because the
/// font matters here: the default base font is already monospaced, which
/// would hide whether code mode is doing the overriding.
private func makeCodeView(_ text: String, baseFont: NSFont = .systemFont(ofSize: 13)) -> ChecklistTextView {
    let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    view.textStorage?.delegate = view
    view.string = text
    view.baseFont = baseFont
    view.applyChecklistStyling()
    view.recomputeMathResults()
    view.recomputeLinkMatches()
    view.applyLinkFolding()
    return view
}

private func font(in view: ChecklistTextView, at location: Int) -> NSFont? {
    view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
}

func runCodeBlockTests() {

    // MARK: - Parsing

    suite("a bare keyword on the first line is a code note") {
        check(CodeBlock.isCodeMode("code\nlet x = 1", keyword: "code"), "keyword alone on line one")
        check(CodeBlock.isCodeMode("  CODE  \nlet x = 1", keyword: "code"),
              "matched after trimming and case-insensitively, like the list keyword")
        check(CodeBlock.isCodeMode("code", keyword: "code"), "a note holding nothing but the keyword")
    }

    suite("anything else on the first line is not a code note") {
        check(!CodeBlock.isCodeMode("code me up\nlet x = 1", keyword: "code"), "keyword plus other words")
        check(!CodeBlock.isCodeMode("notes\ncode", keyword: "code"), "keyword on a later line")
        check(!CodeBlock.isCodeMode("encoded\n", keyword: "code"), "keyword as part of a longer word")
        check(!CodeBlock.isCodeMode("", keyword: "code"), "an empty note")
    }

    suite("the keyword is configurable") {
        check(CodeBlock.isCodeMode("snippet\nlet x = 1", keyword: "snippet"), "a custom keyword matches")
        check(!CodeBlock.isCodeMode("code\nlet x = 1", keyword: "snippet"),
              "and the default one no longer does")
        check(!CodeBlock.isCodeMode("code\nlet x = 1", keyword: "   "),
              "an empty keyword never matches, so no note is silently a code block")
    }

    // MARK: - What Cmd+C copies

    suite("the copied body leaves the keyword line out") {
        equal(CodeBlock.body(of: "code\nlet x = 1\nprint(x)", keyword: "code"),
              "let x = 1\nprint(x)", "the directive is not part of the code")
    }

    suite("interior blank lines survive, trailing ones do not") {
        equal(CodeBlock.body(of: "code\nfirst\n\nsecond\n\n\n", keyword: "code"),
              "first\n\nsecond", "blank lines inside the code are code; the trailing ones are not")
    }

    suite("a keyword-only note copies as nothing") {
        equal(CodeBlock.body(of: "code", keyword: "code"), "", "no code yet, so no code copied")
        equal(CodeBlock.body(of: "code\n\n", keyword: "code"), "", "and blank lines after it are still nothing")
    }

    suite("a note that is not a code block has no body") {
        check(CodeBlock.body(of: "shopping\nmilk", keyword: "code") == nil,
              "nil, so the caller falls through to the ordinary copy")
    }

    // MARK: - Rendering

    suite("a code note renders monospaced even when the resolved font is not") {
        let view = makeCodeView("code\nlet x = 1", baseFont: .systemFont(ofSize: 13))
        guard let bodyFont = font(in: view, at: 6) else {
            check(false, "the body carries a font attribute")
            return
        }
        check(bodyFont.isFixedPitch, "code mode overrides a proportional per-note or theme font")
        equal(bodyFont.pointSize, 13, "and keeps the size that font resolution settled on")
    }

    suite("a base font that is already monospaced is left alone") {
        guard let menlo = NSFont(name: "Menlo", size: 15) else {
            check(false, "Menlo is available on macOS")
            return
        }
        let view = makeCodeView("code\nlet x = 1", baseFont: menlo)
        equal(font(in: view, at: 6)?.fontName, menlo.fontName,
              "a monospaced face the user or a theme note picked stays theirs")
    }

    suite("an ordinary note is untouched by the code font") {
        let view = makeCodeView("notes\nlet x = 1", baseFont: .systemFont(ofSize: 13))
        equal(font(in: view, at: 6)?.isFixedPitch, false, "no code keyword, no monospacing")
    }

    // MARK: - Parsers switched off

    suite("headings do not style inside a code block") {
        let plain = makeCodeView("notes\n# Heading")
        let code = makeCodeView("code\n# Heading")
        let plainHeading = font(in: plain, at: 8)
        let codeHeading = font(in: code, at: 7)
        check(plainHeading!.pointSize > 13, "a heading outside a code block is sized up (control)")
        equal(codeHeading?.pointSize, 13, "inside one it is body-sized text with a hash in front of it")
        check(code.headingMarkers.isEmpty, "and no marker is registered for folding")
    }

    suite("highlights do not paint inside a code block") {
        let code = makeCodeView("code\nx == y == z")
        let painted = code.textStorage?.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? NSColor
        check(painted != Highlight.backgroundColor, "`==` is an operator here, not a highlighter")
        check(code.highlightMarkers.isEmpty, "and no marker is registered for folding")
    }

    suite("checklist markers do not style inside a code block") {
        let code = makeCodeView("code\n- [x] done")
        let struck = code.textStorage?.attribute(.strikethroughStyle, at: 11, effectiveRange: nil)
        check(struck == nil, "no strikethrough on what looks like a checked item")
    }

    suite("ordered-list markers do not style inside a code block") {
        let code = makeCodeView("code\n1. one")
        guard let marker = font(in: code, at: 5) else {
            check(false, "the marker carries a font attribute")
            return
        }
        check(!marker.fontDescriptor.symbolicTraits.contains(.bold), "`1.` stays plain text")
    }

    suite("links do not shrink or underline inside a code block") {
        let code = makeCodeView("code\nfetch(\"https://example.com/a/b\")")
        let underline = code.textStorage?.attribute(.underlineStyle, at: 12, effectiveRange: nil)
        check(underline == nil, "a URL in a string literal is left exactly as typed")
    }

    suite("the keyword line itself is painted like the list keyword's") {
        let code = makeCodeView("code\nlet x = 1")
        let keywordColor = code.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        equal(keywordColor, code.ink.secondary, "pale, the same treatment list mode gives its keyword")
    }

    // MARK: - Commands

    suite("Cmd+L does nothing inside a code block") {
        let view = makeCodeView("code\nlet x = 1")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.toggleChecklist(nil)
        equal(view.string, "code\nlet x = 1", "no checkbox is written into the code")
        // Chained: a second real press, from whatever state the first left.
        view.toggleChecklist(nil)
        equal(view.string, "code\nlet x = 1", "and a second press still does nothing")
    }

    suite("Cmd+Shift+H does nothing inside a code block") {
        let view = makeCodeView("code\nlet x = 1")
        view.setSelectedRange(NSRange(location: 5, length: 3))  // "let"
        view.toggleHighlight(nil)
        equal(view.string, "code\nlet x = 1", "no `==` markers are inserted")
        view.toggleHighlight(nil)
        equal(view.string, "code\nlet x = 1", "and a second press still does nothing")
    }

    suite("both commands are offered again once the note stops being code") {
        let view = makeCodeView("code\nlet x = 1")
        check(!view.validateUserInterfaceItem(FakeMenuItem(action: #selector(ChecklistTextView.toggleChecklist(_:)))),
              "Checklist is greyed out in a code note")
        // Chained: edit the keyword away using the state the view is really in.
        view.replace(range: NSRange(location: 0, length: 4), with: "notes", selecting: NSRange(location: 5, length: 0))
        check(view.validateUserInterfaceItem(FakeMenuItem(action: #selector(ChecklistTextView.toggleChecklist(_:)))),
              "and offered again once it is an ordinary note")
    }

    suite("Return does not continue a list inside a code block") {
        let view = makeCodeView("code\n- [ ] item")
        view.setSelectedRange(NSRange(location: 15, length: 0))  // end of the line
        view.insertNewline(nil)
        equal(view.string, "code\n- [ ] item\n", "a plain newline, no fresh item")
        // Chained: press Return again from where the first press left the caret.
        view.insertNewline(nil)
        equal(view.string, "code\n- [ ] item\n\n", "still just newlines")
    }

    suite("Cmd+C with nothing selected copies the whole block") {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("JotCodeBlockTest-\(UUID().uuidString)"))
        let view = makeCodeView("code\nlet x = 1\nprint(x)")
        view.setSelectedRange(NSRange(location: 8, length: 0))  // caret inside the code
        check(view.copyWholeCodeBlock(to: pasteboard), "the copy is handled here, not by the ordinary one")
        equal(pasteboard.string(forType: .string), "let x = 1\nprint(x)", "the whole block lands on the clipboard")
    }

    suite("Cmd+C with a selection copies only the selection") {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("JotCodeBlockTest-\(UUID().uuidString)"))
        let view = makeCodeView("code\nlet x = 1\nprint(x)")
        view.setSelectedRange(NSRange(location: 5, length: 3))  // "let"
        check(!view.copyWholeCodeBlock(to: pasteboard),
              "a selection is an explicit request for that text, so the ordinary copy runs")
        // Chained: clear the selection the way clicking back into the code
        // would, and the whole block is claimed again.
        view.setSelectedRange(NSRange(location: 8, length: 0))
        check(view.copyWholeCodeBlock(to: pasteboard), "caret only, so the whole block is copied")
        equal(pasteboard.string(forType: .string), "let x = 1\nprint(x)", "and that is what landed")
    }

    suite("Cmd+C in an ordinary note is left to the ordinary copy") {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("JotCodeBlockTest-\(UUID().uuidString)"))
        let view = makeCodeView("notes\nlet x = 1")
        check(!view.copyWholeCodeBlock(to: pasteboard), "nothing is claimed")
        check(pasteboard.string(forType: .string) == nil, "and nothing is written to the clipboard")
    }

    // MARK: - Switching modes on real edits

    // The transition is where the interesting bugs live: styling is normally
    // limited to the edited line, so typing the keyword has to restyle every
    // other line too. Each step below feeds on the state the previous one
    // actually produced rather than a hand-built view.

    suite("typing the keyword restyles the lines above and below it") {
        let view = makeCodeView("# Heading\n==note==\n")
        let heading = font(in: view, at: 2)
        check(heading!.pointSize > 13, "the heading starts out styled as one (control)")

        // Step 1: the keyword arrives on a new first line, as typing it would.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.replace(range: NSRange(location: 0, length: 0), with: "code\n", selecting: NSRange(location: 5, length: 0))
        check(view.isCodeMode, "the note is now a code block")
        equal(font(in: view, at: 7)?.pointSize, 13, "the heading below stopped being a heading")
        check(view.headingMarkers.isEmpty, "no heading marker is left registered for folding")
        check(view.highlightMarkers.isEmpty, "and no highlight marker either")

        // Step 2: the keyword is edited away again, from that same state.
        view.replace(range: NSRange(location: 0, length: 5), with: "", selecting: NSRange(location: 0, length: 0))
        check(!view.isCodeMode, "the note is an ordinary note again")
        check(font(in: view, at: 2)!.pointSize > 13, "the heading is styled as a heading again")
        equal(view.headingMarkers.count, 1, "and its marker is registered for folding again")
    }

    suite("code mode wins when the same word is set for both keywords") {
        let view = makeCodeView("code\n- [ ] item")
        view.listKeyword = "code"
        view.codeKeyword = "code"
        check(view.isCodeMode, "the note is a code block")
        check(!view.isListMode, "and not also a checklist, so the two never half-apply over each other")
    }
}

/// The smallest thing that satisfies `validateUserInterfaceItem`, which only
/// ever reads the action off it.
private final class FakeMenuItem: NSObject, NSValidatedUserInterfaceItem {
    let action: Selector?
    let tag: Int = 0

    init(action: Selector?) {
        self.action = action
    }
}
