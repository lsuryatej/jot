import Foundation

// Coverage for Screen Edge cards' resizable height: Note's own optional
// field, and NotesManager's indexed accessors. The drag/scroll mechanics
// themselves (NoteCard's resize handle, NoteCardEditor's NSScrollView) are
// SwiftUI/AppKit presentation and, like the rest of this app's rendering,
// are not covered here — geometry and persistence are.

func runResizableCardTests() {

    // MARK: - Note

    suite("a fresh note sizes to its content by default") {
        let note = Note()
        check(note.cardHeight == nil, "nil until the resize handle is dragged")
    }

    suite("a note's card height round-trips through Codable") {
        let note = Note(text: "hi", cardHeight: 220)
        let data = try! JSONEncoder().encode(note)
        let decoded = try! JSONDecoder().decode(Note.self, from: data)
        equal(decoded.cardHeight, 220, "survives encode/decode")
    }

    suite("a note file written before this feature existed still decodes") {
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","text":"old note"}]
        """.data(using: .utf8)!
        let notes = try! JSONDecoder().decode([Note].self, from: legacyJSON)
        equal(notes.count, 1, "the note itself decodes")
        check(notes[0].cardHeight == nil, "missing key decodes to nil, not a crash")
    }

    // MARK: - NotesManager

    suite("NotesManager's indexed card-height accessors read and write the right note") {
        let manager = makeManager(seed: ["a", "b"])
        check(manager.cardHeight(at: 1) == nil, "note b starts with no override")
        manager.setCardHeight(180, at: 1)
        equal(manager.cardHeight(at: 1), 180, "written to the note at that index")
        check(manager.cardHeight(at: 0) == nil, "note a is untouched")
    }

    suite("resetting to nil goes back to sizing to content, not a stale value") {
        let manager = makeManager(seed: ["a"])
        manager.setCardHeight(150, at: 0)
        manager.setCardHeight(nil, at: 0)
        check(manager.cardHeight(at: 0) == nil, "double-clicking the handle actually clears it")
    }

    suite("an out-of-range index is a no-op, not a crash") {
        let manager = makeManager(seed: ["a"])
        manager.setCardHeight(150, at: 5)
        check(manager.cardHeight(at: 5) == nil, "nothing to read back for an index that was never valid")
    }
}
