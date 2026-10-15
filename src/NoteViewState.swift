import Foundation

/// Where a note was left: its selection and how far it was scrolled.
struct NoteViewState: Equatable {
    var selection: NSRange
    var scrollOrigin: CGPoint
}

/// Each note's `NoteViewState` for this session, so switching back to a note
/// puts the caret and the scroll where they were (design review H7).
///
/// Deliberately never persisted: a relaunch opens every note fresh, caret at
/// the end, which is where a quick note is most often continued. Owned by
/// `NotesManager` rather than the editor so it outlives the editor view,
/// which SwiftUI rebuilds when the display mode changes.
final class NoteViewStateStore {
    private var states: [UUID: NoteViewState] = [:]

    subscript(id: UUID) -> NoteViewState? {
        get { states[id] }
        set { states[id] = newValue }
    }

    func forget(_ id: UUID) {
        states[id] = nil
    }
}
