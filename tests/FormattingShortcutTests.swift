import AppKit
import Foundation

// Cmd+B / Cmd+I (issue #12): the pure edit Emphasis.toggle computes, and the
// view wiring that turns it into one undoable text change.
//
// Behaviour under test, stated once:
//   - a selection is wrapped in `**` / `*`, surrounding whitespace trimmed
//     off first so the markers hug the text (the parser needs that);
//   - a selection or caret already inside a span of that kind unwraps it,
//     whether the markers sit just outside the selection or inside it;
//   - a caret strictly inside a word wraps that word (Typora / VS Code
//     Markdown All in One), anywhere else inserts an empty pair with the
//     caret between, and pressing again on that empty pair removes it;
//   - a wrap the parser could not read back (across lines, into inline
//     code, italic inside bold) changes nothing at all.

/// Applies an edit the way the view does, for the pure tests.
private func applying(_ edit: Emphasis.ToggleEdit?, to text: String) -> String? {
    guard let edit else { return nil }
    return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
}

/// Supplies an undo manager to a text view that has no window, through the
/// delegate hook NSTextView consults first.
private final class UndoProvider: NSObject, NSTextViewDelegate {
    let manager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

private func formattingKey(_ view: ChecklistTextView, _ chars: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> Bool {
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: 0
    )!
    return view.performKeyEquivalent(with: event)
}

private final class MenuTarget: NSObject {
    @objc func noop() {}
}

func runFormattingShortcutTests() {

    // MARK: - Wrapping a selection

    suite("Cmd+B wraps a selection in **") {
        let text = "make this bold"
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 10, length: 4))
        equal(applying(edit, to: text), "make this **bold**", "the selected word is wrapped")
        equal(edit?.selection, NSRange(location: 12, length: 4), "the selection stays on the word, markers excluded")
    }

    suite("Cmd+I wraps a selection in *") {
        let text = "make this lean"
        let edit = Emphasis.toggle(.emphasis, in: text as NSString, selection: NSRange(location: 10, length: 4))
        equal(applying(edit, to: text), "make this *lean*", "one asterisk each side")
        equal(edit?.selection, NSRange(location: 11, length: 4), "selection on the content")
    }

    suite("a selection with stray whitespace is trimmed before wrapping") {
        let text = "one two three"
        // " two " — a drag that grabbed the spaces either side.
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 3, length: 5))
        equal(applying(edit, to: text), "one **two** three",
              "markers hug the word, since `** two **` would never parse as bold")
    }

    suite("a multi-word selection wraps as one span") {
        let text = "a quick brown fox"
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 2, length: 11))
        equal(applying(edit, to: text), "a **quick brown** fox", "the whole phrase")
    }

    // MARK: - Unwrapping

    suite("Cmd+B on the content of a bold span unwraps it (markers outside the selection)") {
        let text = "make this **bold** now"
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 12, length: 4))
        equal(applying(edit, to: text), "make this bold now", "the markers are removed")
        equal(edit?.selection, NSRange(location: 10, length: 4), "the word stays selected")
    }

    suite("Cmd+B on a whole bold span unwraps it (markers inside the selection)") {
        let text = "make this **bold** now"
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 10, length: 8))
        equal(applying(edit, to: text), "make this bold now", "the markers are removed")
        equal(edit?.selection, NSRange(location: 10, length: 4), "the word stays selected")
    }

    suite("Cmd+I on an italic span unwraps it") {
        let text = "a *soft* word"
        let edit = Emphasis.toggle(.emphasis, in: text as NSString, selection: NSRange(location: 3, length: 4))
        equal(applying(edit, to: text), "a soft word", "single markers removed")
    }

    suite("wrap then toggle again round-trips") {
        var text = "round trip"
        guard let first = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 6, length: 4)) else {
            check(false, "first toggle wraps")
            return
        }
        text = applying(first, to: text)!
        let second = Emphasis.toggle(.strong, in: text as NSString, selection: first.selection)
        equal(applying(second, to: text), "round trip", "the selection the wrap left behind is what unwraps it")
    }

    suite("a caret inside a bold span unwraps it and keeps its place") {
        let text = "x **bold** y"
        // Caret between "bo" and "ld".
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 7, length: 0))
        equal(applying(edit, to: text), "x bold y", "unwrapped")
        equal(edit?.selection, NSRange(location: 5, length: 0), "caret still between bo|ld")
    }

    suite("Cmd+I does not unwrap bold, and Cmd+B does not unwrap italic") {
        let bold = "**bold**"
        let italicOnBold = Emphasis.toggle(.emphasis, in: bold as NSString, selection: NSRange(location: 2, length: 4))
        check(italicOnBold == nil, "`***bold***` would not parse, so italic inside bold is refused rather than written")
        let italic = "*lean*"
        let boldOnItalic = Emphasis.toggle(.strong, in: italic as NSString, selection: NSRange(location: 1, length: 4))
        check(boldOnItalic == nil, "same the other way round")
    }

    // MARK: - No selection

    suite("a caret between words inserts an empty pair with the caret inside") {
        let text = "type "
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 5, length: 0))
        equal(applying(edit, to: text), "type ****", "an empty bold pair")
        equal(edit?.selection, NSRange(location: 7, length: 0), "caret between the markers")

        let italic = Emphasis.toggle(.emphasis, in: "" as NSString, selection: NSRange(location: 0, length: 0))
        equal(applying(italic, to: ""), "**", "an empty italic pair in an empty note")
        equal(italic?.selection, NSRange(location: 1, length: 0), "caret between them")
    }

    suite("a caret at the end of a word inserts a pair rather than wrapping it") {
        let text = "hello"
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 5, length: 0))
        equal(applying(edit, to: text), "hello****", "so you can keep typing bold straight after")
    }

    suite("a caret strictly inside a word wraps the word") {
        let text = "one middle two"
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 7, length: 0))
        equal(applying(edit, to: text), "one **middle** two", "the word under the caret")
        equal(edit?.selection, NSRange(location: 9, length: 0), "caret stays on the same letter")
    }

    suite("pressing again on a just-inserted empty pair removes it") {
        let bold = Emphasis.toggle(.strong, in: "a **** b" as NSString, selection: NSRange(location: 4, length: 0))
        equal(applying(bold, to: "a **** b"), "a  b", "empty bold pair gone")
        equal(bold?.selection, NSRange(location: 2, length: 0), "caret where the pair was")

        let italic = Emphasis.toggle(.emphasis, in: "a ** b" as NSString, selection: NSRange(location: 3, length: 0))
        equal(applying(italic, to: "a ** b"), "a  b", "empty italic pair gone")
    }

    // MARK: - Refusals and math

    suite("a selection across lines is refused") {
        let text = "one\ntwo"
        check(Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 0, length: 7)) == nil,
              "the parser is per line, so markers split across a newline would stay literal")
    }

    suite("a selection inside inline code is refused") {
        let text = "run `ls -la` now"
        check(Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 5, length: 2)) == nil,
              "asterisks inside backticks are literal")
    }

    suite("a whitespace-only selection does nothing") {
        check(Emphasis.toggle(.strong, in: "a   b" as NSString, selection: NSRange(location: 1, length: 3)) == nil,
              "nothing to embolden")
    }

    suite("a word on a math line can still be wrapped explicitly") {
        // `price = 4` evaluates, so the renderer treats the line as math. The
        // shortcut is an explicit request, so it still writes the markers,
        // and it can take them off again.
        let text = "price = 4"
        let edit = Emphasis.toggle(.strong, in: text as NSString, selection: NSRange(location: 0, length: 5))
        equal(applying(edit, to: text), "**price** = 4", "wrapped despite the line being math")
        let wrapped = "**price** = 4"
        let undo = Emphasis.toggle(.strong, in: wrapped as NSString, selection: NSRange(location: 2, length: 5))
        equal(applying(undo, to: wrapped), "price = 4", "and unwrapped again")
    }

    suite("multiplication on a math line is never read as a span to unwrap") {
        // `2*3*4` looks like `*3*` to a scanner that ignores math, so a caret
        // on the 3 must not strip the operators out of the expression.
        let text = "2*3*4"
        let edit = Emphasis.toggle(.emphasis, in: text as NSString, selection: NSRange(location: 2, length: 0))
        check(applying(edit, to: text) != "234", "the expression's operators survive")
    }

    // MARK: - The view

    suite("Cmd+B in the view wraps the selection") {
        let view = makeTextView("make this bold")
        view.setSelectedRange(NSRange(location: 10, length: 4))
        check(formattingKey(view, "b"), "Cmd+B is claimed by the editor")
        equal(view.string, "make this **bold**", "wrapped")
        equal(view.selectedRange(), NSRange(location: 12, length: 4), "selection on the word")
    }

    suite("Cmd+I in the view wraps the selection") {
        let view = makeTextView("make this lean")
        view.setSelectedRange(NSRange(location: 10, length: 4))
        check(formattingKey(view, "i"), "Cmd+I is claimed by the editor")
        equal(view.string, "make this *lean*", "wrapped")
    }

    suite("Cmd+Shift+B and Cmd+Shift+I are not claimed") {
        let view = makeTextView("text")
        view.setSelectedRange(NSRange(location: 0, length: 4))
        _ = formattingKey(view, "b", [.command, .shift])
        _ = formattingKey(view, "i", [.command, .shift])
        equal(view.string, "text", "only the bare Cmd chord formats")
    }

    suite("Cmd+B does nothing in a code note") {
        let view = makeTextView("code\nlet x = 1")
        view.setSelectedRange(NSRange(location: 5, length: 3))
        view.toggleBold(nil)
        equal(view.string, "code\nlet x = 1", "asterisks mean nothing in code, so none are written")
    }

    suite("the wrapped text renders bold with its markers folded") {
        let view = makeTextView("make this bold")
        view.baseFont = .systemFont(ofSize: 13)
        view.setSelectedRange(NSRange(location: 10, length: 4))
        view.toggleBold(nil)
        let font = view.textStorage?.attribute(.font, at: 12, effectiveRange: nil) as? NSFont
        check(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false, "the content is bold")
        equal(view.emphasisMarkers, [NSRange(location: 10, length: 2), NSRange(location: 16, length: 2)],
              "both markers are on the fold list")
    }

    suite("Cmd+B folds the new markers at once and leaves the line's height alone") {
        let view = makeTextView("first line\nmake this bold\nlast line")
        view.baseFont = .systemFont(ofSize: 13)
        guard let lm = view.layoutManager, let tc = view.textContainer else {
            check(false, "view has a layout manager")
            return
        }
        lm.ensureLayout(for: tc)
        func fragment(at character: Int) -> NSRect {
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: character), effectiveRange: nil)
        }
        let lineBefore = fragment(at: 11)
        let lastBefore = fragment(at: (view.string as NSString).length - 1)

        view.setSelectedRange(NSRange(location: 21, length: 4))
        view.toggleBold(nil)
        lm.ensureLayout(for: tc)

        equal(view.selectedRange(), NSRange(location: 23, length: 4), "selection still on the word, not jumped")
        let opening = lm.glyphIndexForCharacter(at: 21)
        let closing = lm.glyphIndexForCharacter(at: 27)
        check(lm.notShownAttribute(forGlyphAt: opening) && lm.notShownAttribute(forGlyphAt: closing),
              "the markers are folded synchronously, never drawn for a frame")
        equal(fragment(at: 11).height, lineBefore.height, "the bolded line keeps its height")
        equal(fragment(at: (view.string as NSString).length - 1).origin.y, lastBefore.origin.y,
              "the line below does not move")
    }

    suite("one Cmd+B is one undo step") {
        let view = makeTextView("make this bold")
        let provider = UndoProvider()
        view.delegate = provider
        view.allowsUndo = true
        view.setSelectedRange(NSRange(location: 10, length: 4))

        provider.manager.beginUndoGrouping()
        view.toggleBold(nil)
        provider.manager.endUndoGrouping()
        equal(view.string, "make this **bold**", "wrapped")
        check(provider.manager.canUndo, "the wrap registered with the undo manager")

        provider.manager.undo()
        equal(view.string, "make this bold", "a single undo restores the original text")
        check(!provider.manager.canUndo, "and there was nothing else to undo")
        view.delegate = nil
    }

    suite("the wrap is a single text change") {
        // One replaceCharacters, so one undo action, whatever the grouping:
        // count the storage edits the toggle makes.
        let view = makeTextView("one middle two")
        var edits = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: view, queue: nil
        ) { _ in edits += 1 }
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.toggleBold(nil)
        NotificationCenter.default.removeObserver(token)
        equal(view.string, "one **middle** two", "word wrapped")
        equal(edits, 1, "exactly one text change was made")
    }

    suite("the Format menu offers Bold and Italic") {
        let menu = MainMenu.build(
            target: MenuTarget(),
            preferencesAction: #selector(MenuTarget.noop),
            newNoteAction: #selector(MenuTarget.noop),
            globalSearchAction: #selector(MenuTarget.noop),
            moveNoteUpAction: #selector(MenuTarget.noop),
            moveNoteDownAction: #selector(MenuTarget.noop),
            nextNoteAction: #selector(MenuTarget.noop),
            previousNoteAction: #selector(MenuTarget.noop),
            toggleChromeAction: #selector(MenuTarget.noop),
            toggleChecklistAction: #selector(MenuTarget.noop),
            toggleHighlightAction: #selector(MenuTarget.noop)
        )
        let format = menu.items.first { $0.submenu?.title == "Format" }?.submenu
        let bold = format?.items.first { $0.title == "Bold" }
        let italic = format?.items.first { $0.title == "Italic" }
        equal(bold?.keyEquivalent, "b", "Bold shows Cmd+B")
        equal(bold?.keyEquivalentModifierMask, [.command], "with no other modifier")
        equal(italic?.keyEquivalent, "i", "Italic shows Cmd+I")
        check(bold?.action == #selector(ChecklistTextView.toggleBold(_:)), "Bold reaches the editor")
        check(italic?.action == #selector(ChecklistTextView.toggleItalic(_:)), "Italic reaches the editor")
        let allItems = menu.items.flatMap { $0.submenu?.items ?? [] }
        equal(allItems.filter { $0.keyEquivalent == "b" && $0.keyEquivalentModifierMask == [.command] }.count, 1,
              "nothing else in the menu bar claims Cmd+B")
        equal(allItems.filter { $0.keyEquivalent == "i" && $0.keyEquivalentModifierMask == [.command] }.count, 1,
              "nothing else in the menu bar claims Cmd+I")
    }
}
