import AppKit

// Deleting a note is undoable (design review H2): the note comes back at its
// old position with the same id and content, and becomes the note on screen.
// The undo lives on NotesManager's own stack, which UndoRouter interleaves
// with the text view's typing stack behind one Edit > Undo.

func runDeleteNoteUndoTests() {
    MainActor.assumeIsolated { deleteNoteUndoSuites() }
}

@MainActor
private func deleteNoteUndoSuites() {

    suite("undoing a delete puts the note back where it was, same id and content") {
        let manager = makeManager(seed: ["A", "B", "C"])
        manager.currentIndex = 1
        manager.notes[1].fontName = "Menlo"
        manager.notes[1].fontSize = 18
        manager.notes[1].cardHeight = 120
        let original = manager.notes[1]

        manager.deleteNote(at: 1)
        equal(manager.texts, ["A", "C"], "B is gone")
        equal(manager.currentText, "C", "the next note is on screen")
        check(manager.noteUndoManager.canUndo, "the delete is undoable")
        equal(manager.noteUndoManager.undoActionName, "Delete Note", "named for the Edit menu")

        manager.noteUndoManager.undo()
        equal(manager.texts, ["A", "B", "C"], "B is back in its old slot")
        equal(manager.notes[1], original, "with its id, text, font, size and card height")
        equal(manager.currentIndex, 1, "and it is the note on screen, so the undo is visible")
    }

    suite("redo deletes it again, and undo/redo keep alternating") {
        let manager = makeManager(seed: ["A", "B", "C"])
        manager.currentIndex = 2
        manager.deleteNote(at: 2)
        equal(manager.currentText, "B", "deleting the last note falls back to the previous one")
        manager.noteUndoManager.undo()
        equal(manager.texts, ["A", "B", "C"], "undo restores C")
        check(manager.noteUndoManager.canRedo, "redo is offered")
        equal(manager.noteUndoManager.redoActionName, "Delete Note", "named Redo Delete Note")
        manager.noteUndoManager.redo()
        equal(manager.texts, ["A", "B"], "redo deletes C again")
        manager.noteUndoManager.undo()
        equal(manager.texts, ["A", "B", "C"], "and undo brings it back again")
        equal(manager.currentText, "C", "on screen")
    }

    suite("redo deletes the restored note even after the list shifted") {
        // CodeRabbit on #20: redo used the restored note's index, so a note
        // added in front between undo and redo made it delete a neighbour.
        let manager = makeManager(seed: ["A", "B", "C"])
        manager.currentIndex = 1
        manager.deleteNote(at: 1)
        manager.noteUndoManager.undo()
        equal(manager.texts, ["A", "B", "C"], "B restored")
        manager.notes.insert(Note(text: "Z"), at: 0)
        manager.noteUndoManager.redo()
        equal(manager.texts, ["Z", "A", "C"], "redo removed B, not whatever now sits at B's old index")
    }

    suite("a cleared only-note with only whitespace typed in is not overwritten by undo") {
        let manager = makeManager(seed: ["keep me"])
        manager.deleteNote(at: 0)
        manager.notes[0].text = "   "
        manager.noteUndoManager.undo()
        check(manager.texts.contains("   ") && manager.texts.contains("keep me"),
              "both survive: the typed whitespace and the restored text (\(manager.texts))")
    }

    suite("several deletes undo in reverse order") {
        let manager = makeManager(seed: ["A", "B", "C", "D"])
        manager.deleteNote(at: 0)
        manager.deleteNote(at: 1)
        equal(manager.texts, ["B", "D"], "A then C deleted")
        manager.noteUndoManager.undo()
        equal(manager.texts, ["B", "C", "D"], "first undo restores C")
        manager.noteUndoManager.undo()
        equal(manager.texts, ["A", "B", "C", "D"], "second restores A")
        check(!manager.noteUndoManager.canUndo, "nothing left to undo")
    }

    suite("a restore whose old slot no longer exists lands at the end") {
        let manager = makeManager(seed: ["A", "B", "C"])
        manager.deleteNote(at: 2)
        // Something else shortened the list meanwhile, with no undo of its own.
        manager.notes.removeFirst()
        manager.noteUndoManager.undo()
        equal(manager.texts, ["B", "C"], "C is appended rather than lost")
        equal(manager.currentText, "C", "and shown")
    }

    suite("deleting the only note leaves an empty note, and undo brings the text back") {
        let manager = makeManager(seed: ["only"])
        let id = manager.notes[0].id
        manager.deleteNote(at: 0)
        equal(manager.texts, [""], "one empty note left")
        manager.noteUndoManager.undo()
        equal(manager.texts, ["only"], "the text is back")
        equal(manager.notes[0].id, id, "in the same note")
    }

    suite("undo never overwrites what was written into the cleared only-note") {
        let manager = makeManager(seed: ["old"])
        manager.deleteNote(at: 0)
        manager.currentText = "new"
        manager.noteUndoManager.undo()
        equal(manager.texts.sorted(), ["new", "old"], "both survive")
        equal(manager.currentText, "old", "the restored one is shown")
        equal(Set(manager.notes.map(\.id)).count, 2, "as two distinct notes")
    }

    suite("an empty only-note has nothing to delete") {
        let manager = makeManager(seed: [""])
        check(!manager.canDeleteNote(at: 0), "Delete Note is disabled")
        manager.deleteNote(at: 0)
        check(!manager.noteUndoManager.canUndo, "and forcing it registers no empty undo")
        let two = makeManager(seed: ["", "B"])
        check(two.canDeleteNote(at: 0), "an empty note among others can go")
        check(!two.canDeleteNote(at: 5), "an index past the end can't")
    }

    suite("undoing a delete reschedules the note's pending reminders") {
        let scheduler = SpyReminderScheduler()
        let manager = makeManager(seed: ["A", "B"], reminderScheduler: scheduler)
        manager.currentIndex = 1
        manager.currentText = "B\nremind in 10 minutes"
        let first = scheduler.scheduled.first
        check(first != nil, "sanity: scheduled once")

        manager.deleteNote(at: 1)
        equal(scheduler.cancelled, first.map { [$0.identifier] } ?? [], "deleting cancelled it")

        manager.noteUndoManager.undo()
        equal(scheduler.scheduled.count, 2, "undo scheduled it again")
        equal(scheduler.scheduled.last?.identifier, first?.identifier, "under the same identifier")
        equal(scheduler.scheduled.last?.fireDate, first?.fireDate,
              "for the original moment, not ten minutes from the undo")

        // Editing the restored note afterwards must not schedule a duplicate.
        manager.currentText = "B edited\nremind in 10 minutes"
        equal(scheduler.scheduled.count, 2, "the restored reminder counts as already seen")
    }

    suite("undoing a delete does not restart a countdown") {
        let manager = makeManager(seed: ["A", "B"])
        manager.currentIndex = 1
        manager.currentText = "5m timer"
        check(manager.activeTimerEnd != nil, "sanity: B's timer runs")
        manager.deleteNote(at: 1)
        check(manager.activeTimerEnd == nil, "deleting B stopped it")
        manager.noteUndoManager.undo()
        check(manager.activeTimerEnd == nil, "restoring B does not start it from the top again")
        manager.currentText = "5m timer and more"
        check(manager.activeTimerEnd == nil, "nor does the next edit, since the directive was already seen")
    }

    // MARK: - Routing

    suite("UndoRouter: text first, unless a note action is newer") {
        typealias R = UndoRouter
        equal(R.stack(for: .undo, textCan: true, notesCan: true, notesIsNewest: false), .text, "typing after a delete undoes first")
        equal(R.stack(for: .undo, textCan: true, notesCan: true, notesIsNewest: true), .notes, "a delete after typing undoes first")
        equal(R.stack(for: .undo, textCan: false, notesCan: true, notesIsNewest: false), .notes, "falls through to notes")
        equal(R.stack(for: .undo, textCan: true, notesCan: false, notesIsNewest: true), .text, "falls through to text")
        equal(R.stack(for: .undo, textCan: false, notesCan: false, notesIsNewest: true), nil, "nothing to undo")
        equal(R.stack(for: .redo, textCan: true, notesCan: true, notesIsNewest: true), .notes, "redo mirrors undo")
        equal(R.stack(for: .redo, textCan: true, notesCan: true, notesIsNewest: false), .text, "both ways")
    }

    suite("UndoRouter: whichever stack acted last is the newest") {
        let text = UndoManager()
        text.groupsByEvent = false
        let notesManager = makeManager(seed: ["A", "B"])
        let router = UndoRouter(notes: notesManager.noteUndoManager)
        router.observeText(text)
        var notesActions = 0
        router.onNotesAction = { notesActions += 1 }

        /// A typing step whose undo registers its redo, like the real thing.
        @MainActor func register(on manager: UndoManager) {
            manager.registerUndo(withTarget: router) { _ in register(on: manager) }
        }
        @MainActor func type() {
            text.beginUndoGrouping()
            register(on: text)
            text.endUndoGrouping()
        }

        type()
        check(!router.notesActionIsNewest, "typing is newest")
        equal(router.manager(for: .undo, text: text), text, "so Undo means Undo Typing")

        notesManager.deleteNote(at: 0)
        check(router.notesActionIsNewest, "the delete is newest")
        equal(notesActions, 1, "and the router said so, so the editor can break typing coalescing")
        check(router.manager(for: .undo, text: text) === notesManager.noteUndoManager, "Undo means Undo Delete Note")

        router.manager(for: .undo, text: text)?.undo()
        equal(notesManager.texts, ["A", "B"], "the note came back")
        check(router.notesActionIsNewest, "an undo on the notes stack keeps it newest")
        check(router.manager(for: .redo, text: text) === notesManager.noteUndoManager, "so Redo is Redo Delete Note")

        type()
        check(!router.notesActionIsNewest, "typing again hands Undo back to the text")
        text.undo()
        check(!router.notesActionIsNewest, "a text undo keeps the text newest")
        check(router.manager(for: .redo, text: text) === text, "so Redo redoes the typing first")
        check(router.manager(for: .redo, text: nil) === notesManager.noteUndoManager,
              "with no text stack at all, the notes stack still answers")
    }
}
