import AppKit

/// One Edit › Undo over two stacks: the editor's typing and the notes list.
///
/// They can't share one `UndoManager`. The editor's stack is cleared every
/// time the note on screen changes (`ChecklistTextView.loadNoteText`), because
/// its actions are recorded against that note's ranges, and deleting a note
/// changes the note on screen. A delete registered there would be wiped the
/// moment it happened. So `NotesManager` keeps its own stack, and the panel
/// asks this router which one an Undo or Redo means.
///
/// The rule: whichever stack acted last goes first. "Acted" covers a new
/// action, an undo and a redo; each manager announces all three through its
/// notifications, so the router only listens and never has to be told.
/// In the single-note modes the two can't actually interleave (a delete always
/// empties the typing stack), so this mostly matters in Screen Edge mode,
/// where one card's typing and another card's deletion share a window.
@MainActor
final class UndoRouter {
    enum Stack: Equatable {
        case text
        case notes
    }

    enum Direction {
        case undo
        case redo
    }

    let notes: UndoManager
    private(set) var notesActionIsNewest = false
    /// Called whenever the notes stack acts. The panel uses it to break the
    /// editor's typing coalescing, so typing after a delete starts a new
    /// undo step (and a new group, which is what tells this router about it)
    /// instead of quietly extending the run from before the delete.
    var onNotesAction: (() -> Void)?

    private weak var text: UndoManager?
    private var notesTokens: [NSObjectProtocol] = []
    private var textTokens: [NSObjectProtocol] = []

    private static let activity: [Notification.Name] = [
        .NSUndoManagerDidCloseUndoGroup,
        .NSUndoManagerDidUndoChange,
        .NSUndoManagerDidRedoChange,
    ]

    init(notes: UndoManager) {
        self.notes = notes
        notesTokens = Self.activity.map { name in
            NotificationCenter.default.addObserver(forName: name, object: notes, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.notesActionIsNewest = true
                    self?.onNotesAction?()
                }
            }
        }
    }

    deinit {
        for token in notesTokens + textTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// The editor's stack: the panel's own undo manager, which every text
    /// view in it uses. Idempotent, so it can be called on every validation.
    func observeText(_ manager: UndoManager?) {
        guard manager !== text else { return }
        textTokens.forEach(NotificationCenter.default.removeObserver)
        text = manager
        guard let manager else {
            textTokens = []
            return
        }
        textTokens = Self.activity.map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.notesActionIsNewest = false }
            }
        }
    }

    /// The pure rule, so it can be read in one place and tested on its own.
    nonisolated static func stack(for direction: Direction, textCan: Bool, notesCan: Bool, notesIsNewest: Bool) -> Stack? {
        switch (textCan, notesCan) {
        case (true, true): return notesIsNewest ? .notes : .text
        case (true, false): return .text
        case (false, true): return .notes
        case (false, false): return nil
        }
    }

    /// The manager an Undo or Redo should go to right now, or nil when
    /// there is nothing to do (the menu item is then disabled).
    func manager(for direction: Direction, text: UndoManager?) -> UndoManager? {
        observeText(text)
        let textCan = direction == .undo ? (text?.canUndo ?? false) : (text?.canRedo ?? false)
        let notesCan = direction == .undo ? notes.canUndo : notes.canRedo
        switch Self.stack(for: direction, textCan: textCan, notesCan: notesCan, notesIsNewest: notesActionIsNewest) {
        case .text: return text
        case .notes: return notes
        case nil: return nil
        }
    }
}
