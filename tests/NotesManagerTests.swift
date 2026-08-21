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
