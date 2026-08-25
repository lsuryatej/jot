import AppKit
import Foundation

// Switching notes is done by assigning `textView.string = text` inside
// `updateNSView`, which swaps the document out from under the text view. The
// undo stack is not part of that swap: it still holds the typing actions
// recorded against the previous note's ranges. Pressing Cmd+Z right after a
// switch therefore replays note A's edit into note B's text storage, deleting
// characters from a note that was never edited, or throwing NSRangeException
// when note B is shorter than the offset the edit was recorded at. The
// debounced save then writes the damage to disk.
//
// This cannot be seen from the fast suite. It needs a real UndoManager, which
// a text view only gets from `NSTextViewDelegate.undoManager(for:)`, and real
// undo registration, which only happens for edits that go through the text
// view's own editing path rather than a direct `string` assignment. So the
// test supplies a delegate with an UndoManager, types through `insertText`,
// performs exactly the assignment `updateNSView` performs, and then undoes.

/// Minimal delegate whose only job is to hand the text view an UndoManager.
/// AppKit registers undo actions against whatever this returns, and returns
/// nil-by-default in a plain window like this one, so without it the text view
/// records nothing and the bug is invisible.
private final class UndoProvidingDelegate: NSObject, NSTextViewDelegate {
    let manager = UndoManager()

    func undoManager(for view: NSTextView) -> UndoManager? {
        manager
    }
}

@MainActor
private func makeUndoableTextView(_ text: String) -> (window: NSWindow, view: ChecklistTextView, delegate: UndoProvidingDelegate) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    view.baseFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.textStorage?.delegate = view
    view.allowsUndo = true
    let delegate = UndoProvidingDelegate()
    view.delegate = delegate
    view.string = text
    view.applyChecklistStyling()

    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    pump(0.6)
    window.makeFirstResponder(view)
    pump(0.2)
    return (window, view, delegate)
}

/// A note switch, driven through the same call `PlainTextEditor.updateNSView`
/// makes, so this exercises the shipped code rather than a paraphrase of it.
/// The guard is the `textView.string != text` condition from `updateNSView`.
@MainActor
private func switchNote(_ view: ChecklistTextView, to text: String) {
    guard view.string != text else { return }
    view.loadNoteText(text)
}

func runUndoAcrossNoteSwitchTests() {
    MainActor.assumeIsolated {
        suite("undo after a note switch leaves the newly opened note untouched") {
            let noteA = "A: "
            let noteB = "B: the quarterly plan, do not lose this text ever"
            let (window, view, delegate) = makeUndoableTextView(noteA)
            defer { window.close() }

            check(window.isKeyWindow, "text view's window is key")

            // Type into note A the way a person does, so AppKit registers a
            // real undo action against note A's ranges.
            view.setSelectedRange(NSRange(location: (noteA as NSString).length, length: 0))
            view.insertText("shopping", replacementRange: view.selectedRange())
            pump(0.1)
            equal(view.string, "A: shopping", "typing lands in note A")
            check(delegate.manager.canUndo, "the typing registered an undo action")

            switchNote(view, to: noteB)
            pump(0.1)
            equal(view.string, noteB, "the note switch swapped in note B")

            delegate.manager.undo()
            pump(0.1)

            equal(view.string, noteB, "undo after the switch does not touch note B's text")
            check(view.string.contains("do not lose this text ever"),
                  "note B's words survive an undo it never earned")
        }

        suite("undo after switching to a shorter note does not throw or truncate") {
            // The other face of the same bug: when the new note is shorter than
            // the offset the previous note's edit was recorded at, replaying
            // that edit raises NSRangeException out of the text storage rather
            // than quietly eating characters.
            let noteA = "A: a much longer note than the one being switched to"
            let noteB = "B"
            let (window, view, delegate) = makeUndoableTextView(noteA)
            defer { window.close() }

            view.setSelectedRange(NSRange(location: (noteA as NSString).length, length: 0))
            view.insertText(" plus a trailing edit", replacementRange: view.selectedRange())
            pump(0.1)
            check(delegate.manager.canUndo, "the typing registered an undo action")

            switchNote(view, to: noteB)
            pump(0.1)

            delegate.manager.undo()
            pump(0.1)

            equal(view.string, noteB, "undo leaves the short note exactly as it was")
        }
    }
}
