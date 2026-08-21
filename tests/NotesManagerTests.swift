import Foundation

// A dependency-free harness. The logic under test (NotesManager, NoteStore) is
// deliberately free of SwiftUI, so it compiles into a plain executable with
// swiftc — no Xcode project or SwiftPM manifest required.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)  (\(file):\(line))")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if actual == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
        print("         expected: \(expected)")
        print("         actual:   \(actual)")
    }
}

func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

/// Fresh manager over a throwaway file, with legacy migration disabled so the
/// user's real notes are never touched by a test run.
func makeManager(seed: [String]? = nil) -> NotesManager {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stickynotes-tests-\(UUID().uuidString)")
        .appendingPathComponent("notes.json")
    let store = NoteStore(fileURL: url, allowsLegacyMigration: false)
    if let seed { store.save(seed) }
    return NotesManager(store: store, saveDebounce: 0)
}

func runAllTests() {
    // MARK: - Timer parsing

    suite("timer directive parsing") {
        equal(NotesManager.firstTimerDirective(in: "5m timer")?.duration, 300, "minutes")
        equal(NotesManager.firstTimerDirective(in: "30s timer")?.duration, 30, "seconds")
        equal(NotesManager.firstTimerDirective(in: "2h timer")?.duration, 7200, "hours")
        equal(NotesManager.firstTimerDirective(in: "5M TIMER")?.duration, 300, "case-insensitive")
        equal(NotesManager.firstTimerDirective(in: "buy milk")?.duration, nil, "no directive")
        equal(NotesManager.firstTimerDirective(in: "notes\n10m timer\nmore")?.source, "10m timer", "found mid-note")
    }

    // MARK: - Timer lifecycle

    suite("expired timer does not resurrect itself") {
        let m = makeManager()
        m.currentText = "5m timer"
        check(m.activeTimerEnd != nil, "timer starts when the directive is typed")

        m.timerDidFire()
        check(m.activeTimerEnd == nil, "timer clears when it fires")

        m.currentText = "5m timer and then some more typing"
        check(m.activeTimerEnd == nil, "further edits do not restart the fired timer")

        m.currentText = "7m timer"
        check(m.activeTimerEnd != nil, "a genuinely new directive does start a timer")
    }

    suite("timer does not leak across notes") {
        let m = makeManager()
        m.currentText = "5m timer"
        check(m.activeTimerEnd != nil, "timer running on note 1")

        m.addNewNote()
        check(m.activeTimerEnd == nil, "switching to a new note clears the overlay")

        m.previousNote()
        check(m.activeTimerEnd == nil, "returning to note 1 does not auto-restart it")
    }

    suite("removing the directive cancels the timer") {
        let m = makeManager()
        m.currentText = "5m timer"
        check(m.activeTimerEnd != nil, "running")
        m.currentText = "no directive here"
        check(m.activeTimerEnd == nil, "cancelled")
    }

    // MARK: - Empty-note purging

    suite("blank notes are purged on navigation") {
        let m = makeManager(seed: ["first", "   ", "third"])
        equal(m.notes.count, 3, "seeded with a blank in the middle")

        m.currentIndex = 2
        m.previousNote()

        check(!m.notes.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              "blank note removed")
        equal(m.notes, ["first", "third"], "surviving notes intact")
    }

    suite("the note you are editing is never purged") {
        let m = makeManager(seed: ["first", "second"])
        m.currentIndex = 1
        m.currentText = ""
        m.previousNote()
        equal(m.notes.count, 2, "current note survives even while blank")
    }

    suite("addNewNote refuses to stack blanks") {
        let m = makeManager()
        m.currentText = "something"
        m.addNewNote()
        equal(m.notes.count, 2, "first blank added")
        m.addNewNote()
        equal(m.notes.count, 2, "second call is a no-op on a blank note")
    }

    // MARK: - Checklists

    suite("checklist toggles the line under the caret") {
        let m = makeManager()
        m.currentText = "[ ] alpha\n[ ] bravo\n[ ] charlie"

        // Caret on line 2 ("bravo" starts at index 10).
        m.toggleChecklist(atCharacterIndex: 12)
        equal(m.currentText, "[ ] alpha\n[x] bravo\n[ ] charlie", "second line checked, others untouched")

        // The old implementation could never uncheck anything but the first item.
        m.toggleChecklist(atCharacterIndex: 12)
        equal(m.currentText, "[ ] alpha\n[ ] bravo\n[ ] charlie", "same line unchecks again")
    }

    suite("checklist adds a checkbox to a plain line") {
        let m = makeManager()
        m.currentText = "buy milk"
        m.toggleChecklist(atCharacterIndex: 3)
        equal(m.currentText, "[ ] buy milk", "checkbox introduced")
    }

    suite("checklist preserves indentation") {
        let m = makeManager()
        m.currentText = "    nested item"
        m.toggleChecklist(atCharacterIndex: 6)
        equal(m.currentText, "    [ ] nested item", "indent kept ahead of the checkbox")
    }

    // MARK: - Configurable timer keyword

    suite("timer keyword is configurable") {
        equal(NotesManager.firstTimerDirective(in: "5m pomodoro", keyword: "pomodoro")?.duration, 300,
              "custom keyword matches")
        equal(NotesManager.firstTimerDirective(in: "5m timer", keyword: "pomodoro")?.duration, nil,
              "default keyword no longer matches once changed")

        let m = makeManager()
        m.timerKeyword = "countdown"
        m.currentText = "10m countdown"
        check(m.activeTimerEnd != nil, "manager honours its keyword")
    }

    suite("an empty keyword falls back rather than matching everything") {
        equal(NotesManager.firstTimerDirective(in: "5m timer", keyword: "   ")?.duration, 300,
              "blank keyword falls back to 'timer'")
    }

    suite("regex-special keywords are escaped") {
        // An unescaped "c++" would be an invalid pattern and match nothing.
        equal(NotesManager.firstTimerDirective(in: "5m c++", keyword: "c++")?.duration, 300,
              "keyword with regex metacharacters still matches literally")
    }

    suite("changing the keyword re-evaluates the current note") {
        let m = makeManager()
        m.currentText = "5m timer"
        check(m.activeTimerEnd != nil, "running under the old keyword")
        m.timerKeywordDidChange(to: "pomodoro")
        check(m.activeTimerEnd == nil, "stale directive no longer keeps a timer alive")
    }

    // MARK: - Text statistics

    suite("word, character, and line counts") {
        let stats = TextStatistics.of("hello world\nsecond line")
        equal(stats.words, 4, "words")
        equal(stats.characters, 23, "characters")
        equal(stats.lines, 2, "lines")

        equal(TextStatistics.of("").words, 0, "empty has no words")
        equal(TextStatistics.of("").lines, 1, "empty is still one line")
        equal(TextStatistics.of("one\n").lines, 1, "a trailing newline does not open a new line")
        equal(TextStatistics.of("  spaced   out  ").words, 2, "runs of whitespace are one separator")
        equal(TextStatistics.of("café").characters, 4, "accented characters count once")
    }

    suite("footer label pluralises") {
        equal(TextStatistics.of("word").summary, "1 word · 4 chars · 1 line", "singular")
        equal(TextStatistics.of("two words").summary, "2 words · 9 chars · 1 line", "plural words")
        equal(TextStatistics.of("a\nb").summary, "2 words · 3 chars · 2 lines", "plural lines")
    }

    // MARK: - Selection maths

    suite("sum and average over a selection") {
        let math = SelectionMath.of("10 20 30")
        equal(math?.count, 3, "three numbers")
        equal(math?.sum, 60, "sum")
        equal(math?.average, 20, "average")
    }

    suite("numbers are parsed out of surrounding text") {
        let math = SelectionMath.of("rent $1,240.50 and food $310.25")
        equal(math?.count, 2, "currency symbols and separators do not break parsing")
        equal(math?.sum, 1550.75, "thousands separator handled")
    }

    suite("negatives and decimals") {
        let math = SelectionMath.of("-5 2.5")
        equal(math?.sum, -2.5, "negative plus decimal")
    }

    suite("a selection worth no summary returns nil") {
        equal(SelectionMath.of("no numbers here") == nil, true, "no numbers")
        equal(SelectionMath.of("just 42") == nil, true, "one number has no meaningful average")
    }

    // MARK: - Key combos

    suite("key combo display and validation") {
        equal(KeyCombo.default.displayString, "\u{2325}A", "default renders as option-A")
        check(KeyCombo.default.isValid, "default is valid")
        check(!KeyCombo(keyCode: 0, carbonModifiers: 0).isValid,
              "a bare key is rejected, since it would swallow ordinary typing")
    }

    // MARK: - Storage

    suite("notes survive a store round trip") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-roundtrip-\(UUID().uuidString)")
            .appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)

        store.save(["alpha", "bravo"])
        equal(store.load(), ["alpha", "bravo"], "round trip")

        store.save([])
        equal(store.load(), [""], "empty input never yields an unaddressable array")
    }

    suite("loading takes a backup of what was already on disk") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-backup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)

        store.save(["important"])
        _ = store.load()
        check(FileManager.default.fileExists(atPath: store.backupFileURL.path), "backup written")

        // Simulate the clobber that cost a note during development.
        store.save([""])
        equal(store.load(), [""], "live file is now empty")

        let recovered = try? JSONDecoder().decode([String].self, from: Data(contentsOf: store.backupFileURL))
        equal(recovered, ["important"], "backup still holds the real content")
    }

    suite("a blank document never overwrites a good backup") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-backup2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)

        store.save(["keep me"])
        _ = store.load()
        store.save([""])
        _ = store.load()
        _ = store.load()

        let recovered = try? JSONDecoder().decode([String].self, from: Data(contentsOf: store.backupFileURL))
        equal(recovered, ["keep me"], "repeated loads of an empty file leave the backup alone")
    }

    suite("a missing file yields one empty note") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-missing-\(UUID().uuidString)")
            .appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)
        equal(store.load(), [""], "safe default")
    }

    suite("corrupt file does not crash or lose the shape") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-corrupt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.json")
        try? Data("{ not json".utf8).write(to: url)

        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)
        equal(store.load(), [""], "falls back cleanly")
    }
}
