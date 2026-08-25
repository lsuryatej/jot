import Foundation

// Coverage for per-note font/size: Note's own optional fields, NotesManager's
// accessors, and SettingsManager's precedence when resolving what to actually
// display.

func runPerNoteFontTests() {

    // MARK: - Note

    suite("a fresh note has no font override") {
        let note = Note()
        check(note.fontName == nil, "nil until explicitly set")
        check(note.fontSize == nil, "same for size")
    }

    suite("a note's font fields round-trip through Codable") {
        let note = Note(text: "hi", fontName: "Menlo", fontSize: 16)
        let data = try! JSONEncoder().encode(note)
        let decoded = try! JSONDecoder().decode(Note.self, from: data)
        equal(decoded.fontName, "Menlo", "font name survives encode/decode")
        equal(decoded.fontSize, 16, "font size survives encode/decode")
    }

    suite("a note file written before this feature existed still decodes") {
        // The exact shape NoteStore wrote before `fontName`/`fontSize` existed:
        // no such keys at all. Old files must not break on the next launch.
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","text":"old note"}]
        """.data(using: .utf8)!
        let notes = try! JSONDecoder().decode([Note].self, from: legacyJSON)
        equal(notes.count, 1, "the note itself decodes")
        check(notes[0].fontName == nil, "missing key decodes to nil, not a crash")
        check(notes[0].fontSize == nil, "same for size")
    }

    // MARK: - NotesManager

    suite("NotesManager's current-note font accessors read and write the right note") {
        let store = NoteStore(fileURL: tempNotesFileURL(), allowsLegacyMigration: false)
        let manager = NotesManager(store: store)
        manager.notes = [Note(text: "a"), Note(text: "b")]
        manager.currentIndex = 1

        check(manager.currentFontName == nil, "note b starts with no override")
        manager.currentFontName = "Monaco"
        manager.currentFontSize = 18
        equal(manager.notes[1].fontName, "Monaco", "written to the note at currentIndex")
        equal(manager.notes[1].fontSize, 18, "same for size")
        check(manager.notes[0].fontName == nil, "note a is untouched — this is the whole point of the feature")
    }

    suite("clearing the override goes back through nil, not a stale value") {
        let store = NoteStore(fileURL: tempNotesFileURL(), allowsLegacyMigration: false)
        let manager = NotesManager(store: store)
        manager.currentFontName = "Courier"
        manager.currentFontName = nil
        check(manager.currentFontName == nil, "reset actually clears it")
    }

    // MARK: - SettingsManager precedence

    suite("with no per-note override, the picked default wins") {
        let settings = SettingsManager(defaults: tempDefaults())
        settings.noteFontName = "Menlo"
        settings.noteFontSize = 15
        equal(settings.resolvedFontName(perNote: nil), "Menlo", "falls through to the default")
        equal(settings.resolvedFontSize(perNote: nil), 15, "same for size")
    }

    suite("a per-note override beats the picked default") {
        let settings = SettingsManager(defaults: tempDefaults())
        settings.noteFontName = "Menlo"
        settings.noteFontSize = 15
        equal(settings.resolvedFontName(perNote: "Monaco"), "Monaco", "the note's own choice wins")
        equal(settings.resolvedFontSize(perNote: 20), 20, "same for size")
    }

    suite("an active theme note still wins over a per-note override") {
        let settings = SettingsManager(defaults: tempDefaults())
        settings.noteFontName = "Menlo"
        settings.themeOverride = ThemeNote.Theme(fontName: "SF Pro", fontSize: 22)
        equal(settings.resolvedFontName(perNote: "Monaco"), "SF Pro",
              "a theme is a deliberate whole-app statement and still outranks a single note's own pick")
        equal(settings.resolvedFontSize(perNote: 20), 22, "same for size")
    }

    suite("resolvedEditorFont resolves both name and size together") {
        let settings = SettingsManager(defaults: tempDefaults())
        settings.noteFontName = "Menlo"
        settings.noteFontSize = 15
        let font = settings.resolvedEditorFont(perNoteName: "Monaco", perNoteSize: 20)
        equal(font.pointSize, 20, "the resolved size lands on the actual NSFont")
    }
}

private func tempNotesFileURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("jot-test-\(UUID().uuidString).json")
}

private func tempDefaults() -> UserDefaults {
    let suite = "jot-test-\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}
