import AppKit
import Carbon.HIToolbox
import Foundation

// Rearranging list items (issue #12 item 6): Ctrl-Cmd-Up/Down and dragging
// an item by its marker. The rules live in `ListMove`; these check them
// directly, then the view wiring that turns them into one undoable edit.

private func applied(_ outcome: ListMove.Outcome, to text: String) -> (String, NSRange)? {
    guard case .moved(let edit) = outcome else { return nil }
    return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
}

private func applied(_ edit: ListMove.Edit?, to text: String) -> String? {
    guard let edit else { return nil }
    return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
}

private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

private func location(of needle: String, in text: String) -> Int {
    (text as NSString).range(of: needle).location
}

private final class ListUndoProvider: NSObject, NSTextViewDelegate {
    let manager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

private func chord(_ view: ChecklistTextView, _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = [.command, .control, .numericPad, .function]) -> Bool {
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: UInt16(keyCode)
    )!
    return view.performKeyEquivalent(with: event)
}

private func posts(_ name: Notification.Name, _ body: () -> Void) -> Bool {
    var fired = false
    let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in fired = true }
    defer { NotificationCenter.default.removeObserver(token) }
    body()
    return fired
}

private func markerCenter(_ range: NSRange, in view: ChecklistTextView) -> NSPoint {
    let lm = view.layoutManager!, tc = view.textContainer!
    lm.ensureLayout(for: tc)
    var rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc)
    rect.origin.x += view.textContainerInset.width
    rect.origin.y += view.textContainerInset.height
    return NSPoint(x: rect.midX, y: rect.midY)
}

func runListMoveTests() {

    // MARK: - Pure moves

    suite("Ctrl-Cmd-Up moves a bullet above its previous sibling") {
        let text = "- a\n- b\n- c"
        let result = applied(ListMove.move(.up, in: text, selection: caret(5)), to: text)
        equal(result?.0, "- b\n- a\n- c", "b and a swapped")
        equal(result?.1, caret(1), "the caret rides along, same column on the moved line")
    }

    suite("Ctrl-Cmd-Down moves an item below its next sibling") {
        let text = "- [ ] a\n- [x] b\n- [ ] c"
        let result = applied(ListMove.move(.down, in: text, selection: caret(7)), to: text)
        equal(result?.0, "- [x] b\n- [ ] a\n- [ ] c", "a and b swapped")
        equal(result?.1, caret(15), "caret at the end of a, now the second line")
    }

    suite("at the ends of a list the move is refused") {
        let text = "- a\n- b"
        equal(ListMove.move(.up, in: text, selection: caret(1)), .atBoundary, "the first item cannot go up")
        equal(ListMove.move(.down, in: text, selection: caret(6)), .atBoundary, "the last item cannot go down")
        equal(ListMove.move(.up, in: "- only", selection: caret(3)), .atBoundary, "a lone item has nowhere to go")
    }

    suite("a caret outside any list item is not a list move") {
        equal(ListMove.move(.up, in: "plain\n- a", selection: caret(2)), .notInList, "prose line")
        equal(ListMove.move(.down, in: "", selection: caret(0)), .notInList, "empty note")
        equal(ListMove.move(.up, in: "- a\n\nprose", selection: caret(6)), .notInList, "prose after a list")
    }

    suite("a blank line ends the list") {
        let text = "- a\n\n- b"
        equal(ListMove.move(.up, in: text, selection: caret(7)), .atBoundary, "b is the first of its own list")
        equal(ListMove.move(.down, in: text, selection: caret(2)), .atBoundary, "a is the last of its own list")
    }

    suite("a prose line at the same indent ends the list") {
        let text = "- a\nprose\n- b"
        equal(ListMove.move(.up, in: text, selection: caret(11)), .atBoundary, "b does not jump over the prose")
    }

    // MARK: - Nesting

    suite("nested children move with their parent") {
        let text = "- [ ] a\n    - [ ] a1\n    - [ ] a2\n- [ ] b"
        let result = applied(ListMove.move(.up, in: text, selection: caret(location(of: "b", in: text) + 1)), to: text)
        equal(result?.0, "- [ ] b\n- [ ] a\n    - [ ] a1\n    - [ ] a2", "b goes above a and both of a's children")

        let down = applied(ListMove.move(.down, in: text, selection: caret(3)), to: text)
        equal(down?.0, "- [ ] b\n- [ ] a\n    - [ ] a1\n    - [ ] a2", "moving a down carries its children past b")
        equal(down?.1, caret(11), "caret still on a's marker column")
    }

    suite("a child moves among its siblings and never leaves its parent") {
        let text = "- a\n    - a1\n    - a2\n- b"
        let result = applied(ListMove.move(.up, in: text, selection: caret(location(of: "a2", in: text))), to: text)
        equal(result?.0, "- a\n    - a2\n    - a1\n- b", "a2 above a1")
        equal(ListMove.move(.up, in: text, selection: caret(location(of: "a1", in: text))), .atBoundary,
              "the first child stays under its parent")
        equal(ListMove.move(.down, in: text, selection: caret(location(of: "a2", in: text))), .atBoundary,
              "the last child stays under its parent")
    }

    suite("grandchildren travel with their parent") {
        let text = "- a\n    - a1\n        - deep\n    - a2"
        let result = applied(ListMove.move(.down, in: text, selection: caret(location(of: "a1", in: text))), to: text)
        equal(result?.0, "- a\n    - a2\n    - a1\n        - deep", "deep stays under a1")
    }

    suite("tab-indented children count as nested") {
        let text = "- a\n\t- a1\n- b"
        let result = applied(ListMove.move(.up, in: text, selection: caret(location(of: "b", in: text))), to: text)
        equal(result?.0, "- b\n- a\n\t- a1", "the tab child moved with a")
    }

    suite("a caret on a child's continuation line moves that child") {
        let text = "- a\n    wrapped detail\n- b"
        let result = applied(ListMove.move(.down, in: text, selection: caret(location(of: "detail", in: text))), to: text)
        equal(result?.0, "- b\n- a\n    wrapped detail", "the detail line belongs to a")
    }

    // MARK: - Renumbering

    suite("a numbered list renumbers after a move") {
        let text = "1. one\n2. two\n3. three"
        let result = applied(ListMove.move(.up, in: text, selection: caret(location(of: "three", in: text) + 2)), to: text)
        equal(result?.0, "1. one\n2. three\n3. two", "numbers stay in order, text moved")
        equal(result?.1, caret(location(of: "three", in: "1. one\n2. three\n3. two") + 2), "caret stays inside 'three'")
    }

    suite("renumbering across a width change keeps the caret on its text") {
        let text = "8. h\n9. i\n10. j"
        let result = applied(ListMove.move(.up, in: text, selection: caret((text as NSString).length)), to: text)
        equal(result?.0, "8. h\n9. j\n10. i", "9/10 kept in place, j moved")
        equal(result?.1, caret(9), "caret after j, one column left because the marker shrank")
    }

    suite("a list numbered from 3 keeps starting at 3") {
        let text = "3. c\n4. d"
        equal(applied(ListMove.move(.down, in: text, selection: caret(1)), to: text)?.0, "3. d\n4. c", "starts at 3")
    }

    suite("letters and roman numerals renumber too") {
        equal(applied(ListMove.move(.down, in: "a. x\nb. y", selection: caret(1)), to: "a. x\nb. y")?.0, "a. y\nb. x", "letters")
        equal(applied(ListMove.move(.down, in: "i. x\nii. y", selection: caret(1)), to: "i. x\nii. y")?.0, "i. y\nii. x", "roman")
    }

    suite("a list typed out of sequence is not renumbered") {
        let text = "1. a\n1. b\n1. c"
        equal(applied(ListMove.move(.down, in: text, selection: caret(1)), to: text)?.0, "1. b\n1. a\n1. c", "kept as typed")
    }

    suite("nested numbered children keep their own numbers") {
        let text = "1. a\n    1. a1\n    2. a2\n2. b"
        let result = applied(ListMove.move(.down, in: text, selection: caret(1)), to: text)
        equal(result?.0, "1. b\n2. a\n    1. a1\n    2. a2", "outer renumbered, inner untouched")
    }

    // MARK: - Selections

    suite("a selection across two items moves both as one block") {
        let text = "- a\n- b\n- c\n- d"
        let selection = NSRange(location: 6, length: 5)  // "b\n- c"
        let result = applied(ListMove.move(.up, in: text, selection: selection), to: text)
        equal(result?.0, "- b\n- c\n- a\n- d", "b and c went above a together")
        equal(result.map { ($0.0 as NSString).substring(with: $0.1) }, "b\n- c", "selection still covers the same text")
    }

    suite("a whole-line selection keeps its newline and nothing more") {
        let text = "- a\n- b\n- c"
        let result = applied(ListMove.move(.up, in: text, selection: NSRange(location: 4, length: 4)), to: text)
        equal(result?.0, "- b\n- a\n- c", "moved")
        equal(result?.1, NSRange(location: 0, length: 4), "selection is '- b\\n'")
        let down = applied(ListMove.move(.down, in: text, selection: NSRange(location: 4, length: 4)), to: text)
        equal(down?.0, "- a\n- c\n- b", "moved down to the end")
        equal(down?.1, NSRange(location: 8, length: 3), "clamped to the text, no newline past the end")
    }

    suite("a selection reaching outside the list is not a list move") {
        let text = "prose\n- a\n- b"
        equal(ListMove.move(.down, in: text, selection: NSRange(location: 2, length: 8)), .notInList, "starts in prose")
    }

    // MARK: - Content kept intact

    suite("items holding images move intact") {
        let text = "- [ ] ![](Attachments/one.png)\n- [ ] text"
        let result = applied(ListMove.move(.up, in: text, selection: caret(location(of: "text", in: text))), to: text)
        equal(result?.0, "- [ ] text\n- [ ] ![](Attachments/one.png)", "the image reference moved whole")
    }

    suite("a trailing newline and the text around the list are untouched") {
        let text = "Title\n- a\n- b\n\nafter\n"
        guard case .moved(let edit) = ListMove.move(.up, in: text, selection: caret(location(of: "b", in: text))) else {
            check(false, "should move"); return
        }
        equal(applied(edit, to: text), "Title\n- b\n- a\n\nafter\n", "only the two lines changed")
        equal(edit.range, NSRange(location: 6, length: 7), "the edit covers just the swapped lines")
    }

    suite("bullets and checkboxes at one level are siblings") {
        let text = "- [ ] task\n- note"
        equal(applied(ListMove.move(.up, in: text, selection: caret(13)), to: text)?.0, "- note\n- [ ] task", "mixed markers swap")
    }

    // MARK: - Drag

    suite("the drag context lists siblings and their drop slots") {
        let text = "- a\n    - a1\n- b\n- c"
        let context = ListMove.dragContext(in: text, itemAt: 0)
        equal(context?.itemIndex, 0, "dragging the first item")
        equal(context?.itemRanges, [NSRange(location: 0, length: 12), NSRange(location: 13, length: 3), NSRange(location: 17, length: 3)], "a's block includes a1")
        equal(context?.slotLocations, [0, 13, 17, 20], "a slot before each sibling and one after the last")
        check(context?.isNoOp(slot: 0) == true && context?.isNoOp(slot: 1) == true, "slots either side of the item do nothing")
        equal(ListMove.dragContext(in: "prose", itemAt: 1), nil, "prose is not draggable")
    }

    suite("dropping an item into a slot moves it there") {
        let text = "1. a\n2. b\n3. c"
        equal(applied(ListMove.move(in: text, itemAt: 0, toSlot: 3, selection: caret(0)), to: text), "1. b\n2. c\n3. a", "a to the end, renumbered")
        equal(applied(ListMove.move(in: text, itemAt: 11, toSlot: 0, selection: caret(0)), to: text), "1. c\n2. a\n3. b", "c to the top")
        equal(ListMove.move(in: text, itemAt: 5, toSlot: 1, selection: caret(0)), nil, "dropping in place is no edit")
        equal(ListMove.move(in: text, itemAt: 5, toSlot: 2, selection: caret(0)), nil, "nor just below itself")
    }

    suite("the nearest slot follows the pointer") {
        let ys: [CGFloat] = [0, 20, 40, 60]
        equal(ChecklistTextView.nearestSlot(toY: -30, slotYs: ys), 0, "above everything")
        equal(ChecklistTextView.nearestSlot(toY: 29, slotYs: ys), 1, "closer to 20")
        equal(ChecklistTextView.nearestSlot(toY: 31, slotYs: ys), 2, "closer to 40")
        equal(ChecklistTextView.nearestSlot(toY: 500, slotYs: ys), 3, "below everything")
    }

    suite("a click is not a drag until the pointer travels past the threshold") {
        let start = NSPoint(x: 10, y: 10)
        check(!ChecklistTextView.isListDrag(from: start, to: NSPoint(x: 11, y: 12)), "a hand's wobble is a click")
        check(!ChecklistTextView.isListDrag(from: start, to: NSPoint(x: 12, y: 10)), "two points sideways is a click")
        check(ChecklistTextView.isListDrag(from: start, to: NSPoint(x: 10, y: 14)), "four points down is a drag")
        check(ChecklistTextView.isListDrag(from: start, to: NSPoint(x: 10, y: 6)), "four points up is a drag")
    }

    // MARK: - View wiring

    suite("Ctrl-Cmd-Down in a list moves the item instead of the note") {
        let view = makeTextView("- a\n- b")
        view.setSelectedRange(caret(2))
        var handled = false
        let movedNote = posts(.jotRequestMoveNoteDown) { handled = chord(view, kVK_DownArrow) }
        check(handled, "handled")
        check(!movedNote, "the note did not move")
        equal(view.string, "- b\n- a", "the item moved")
        equal(view.selectedRange(), caret(6), "caret followed the item")
    }

    suite("Ctrl-Cmd-Up outside a list is not claimed, and never moves the note") {
        // Moving the note is Option-Cmd-Up/Down; Ctrl-Cmd belongs to list items.
        let view = makeTextView("prose\n- a")
        view.setSelectedRange(caret(1))
        var handled = false
        let movedNote = posts(.jotRequestMoveNoteUp) { handled = chord(view, kVK_UpArrow) }
        check(!handled && !movedNote, "passes through untouched")
        equal(view.string, "prose\n- a", "text untouched")
    }

    suite("Ctrl-Cmd-Up at the top of a list beeps and does nothing else") {
        let view = makeTextView("- a\n- b")
        view.setSelectedRange(caret(1))
        var beeps = 0
        view.beep = { beeps += 1 }
        var handled = false
        let movedNote = posts(.jotRequestMoveNoteUp) { handled = chord(view, kVK_UpArrow) }
        check(handled, "claimed, so the note does not move under the user")
        check(!movedNote, "no note move")
        equal(beeps, 1, "one beep")
        equal(view.string, "- a\n- b", "unchanged")
    }

    suite("Ctrl-Cmd-Up with Caps Lock on still moves the item") {
        let view = makeTextView("- a\n- b")
        view.setSelectedRange(caret(5))
        check(chord(view, kVK_UpArrow, [.command, .control, .capsLock, .numericPad, .function]), "handled")
        equal(view.string, "- b\n- a", "moved")
    }

    suite("a list move inside a code block falls through") {
        let view = makeTextView("code\n- a\n- b")
        view.codeKeyword = "code"
        view.setSelectedRange(caret(11))
        var handled = false
        let movedNote = posts(.jotRequestMoveNoteUp) { handled = chord(view, kVK_UpArrow) }
        check(!handled && !movedNote, "code is not a list: nothing moves")
        equal(view.string, "code\n- a\n- b", "untouched")
    }

    suite("one list move is one undo step") {
        let view = makeTextView("1. a\n2. b\n3. c")
        let provider = ListUndoProvider()
        view.delegate = provider
        view.allowsUndo = true
        view.setSelectedRange(caret(11))

        provider.manager.beginUndoGrouping()
        _ = chord(view, kVK_UpArrow)
        provider.manager.endUndoGrouping()
        equal(view.string, "1. a\n2. c\n3. b", "moved and renumbered")
        equal(provider.manager.undoActionName, "Move Item", "named for the Edit menu")

        provider.manager.undo()
        equal(view.string, "1. a\n2. b\n3. c", "a single undo restores the list")
        check(!provider.manager.canUndo, "nothing else to undo")
        view.delegate = nil
    }

    suite("the markers that can be dragged are hit, the text is not") {
        let view = makeTextView("- [ ] task\n- bullet\n1. number\nprose")
        let check1 = view.listMarkerHit(at: markerCenter(NSRange(location: 0, length: 5), in: view))
        equal(check1?.isCheckbox, true, "the checkbox")
        equal(check1?.lineLocation, 0, "on the first line")
        let bullet = view.listMarkerHit(at: markerCenter(NSRange(location: 11, length: 1), in: view))
        equal(bullet?.isCheckbox, false, "the bullet")
        equal(bullet?.lineLocation, 11, "second line")
        let number = view.listMarkerHit(at: markerCenter(NSRange(location: 20, length: 2), in: view))
        equal(number?.lineLocation, 20, "the number")
        equal(view.listMarkerHit(at: markerCenter(NSRange(location: 15, length: 3), in: view)), nil, "bullet text")
        equal(view.listMarkerHit(at: markerCenter(NSRange(location: 31, length: 3), in: view)), nil, "prose")
    }

    suite("releasing a checkbox without dragging still toggles it") {
        let view = makeTextView("- [ ] task\n- [ ] other")
        guard let hit = view.listMarkerHit(at: markerCenter(NSRange(location: 0, length: 5), in: view)) else {
            check(false, "the checkbox should be hit"); return
        }
        view.finishListMarkerClick(hit, at: markerCenter(NSRange(location: 0, length: 5), in: view))
        equal(view.string, "- [x] task\n- [ ] other", "toggled")
    }

    suite("dropping a dragged item applies one undoable move") {
        let view = makeTextView("- [ ] a\n- [ ] b\n- [ ] c")
        let provider = ListUndoProvider()
        view.delegate = provider
        view.allowsUndo = true
        view.setSelectedRange(caret(3))

        provider.manager.beginUndoGrouping()
        let moved = view.dropListItem(lineLocation: 0, toSlot: 3)
        provider.manager.endUndoGrouping()
        check(moved, "the drop changed the text")
        equal(view.string, "- [ ] b\n- [ ] c\n- [ ] a", "a went to the end")
        equal(view.selectedRange(), caret(19), "the caret came with it")
        provider.manager.undo()
        equal(view.string, "- [ ] a\n- [ ] b\n- [ ] c", "one undo puts it back")
        check(!view.dropListItem(lineLocation: 0, toSlot: 1), "a drop in place is no edit")
        view.delegate = nil
    }

    suite("drop slots sit at the top of each sibling and the foot of the last") {
        let view = makeTextView("- a\n- b\n- c")
        guard let context = ListMove.dragContext(in: view.string, itemAt: 0) else {
            check(false, "context"); return
        }
        let ys = view.listDropSlotYs(for: context)
        equal(ys.count, 4, "four slots")
        check(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 }, "top to bottom")
    }
}
