import AppKit
import Foundation

// Design review H7: switching notes reused the previous note's caret offset
// and left the scroll wherever the last note had it. Each note now gets back
// the selection and scroll it was left with this session; a note not opened
// yet this session opens at its end, scrolled so the caret shows. These drive
// `PlainTextEditor.showNote`, the call `updateNSView` makes on a switch, over
// a real scroll view and text view (no window, which a headless run lacks).

private func makeEditor() -> (NSScrollView, ChecklistTextView) {
    let scrollView = SwipeScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    scrollView.hasVerticalScroller = true
    scrollView.automaticallyAdjustsContentInsets = false
    let textView = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.baseFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textStorage?.delegate = textView
    scrollView.documentView = textView
    return (scrollView, textView)
}

private func longNote(_ tag: String, lines: Int = 120) -> String {
    (1...lines).map { "\(tag) line \($0)" }.joined(separator: "\n")
}

private func scrollY(_ scrollView: NSScrollView) -> CGFloat {
    scrollView.contentView.bounds.origin.y
}

/// Whether the caret's line sits inside the visible part of the document.
private func caretIsVisible(_ textView: ChecklistTextView) -> Bool {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else { return false }
    lm.ensureLayout(for: tc)
    let location = textView.selectedRange().location
    let length = (textView.string as NSString).length
    let rect: NSRect
    if location >= length, length > 0 {
        rect = lm.extraLineFragmentRect.isEmpty
            ? lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
            : lm.extraLineFragmentRect
    } else {
        rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: location), effectiveRange: nil)
    }
    let inView = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    return textView.visibleRect.insetBy(dx: 0, dy: -1).contains(NSPoint(x: textView.visibleRect.midX, y: inView.midY))
}

func runNoteViewStateTests() {

    suite("the view-state store keeps one entry per note, for the session only") {
        let store = NoteViewStateStore()
        let a = UUID(), b = UUID()
        store[a] = NoteViewState(selection: NSRange(location: 3, length: 2), scrollOrigin: CGPoint(x: 0, y: 40))
        equal(store[a]?.selection, NSRange(location: 3, length: 2), "stored")
        equal(store[b], nil, "another note has nothing yet")
        store.forget(a)
        equal(store[a], nil, "forgotten")

        let manager = makeManager(seed: ["one", "two"])
        check(manager.currentNoteID == manager.notes[manager.currentIndex].id, "the manager names the note on screen")
        manager.viewStates[manager.notes[1].id] = NoteViewState(selection: NSRange(location: 1, length: 0), scrollOrigin: .zero)
        equal(manager.viewStates[manager.notes[1].id]?.selection.location, 1, "and owns a store for the session")
    }

    suite("a note not opened yet this session opens at its end, caret in view") {
        let (scrollView, textView) = makeEditor()
        let store = NoteViewStateStore()
        let a = UUID()
        let text = longNote("A")
        PlainTextEditor.showNote(a, text: text, leaving: nil, in: textView, states: store)
        equal(textView.selectedRange(), NSRange(location: (text as NSString).length, length: 0), "caret at the end")
        check(scrollY(scrollView) > 0, "scrolled down to it")
        check(caretIsVisible(textView), "the caret is on screen")
    }

    suite("switching away and back restores the caret and the scroll") {
        let (scrollView, textView) = makeEditor()
        let store = NoteViewStateStore()
        let a = UUID(), b = UUID()
        let textA = longNote("A"), textB = longNote("B")

        PlainTextEditor.showNote(a, text: textA, leaving: nil, in: textView, states: store)
        textView.setSelectedRange(NSRange(location: 200, length: 5))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        PlainTextEditor.showNote(b, text: textB, leaving: a, in: textView, states: store)
        equal(textView.string, textB, "B is showing")
        equal(textView.selectedRange(), NSRange(location: (textB as NSString).length, length: 0),
              "B, never opened, starts at its end rather than at A's offset")

        textView.setSelectedRange(NSRange(location: 40, length: 0))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        PlainTextEditor.showNote(a, text: textA, leaving: b, in: textView, states: store)
        equal(textView.selectedRange(), NSRange(location: 200, length: 5), "A's selection is back")
        equal(scrollY(scrollView), 300, "A's scroll is back")

        PlainTextEditor.showNote(b, text: textB, leaving: a, in: textView, states: store)
        equal(textView.selectedRange(), NSRange(location: 40, length: 0), "B's caret is back")
        equal(scrollY(scrollView), 120, "B's scroll is back")
    }

    suite("a remembered spot past the end of a note that shrank is clamped") {
        let (scrollView, textView) = makeEditor()
        let store = NoteViewStateStore()
        let a = UUID()
        store[a] = NoteViewState(selection: NSRange(location: 5000, length: 10), scrollOrigin: CGPoint(x: 0, y: 99999))
        let text = longNote("A", lines: 30)
        PlainTextEditor.showNote(a, text: text, leaving: nil, in: textView, states: store)
        equal(textView.selectedRange(), NSRange(location: (text as NSString).length, length: 0), "selection clamped to the text")
        let maxY = textView.frame.height - scrollView.contentView.bounds.height
        check(scrollY(scrollView) <= maxY + 0.5 && scrollY(scrollView) >= 0, "scroll clamped to the document")
    }

    suite("a short note restores to the top without scrolling past it") {
        let (scrollView, textView) = makeEditor()
        let store = NoteViewStateStore()
        let a = UUID()
        store[a] = NoteViewState(selection: NSRange(location: 2, length: 0), scrollOrigin: CGPoint(x: 0, y: 500))
        PlainTextEditor.showNote(a, text: "short", leaving: nil, in: textView, states: store)
        equal(scrollY(scrollView), 0, "nothing to scroll")
        equal(textView.selectedRange(), NSRange(location: 2, length: 0), "caret restored")
    }

    suite("a search jump lands on the match, not the remembered spot") {
        let (scrollView, textView) = makeEditor()
        let store = NoteViewStateStore()
        let a = UUID(), b = UUID()
        let textA = longNote("A")
        store[a] = NoteViewState(selection: NSRange(location: 10, length: 0), scrollOrigin: .zero)
        PlainTextEditor.showNote(b, text: "b", leaving: nil, in: textView, states: store)

        PlainTextEditor.showNote(a, text: textA, leaving: b, in: textView, states: store)
        let match = (textA as NSString).range(of: "A line 100")
        PlainTextEditor.applyScrollTarget(match, in: textView)
        equal(textView.selectedRange(), match, "the match is selected")
        check(scrollY(scrollView) > 0, "scrolled to the match")
        check(caretIsVisible(textView), "the match is on screen")
    }

    suite("the same note changing underneath keeps the caret where it was") {
        let (_, textView) = makeEditor()
        let store = NoteViewStateStore()
        let a = UUID()
        PlainTextEditor.showNote(a, text: "hello world", leaving: nil, in: textView, states: store)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        PlainTextEditor.showNote(a, text: "hello world, again", leaving: a, in: textView, states: store)
        equal(textView.string, "hello world, again", "text updated")
        equal(textView.selectedRange(), NSRange(location: 3, length: 0), "caret untouched, not sent to the end")
    }

    suite("switching notes still drops the old note's undo history") {
        let (_, textView) = makeEditor()
        let manager = UndoManager()
        manager.groupsByEvent = false
        final class Provider: NSObject, NSTextViewDelegate {
            let manager: UndoManager
            init(_ manager: UndoManager) { self.manager = manager }
            func undoManager(for view: NSTextView) -> UndoManager? { manager }
        }
        let provider = Provider(manager)
        textView.delegate = provider
        textView.allowsUndo = true
        let store = NoteViewStateStore()
        let a = UUID(), b = UUID()
        PlainTextEditor.showNote(a, text: "a", leaving: nil, in: textView, states: store)
        manager.beginUndoGrouping()
        textView.insertText("x", replacementRange: NSRange(location: 1, length: 0))
        manager.endUndoGrouping()
        check(manager.canUndo, "typing registered")
        PlainTextEditor.showNote(b, text: "b", leaving: a, in: textView, states: store)
        check(!manager.canUndo, "undo stack cleared at the switch")
        textView.delegate = nil
    }
}
