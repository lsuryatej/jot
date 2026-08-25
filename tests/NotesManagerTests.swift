import Foundation
import AppKit
import Combine

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
    if let seed { store.save(seed.map { Note(text: $0) }) }
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

    suite("a running timer survives switching notes, and does not auto-restart on return") {
        let m = makeManager()
        m.currentText = "5m timer"
        let owner = m.notes[m.currentIndex].id
        check(m.activeTimerEnd != nil, "timer running on note 1")
        equal(m.activeTimerOwnerID, owner, "note 1 owns it")

        m.addNewNote()
        check(m.activeTimerEnd != nil, "switching to a new, unrelated note leaves it running")
        equal(m.activeTimerOwnerID, owner, "still owned by note 1, not the new note")

        m.previousNote()
        check(m.activeTimerEnd != nil, "returning to note 1 finds it still running")
        equal(m.activeTimerOwnerID, owner, "ownership unchanged by the round trip")
    }

    suite("editing a different note while a timer runs elsewhere does not touch it") {
        let m = makeManager()
        m.currentText = "5m timer"
        let owner = m.notes[m.currentIndex].id
        check(m.activeTimerEnd != nil, "timer running on note 1")
        let endDate = m.activeTimerEnd

        m.addNewNote()
        m.currentText = "second note, now with more text"
        equal(m.activeTimerEnd, endDate, "unrelated typing in another note leaves the running countdown untouched")
        equal(m.activeTimerOwnerID, owner, "ownership is still note 1's")
    }

    suite("switching to a note with an old, never-started directive does not spontaneously start it") {
        // Simulates a directive typed in a previous session: present in the
        // seed data from the very first load, never freshly typed this run.
        let m = makeManager(seed: ["5m timer", "plain"])
        m.currentIndex = 1
        check(m.activeTimerEnd == nil, "landing elsewhere first: nothing has started yet")

        m.currentIndex = 0
        check(m.activeTimerEnd == nil, "merely looking at the note with the directive does not start it")

        m.currentText = "5m timer, with an unrelated edit appended"
        check(m.activeTimerEnd == nil, "editing around the *same* directive text still does not start it")
    }

    suite("a fresh directive in a different note silently replaces a running timer") {
        let m = makeManager()
        m.currentText = "5m timer"
        check(m.activeTimerEnd != nil, "timer running on note 1")
        let firstOwner = m.activeTimerOwnerID

        m.addNewNote()
        m.currentText = "10m timer"
        let secondOwner = m.notes[m.currentIndex].id
        equal(m.activeTimerOwnerID, secondOwner, "the newest directive wins the one countdown slot")
        check(m.activeTimerOwnerID != firstOwner, "no longer note 1's")
    }

    suite("deleting the note that owns a running timer cancels it") {
        let m = makeManager()
        m.currentText = "5m timer"
        m.addNewNote()  // a second note, so deleting the first is a real removal
        check(m.activeTimerEnd != nil, "timer running on note 1")

        m.deleteNote(at: 0)
        check(m.activeTimerEnd == nil, "no note left to point back to, so it's cancelled outright")
        check(m.activeTimerOwnerID == nil, "ownership cleared too")
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

        check(!m.notes.contains(where: { $0.isBlank }),
              "blank note removed")
        equal(m.texts, ["first", "third"], "surviving notes intact")
    }

    suite("the note you are editing is never purged") {
        let m = makeManager(seed: ["first", "second"])
        m.currentIndex = 1
        m.currentText = ""
        m.previousNote()
        equal(m.notes.count, 2, "current note survives even while blank")
    }

    // MARK: - Reordering

    suite("moving a note reorders the list") {
        let m = makeManager(seed: ["one", "two", "three"])
        m.moveNote(from: 2, to: 0)
        equal(m.texts, ["three", "one", "two"], "last note lands at the top")

        let n = makeManager(seed: ["one", "two", "three"])
        n.moveNote(from: 0, to: 3)
        equal(n.texts, ["two", "three", "one"], "first note lands at the bottom")

        let o = makeManager(seed: ["a", "b", "c", "d"])
        o.moveNote(from: 1, to: 3)
        equal(o.texts, ["a", "c", "b", "d"], "a note lands before whatever it was dropped onto")
    }

    suite("the two no-op slots leave everything alone") {
        // Under the onMove convention, dropping onto yourself or just below
        // yourself changes nothing — both must be caught before the array is
        // touched, so no save fires and no view animates.
        let m = makeManager(seed: ["one", "two", "three"])
        m.moveNote(from: 1, to: 1)
        m.moveNote(from: 1, to: 2)
        equal(m.texts, ["one", "two", "three"], "order unchanged")
    }

    suite("out-of-range moves are refused, not crashed into") {
        let m = makeManager(seed: ["one", "two"])
        m.moveNote(from: -1, to: 0)
        m.moveNote(from: 5, to: 0)
        m.moveNote(from: 0, to: -3)
        m.moveNote(from: 0, to: 99)
        equal(m.texts, ["one", "two"], "every bad move left the list untouched")
    }

    suite("reordering keeps the user on the same note") {
        // currentIndex starts on the last seeded note.
        let m = makeManager(seed: ["one", "two", "three"])
        let followedID = m.notes[m.currentIndex].id

        m.moveNote(from: 0, to: 3)
        equal(m.texts[m.currentIndex], "three", "notes moving past it do not drag the caret along")
        equal(m.notes[m.currentIndex].id, followedID, "identity, not coincidence of position")

        let n = makeManager(seed: ["one", "two", "three"])
        n.moveNote(from: 2, to: 0)
        equal(n.texts[n.currentIndex], "three", "moving the current note itself keeps it current")
    }

    suite("moving does not purge blank notes") {
        // Purging belongs to navigation. A drag that quietly deleted the blank
        // note two slots over would be a surprise nobody asked for.
        let m = makeManager(seed: ["one", "", "", "four"])
        m.moveNote(from: 3, to: 0)
        equal(m.notes.count, 4, "count unchanged by a move")
    }

    suite("a running timer keeps running while its note moves") {
        // Navigation deliberately clears the timer (covered above); a move is
        // not navigation, so it must not touch the countdown either way.
        let m = makeManager(seed: ["first", "second"])
        m.currentText = "5m timer"
        check(m.activeTimerEnd != nil, "timer started")

        // Moving the very note the timer belongs to, without navigating.
        m.moveNote(from: 1, to: 0)
        check(m.activeTimerEnd != nil, "still running after its note moved up the list")
        equal(m.texts[m.currentIndex], "5m timer", "and the user stayed on it")
    }

    suite("moveCurrentNote walks one slot at a time and clamps") {
        // Seeded managers start on the last note.
        let m = makeManager(seed: ["a", "b", "c"])
        m.moveCurrentNote(by: -1)
        equal(m.texts, ["a", "c", "b"], "up means toward index 0")

        m.moveCurrentNote(by: +1)
        equal(m.texts, ["a", "b", "c"], "back down again")

        m.moveCurrentNote(by: +5)
        equal(m.texts, ["a", "b", "c"], "already at the bottom, clamped")

        m.moveCurrentNote(by: -9)
        equal(m.texts, ["c", "a", "b"], "clamped at the top from wherever it was")

        let single = makeManager()
        single.moveCurrentNote(by: -1)
        single.moveCurrentNote(by: +1)
        equal(single.notes.count, 1, "a lone note has nowhere to go")
    }

    suite("a reordered list survives persistence") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-reorder-\(UUID().uuidString)")
            .appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)
        let m = NotesManager(store: store, saveDebounce: 0)
        m.appendNote()
        m.appendNote()
        m.appendNote()
        for (i, text) in ["one", "two", "three", "four"].enumerated() { m.setText(text, at: i) }

        m.moveNote(from: 3, to: 0)
        m.flush()

        let reloaded = NoteStore(fileURL: url, allowsLegacyMigration: false).load()
        equal(reloaded.map(\.text), ["four", "one", "two", "three"], "new order is what reaches disk")
        equal(Set(reloaded.map(\.id)), Set(m.notes.map(\.id)), "identities are untouched by a move")
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

    // MARK: - Pomodoro

    suite("pomodoro directive parsing") {
        let d = NotesManager.firstPomodoroDirective(in: "pomodoro 25/5")
        equal(d?.workDuration, 1500, "25 minutes of work")
        equal(d?.breakDuration, 300, "5 minutes of break")
        equal(d?.source, "pomodoro 25/5", "the exact matched text")

        equal(NotesManager.firstPomodoroDirective(in: "POMODORO 60/10")?.workDuration, 3600, "case-insensitive")
        equal(NotesManager.firstPomodoroDirective(in: "buy milk")?.workDuration, nil, "no directive")
        equal(
            NotesManager.firstPomodoroDirective(in: "notes\npomodoro 45/15\nmore")?.source,
            "pomodoro 45/15",
            "found mid-note"
        )
    }

    suite("a pomodoro cycle starts in the work phase and alternates when it fires") {
        let m = makeManager()
        m.currentText = "pomodoro 25/5"
        check(m.activeTimerEnd != nil, "the cycle starts")
        equal(m.activePomodoroPhase, .work, "work comes first")

        m.timerDidFire()
        check(m.activeTimerEnd != nil, "firing does not stop the cycle")
        equal(m.activePomodoroPhase, .rest, "work flips to break")

        m.timerDidFire()
        equal(m.activePomodoroPhase, .work, "break flips back to work")
    }

    suite("a fired phase starts the next one at the directive's own duration") {
        let m = makeManager()
        m.currentText = "pomodoro 25/5"
        let workEnd = m.activeTimerEnd!
        m.timerDidFire()
        let breakEnd = m.activeTimerEnd!

        // Work is 1500s, break is 300s — the break phase should end roughly
        // 1200s sooner than the work phase would have from the same start.
        let workRemaining = workEnd.timeIntervalSinceNow
        let breakRemaining = breakEnd.timeIntervalSinceNow
        check(abs((workRemaining - breakRemaining) - 1200) < 2, "break is the shorter half of this cycle")
    }

    suite("a plain timer directive is ignored while a pomodoro directive owns the note") {
        let m = makeManager()
        m.currentText = "pomodoro 25/5 and also 5m timer"
        equal(m.activePomodoroPhase, .work, "pomodoro wins the note's one countdown slot")
    }

    suite("removing the pomodoro directive cancels the cycle") {
        let m = makeManager()
        m.currentText = "pomodoro 25/5"
        check(m.activePomodoroPhase != nil, "running")
        m.currentText = "no directive here"
        check(m.activeTimerEnd == nil, "cancelled")
        check(m.activePomodoroPhase == nil, "phase cleared too")
    }

    suite("a pomodoro cycle survives switching notes, and does not auto-restart on return") {
        let m = makeManager()
        m.currentText = "pomodoro 25/5"
        let owner = m.notes[m.currentIndex].id
        check(m.activePomodoroPhase != nil, "running on note 1")

        m.addNewNote()
        check(m.activeTimerEnd != nil, "switching to a new, unrelated note leaves it running")
        check(m.activePomodoroPhase != nil, "phase label survives too")
        equal(m.activeTimerOwnerID, owner, "still owned by note 1")

        m.previousNote()
        check(m.activeTimerEnd != nil, "returning to note 1 finds the cycle still running")
        equal(m.activeTimerOwnerID, owner, "ownership unchanged by the round trip")
    }

    suite("a fresh pomodoro directive in a different note silently replaces a running cycle") {
        let m = makeManager()
        m.currentText = "pomodoro 25/5"
        let firstOwner = m.activeTimerOwnerID
        check(m.activePomodoroPhase != nil, "running on note 1")

        m.addNewNote()
        m.currentText = "pomodoro 50/10"
        let secondOwner = m.notes[m.currentIndex].id
        equal(m.activeTimerOwnerID, secondOwner, "the newest directive wins the one countdown slot")
        check(m.activeTimerOwnerID != firstOwner, "no longer note 1's")
        equal(m.activePomodoroPhase, .work, "the new cycle starts at work")
    }

    suite("pomodoro keyword is configurable") {
        equal(NotesManager.firstPomodoroDirective(in: "focus 25/5", keyword: "focus")?.workDuration, 1500,
              "custom keyword matches")
        equal(NotesManager.firstPomodoroDirective(in: "pomodoro 25/5", keyword: "focus")?.workDuration, nil,
              "default keyword no longer matches once changed")

        let m = makeManager()
        m.pomodoroKeyword = "focus"
        m.currentText = "focus 50/10"
        check(m.activePomodoroPhase != nil, "manager honours its keyword")
    }

    suite("changing the pomodoro keyword re-evaluates the current note") {
        let m = makeManager()
        m.currentText = "pomodoro 25/5"
        check(m.activePomodoroPhase != nil, "running under the old keyword")
        m.pomodoroKeywordDidChange(to: "focus")
        check(m.activeTimerEnd == nil, "stale directive no longer keeps a cycle alive")
        check(m.activePomodoroPhase == nil, "phase cleared too")
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

    // MARK: - Checklists

    suite("lenient parsing, strict output") {
        equal(Checklist.item(in: "- [ ] task")?.isChecked, false, "markdown unchecked")
        equal(Checklist.item(in: "- [x] task")?.isChecked, true, "markdown checked")
        equal(Checklist.item(in: "- [X] task")?.isChecked, true, "uppercase X")
        equal(Checklist.item(in: "* [ ] task")?.body, "task", "asterisk bullet")
        equal(Checklist.item(in: "+ [ ] task")?.body, "task", "plus bullet")
        // Notes written by earlier versions must keep working without migration.
        equal(Checklist.item(in: "[ ] legacy")?.body, "legacy", "bare bracket form still parses")
        equal(Checklist.item(in: "    - [ ] nested")?.indent, "    ", "indent captured")
        check(Checklist.item(in: "not a task") == nil, "plain line is not an item")
        check(Checklist.item(in: "") == nil, "empty line is not an item")
    }

    suite("legacy markers are rewritten to markdown on toggle") {
        equal(Checklist.toggled(block: "[ ] legacy"), "- [x] legacy", "bare bracket becomes a markdown task")
    }

    suite("toggling a single line") {
        equal(Checklist.toggled(block: "- [ ] task"), "- [x] task", "check")
        equal(Checklist.toggled(block: "- [x] task"), "- [ ] task", "uncheck")
        equal(Checklist.toggled(block: "buy milk"), "- [ ] buy milk", "plain line becomes an item")
        equal(Checklist.toggled(block: "    buy milk"), "    - [ ] buy milk", "indent preserved")
    }

    suite("toggling a multi-line selection") {
        // The old implementation only ever touched one line.
        equal(Checklist.toggled(block: "- [ ] a\n- [ ] b"), "- [x] a\n- [x] b", "all unchecked become checked")
        equal(Checklist.toggled(block: "- [x] a\n- [x] b"), "- [ ] a\n- [ ] b", "all checked become unchecked")
        equal(Checklist.toggled(block: "- [x] a\n- [ ] b"), "- [x] a\n- [x] b", "mixed resolves to checked")
        equal(Checklist.toggled(block: "a\n- [x] b"), "- [ ] a\n- [x] b", "a non-item makes everything an item first")
    }

    suite("toggling skips blank lines") {
        equal(Checklist.toggled(block: "a\n\nb"), "- [ ] a\n\n- [ ] b",
              "paragraph breaks do not collect empty checkboxes")
        equal(Checklist.toggled(block: ""), "- [ ] ", "an empty line starts a list")
    }

    suite("toggling preserves a trailing newline") {
        equal(Checklist.toggled(block: "- [ ] a\n"), "- [x] a\n", "line ending kept")
    }

    suite("Return continues the list") {
        equal(Checklist.newline(inLine: "- [ ] task"), .continueList("\n- [ ] "), "new item")
        equal(Checklist.newline(inLine: "    - [x] task"), .continueList("\n    - [ ] "),
              "continues unchecked at the same indent")
        check(Checklist.newline(inLine: "plain text") == nil, "ordinary line gets an ordinary newline")
    }

    suite("Return on an empty item leaves the list") {
        equal(Checklist.newline(inLine: "- [ ] "), .exitList(""), "empty item is cleared")
        equal(Checklist.newline(inLine: "    - [ ]"), .exitList(""), "nested empty item too")
    }

    suite("nesting") {
        equal(Checklist.indented(block: "- [ ] a", by: 1), "    - [ ] a", "indent one level")
        equal(Checklist.indented(block: "    - [ ] a", by: -1), "- [ ] a", "outdent one level")
        equal(Checklist.indented(block: "- [ ] a", by: -1), nil, "outdenting at column zero does nothing")
        equal(Checklist.indented(block: "plain", by: 1), nil, "Tab keeps its ordinary meaning outside a list")
        equal(Checklist.indented(block: "- [ ] a\n- [x] b", by: 1), "    - [ ] a\n    - [x] b", "whole selection")
    }

    suite("marker range covers the clickable box") {
        let item = Checklist.item(in: "  - [x] task")
        equal(item?.markerRange.location, 2, "starts after the indent")
        equal(item?.markerRange.length, 5, "covers exactly \"- [x]\"")
    }

    suite("notes files written before identities still load") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-legacyshape-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.json")
        // The pre-identity on-disk shape: a bare array of strings.
        try? Data("[\"first\",\"second\"]".utf8).write(to: url)

        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)
        let loaded = store.load()
        equal(loaded.map(\.text), ["first", "second"], "text survives the format change")
        equal(loaded.count, Set(loaded.map(\.id)).count, "each note gets a distinct identity")
    }

    suite("identities survive a round trip") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-ids-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = NoteStore(fileURL: dir.appendingPathComponent("notes.json"), allowsLegacyMigration: false)

        let original = [Note(text: "alpha"), Note(text: "bravo")]
        store.save(original)
        equal(store.load().map(\.id), original.map(\.id), "ids are stable across save and load")
    }

    suite("note titles") {
        equal(Note(text: "Groceries\nmilk").title, "Groceries", "first line")
        equal(Note(text: "\n\n  Real title\nbody").title, "Real title", "leading blank lines skipped")
        equal(Note(text: "   ").title, "Untitled note", "blank note has a fallback title")
    }

    // MARK: - Typography

    suite("every curated font resolves at the requested size") {
        for name in NoteFont.all {
            let font = NoteFont.resolved(name, size: 13)
            check(font.pointSize == 13, "\(name) resolves")
        }
    }

    suite("an unknown stored font name degrades to the default, not nil") {
        let unknown = NoteFont.resolved("No Such Font", size: 15)
        let fallback = NoteFont.resolved(NoteFont.defaultName, size: 15)
        equal(unknown.fontName, fallback.fontName, "same family as the default")
        equal(unknown.pointSize, fallback.pointSize, "size preserved through the fallback")
    }

    suite("opaque papers bring their own ink") {
        // The whole point of an opaque paper: system label colors follow
        // macOS's mode, not the paper, so a dark-mode user on Cream would be
        // reading white-on-cream without this rule.
        for appearance in Appearance.allCases where appearance.paperColor != nil {
            check(appearance.ink.text != NSColor.labelColor,
                  "\(appearance.title) does not inherit the system label color")
        }
    }

    suite("translucent appearances follow the system palette") {
        for appearance in Appearance.allCases where appearance.paperColor == nil {
            equal(appearance.ink, InkTheme.system, "\(appearance.title) uses system ink")
            check(appearance.materialRawValue == 6 || appearance.materialRawValue == 12 || appearance.materialRawValue == 13,
                  "\(appearance.title) maps to a real material")
        }
    }

    suite("chrome and cards separate from their own paper") {
        // Shipped once with the chrome strip painted in the paper's own color:
        // a cream header on cream paper, invisible. Tone has to move for
        // every opaque surface, in both directions the paper allows.
        for appearance in Appearance.allCases where appearance.paperColor != nil {
            check(appearance.chromeColor != appearance.paperColor,
                  "\(appearance.title) header strip is not the paper color")
            check(appearance.cardColor != appearance.paperColor,
                  "\(appearance.title) cards are not the paper color")
        }
    }

    suite("paper guide round-trips through its persisted form") {
        for guide in PaperGuide.allCases {
            equal(PaperGuide(rawValue: guide.rawValue), guide, "\(guide.title) round-trips")
        }
    }

    /// Disposable defaults, so a test run never reads or writes the user's
    /// real preferences.
    func makeSettings(seedSize: Double? = nil) -> SettingsManager {
        let name = "JotTests.settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        if let seedSize { defaults.set(seedSize, forKey: "noteFontSize") }
        return SettingsManager(defaults: defaults)
    }

    suite("a wild stored font size is clamped at init") {
        equal(makeSettings(seedSize: 200).noteFontSize, 24, "too large comes down")
        equal(makeSettings(seedSize: 2).noteFontSize, 11, "too small comes up")
        equal(makeSettings().noteFontSize, 13, "absent keeps the default")

        // The clamp has to live in init: property observers don't fire there,
        // so a didSet clamp never guarded the values that actually enter this
        // way — and assigning inside didSet re-fires the observer forever,
        // which hung the app whenever the size slider moved.
    }

    suite("changing the font size publishes once per change") {
        let settings = makeSettings()
        var publishes = 0
        let token = settings.objectWillChange.sink { _ in publishes += 1 }

        // A regression recurses synchronously inside didSet, so the assignment
        // runs where a hang becomes a failed check after five seconds rather
        // than a test binary stuck for good.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            settings.noteFontSize = 14
            done.signal()
        }
        equal(done.wait(timeout: .now() + 5), .success, "the assignment returns")
        token.cancel()
        equal(publishes, 1, "one publish, not a recursion")
    }

    suite("a bare keyword on the first line turns the note into a list") {
        check(Checklist.isListMode("list", keyword: "list"), "exactly the keyword")
        check(Checklist.isListMode("List\nmilk", keyword: "list"), "case-insensitive")
        check(Checklist.isListMode("  list  \nmilk", keyword: "list"), "surrounding space ignored")
        check(!Checklist.isListMode("listen to the podcast", keyword: "list"),
              "a word that merely starts with the keyword is an ordinary note")
        check(!Checklist.isListMode("groceries\nlist", keyword: "list"),
              "the keyword only counts on the first line")
        check(!Checklist.isListMode("", keyword: "list"), "empty note")
    }

    // MARK: - Headings

    suite("heading parsing takes one to three hashes and a space") {
        equal(Heading.parse("# Title"), Heading(level: 1, markerLength: 2), "level one")
        equal(Heading.parse("## Title"), Heading(level: 2, markerLength: 3), "level two")
        equal(Heading.parse("### Title"), Heading(level: 3, markerLength: 4), "level three")
        check(Heading.parse("#### Title") == nil, "four hashes has no level here")
        check(Heading.parse("#hashtag") == nil, "no space is ordinary text")
        check(Heading.parse("#") == nil, "a lone hash is ordinary text")
        check(Heading.parse("###") == nil, "hashes with no space are ordinary text")
        check(Heading.parse(" # Title") == nil, "leading whitespace disqualifies")
        check(Heading.parse("#NoSpace") == nil, "glued text disqualifies")
        check(Heading.parse("plain words") == nil, "prose is not a heading")
        check(Heading.parse("- [ ] # inside an item") == nil,
              "a hash mid-line means nothing to the heading parser")
    }

    suite("heading markers map into whole-string coordinates") {
        let ns = "# Top\nbody\n## Section" as NSString
        equal(
            Heading.markerRanges(in: ns),
            [NSRange(location: 0, length: 2), NSRange(location: 11, length: 3)],
            "both markers found at their lines"
        )
        equal(Heading.markerRanges(in: "no headings here" as NSString), [], "none in plain prose")
    }

    suite("headings never become list items") {
        equal(
            Checklist.convertedToList("list\n# Heading\nmilk", keyword: "list"),
            "list\n# Heading\n- [ ] milk",
            "conversion leaves them standing"
        )
        equal(
            Checklist.pastedAsListItems("eggs\n## From the web", into: "list\n- [ ] milk", keyword: "list"),
            "- [ ] eggs\n## From the web",
            "paste-splitting leaves them standing"
        )
        equal(Checklist.itemized(line: "# Heading"), "# Heading", "itemized passes a heading through")

        equal(
            Checklist.toggled(block: "# Roadmap\nship v2"),
            "# Roadmap\n- [ ] ship v2",
            "toggling a mixed selection skips the heading"
        )
        equal(
            Checklist.toggled(block: "# Roadmap\n## Later"),
            "# Roadmap\n## Later",
            "toggling a selection of only headings changes nothing"
        )
    }

    suite("a heading's text is the note's title") {
        equal(Note(text: "## Roadmap\nbody").title, "Roadmap", "hashes stripped from the title")
        // Not a heading by the parser's rule, so it titles literally — same
        // as any other punctuation-only first line.
        equal(Note(text: "#\nbody").title, "#", "a lone hash titles as itself")
        equal(Note(text: "plain first line").title, "plain first line", "ordinary notes unchanged")
    }

    suite("the list keyword still wins the first line over everything") {
        // The whole-line-exact match means markup never collides with it.
        check(!Checklist.isListMode("# list", keyword: "list"), "'# list' is a heading named list, not checklist mode")
        check(Checklist.isListMode("LIST", keyword: "list"), "bare keyword still triggers")
    }

    suite("switching to list mode converts what is already there") {
        equal(
            Checklist.convertedToList("list\nmilk\neggs", keyword: "list"),
            "list\n- [ ] milk\n- [ ] eggs",
            "plain lines become items"
        )
        equal(
            Checklist.convertedToList("list\n- [x] milk\neggs", keyword: "list"),
            "list\n- [x] milk\n- [ ] eggs",
            "existing items keep their state"
        )
        equal(
            Checklist.convertedToList("list\nmilk\n\neggs", keyword: "list"),
            "list\n- [ ] milk\n\n- [ ] eggs",
            "blank lines are left alone"
        )
        equal(
            Checklist.convertedToList("list\n    nested", keyword: "list"),
            "list\n    - [ ] nested",
            "indentation preserved"
        )
        equal(
            Checklist.convertedToList("groceries\nmilk", keyword: "list"),
            "groceries\nmilk",
            "a note not in list mode is untouched"
        )
    }

    suite("a multi-line paste into a list note becomes items") {
        equal(
            Checklist.pastedAsListItems("eggs\nmilk\nbread", into: "list", keyword: "list"),
            "- [ ] eggs\n- [ ] milk\n- [ ] bread",
            "each pasted line lands as its own unchecked item"
        )
        equal(
            Checklist.pastedAsListItems("eggs\nmilk", into: "groceries", keyword: "list"),
            nil,
            "an ordinary note takes the paste as-is"
        )
        equal(
            Checklist.pastedAsListItems("one line only", into: "list", keyword: "list"),
            nil,
            "a single-line paste is left to paste normally"
        )
        equal(
            Checklist.pastedAsListItems("- [x] done\nplain\n\nnext", into: "list", keyword: "list"),
            "- [x] done\n- [ ] plain\n\n- [ ] next",
            "lines that are already items keep their state and blanks survive as breaks"
        )
        equal(
            Checklist.pastedAsListItems("    sub\ntop", into: "list", keyword: "list"),
            "    - [ ] sub\n- [ ] top",
            "each line keeps its own indentation"
        )
        equal(
            Checklist.pastedAsListItems("eggs\n", into: "list", keyword: "list"),
            "- [ ] eggs\n",
            "a trailing newline is preserved"
        )
        equal(
            Checklist.pastedAsListItems("a\nb", into: "todo", keyword: "todo"),
            "- [ ] a\n- [ ] b",
            "the configured keyword counts, not just the default"
        )
    }

    // MARK: - Inline images

    suite("image references parse out of a line") {
        let refs = Checklist.item(in: "x") == nil
            ? Attachments.references(in: "before ![320](Attachments/a.png) after")
            : []
        equal(refs.count, 1, "one reference found")
        equal(refs.first?.path, "Attachments/a.png", "path")
        equal(refs.first?.width, 320, "width")
    }

    suite("a reference without a width means natural size") {
        let refs = Attachments.references(in: "![](Attachments/a.png)")
        equal(refs.first?.width, nil, "no width given")
        equal(refs.first?.path, "Attachments/a.png", "path still parsed")
    }

    suite("lines with no image yield nothing") {
        equal(Attachments.references(in: "just text").count, 0, "plain line")
        equal(Attachments.references(in: "[link](http://example.com)").count, 0,
              "an ordinary link is not an image")
    }

    suite("markdown round trips") {
        equal(Attachments.markdown(path: "Attachments/a.png", width: 240),
              "![240](Attachments/a.png)", "with width")
        equal(Attachments.markdown(path: "Attachments/a.png", width: nil),
              "![](Attachments/a.png)", "without width")
    }

    suite("resizing rewrites only the width") {
        let line = "![320](Attachments/a.png)"
        let resized = Attachments.settingWidth(180, on: line, at: NSRange(location: 0, length: (line as NSString).length))
        equal(resized, "![180](Attachments/a.png)", "width replaced, path intact")
    }

    suite("resizing has a floor") {
        let line = "![320](Attachments/a.png)"
        let resized = Attachments.settingWidth(4, on: line, at: NSRange(location: 0, length: (line as NSString).length))
        equal(resized, "![48](Attachments/a.png)", "cannot be dragged away to nothing")
    }

    // MARK: - Apple Notes sync

    suite("HTML escaping") {
        equal(AppleNotesSync.escape("a < b & c > d"), "a &lt; b &amp; c &gt; d", "angle brackets and ampersand")
        equal(AppleNotesSync.escape("say \"hi\""), "say &quot;hi&quot;", "quotes")
        // Ampersand has to be escaped first or the others get double-escaped.
        equal(AppleNotesSync.escape("&lt;"), "&amp;lt;", "an escape sequence in the source survives intact")
    }

    suite("note body becomes one div per line") {
        equal(AppleNotesSync.htmlBody(for: Note(text: "one\ntwo")),
              "<div>one</div><div>two</div>", "each line wrapped")
        equal(AppleNotesSync.htmlBody(for: Note(text: "a\n\nb")),
              "<div>a</div><div><br></div><div>b</div>", "blank lines survive as breaks")
    }

    suite("checklist markup survives the trip") {
        equal(AppleNotesSync.htmlBody(for: Note(text: "- [x] done")),
              "<div>- [x] done</div>", "brackets are not HTML and must not be mangled")
    }

    suite("AppleScript string literals are escaped") {
        equal(AppleNotesSync.appleScriptLiteral("plain"), "\"plain\"", "wrapped in quotes")
        equal(AppleNotesSync.appleScriptLiteral("say \"hi\""), "\"say \\\"hi\\\"\"", "embedded quotes escaped")
        // A stray backslash would otherwise start an escape sequence in the
        // generated script and break the whole sync.
        equal(AppleNotesSync.appleScriptLiteral("back\\slash"), "\"back\\\\slash\"", "backslashes escaped")
    }

    suite("script output is trimmed before it becomes a mapping key") {
        // osascript echoes a trailing newline. Storing it made every sync fail
        // its lookup and create a duplicate of the whole library.
        equal(AppleNotesSync.normalizeIdentifier("x-coredata://abc/ICNote/p1\n"),
              "x-coredata://abc/ICNote/p1", "trailing newline stripped")
        equal(AppleNotesSync.normalizeIdentifier("  padded  "), "padded", "surrounding space stripped")
        equal(AppleNotesSync.normalizeIdentifier("\n"), nil, "an empty result is not an identifier")
        equal(AppleNotesSync.normalizeIdentifier(""), nil, "neither is nothing at all")
    }

    // MARK: - Pasteboard

    suite("an image is detected even when a string rides along") {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StickyNotesTest-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()

        // Copying an image very often puts its filename or source URL on the
        // pasteboard too. Bailing out to plain-text paste whenever any string
        // was present is what stopped images pasting at all.
        pasteboard.writeObjects([image])
        pasteboard.setString("screenshot.png", forType: .string)

        check(TextRecognition.containsImage(pasteboard), "image wins over the incidental string")
        check(TextRecognition.image(from: pasteboard) != nil, "and the image can be read back")
    }

    suite("plain text is not mistaken for an image") {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StickyNotesTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("just some copied words", forType: .string)
        check(!TextRecognition.containsImage(pasteboard), "text pastes as text")
    }

    // MARK: - Math engine

    /// Evaluates one line in a fresh environment and returns the numeric
    /// result, or nil if the line does not evaluate (prose, or an error).
    func evalLine(_ line: String, env: inout [String: MathExpression.Value]) -> Double? {
        guard let node = MathExpression.parse(line) else { return nil }
        guard case .success(let value) = MathExpression.evaluate(node, environment: &env) else { return nil }
        return value.amount
    }

    func evalDoc(_ lines: [String]) -> [Double?] {
        var env: [String: MathExpression.Value] = [:]
        return lines.map { evalLine($0, env: &env) }
    }

    suite("prose does not evaluate") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("just some words", env: &env), nil, "no numbers at all")
        equal(evalLine("5 apples", env: &env), nil, "a bare number with a word is not math")
        equal(evalLine("1200", env: &env), nil, "a bare number alone is not math either")
        equal(evalLine("meeting at 3pm", env: &env), nil, "a number embedded in prose")
    }

    suite("basic arithmetic") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("2 + 2", env: &env), 4, "addition")
        equal(evalLine("10 - 3", env: &env), 7, "subtraction")
        equal(evalLine("4 * 5", env: &env), 20, "multiplication")
        equal(evalLine("10 / 4", env: &env), 2.5, "division")
        equal(evalLine("2 ^ 8", env: &env), 256, "exponent")
        equal(evalLine("(2 + 3) * 4", env: &env), 20, "parentheses")
        equal(evalLine("-5 + 10", env: &env), 5, "leading negative literal")
        equal(evalLine("10 - -5", env: &env), 15, "subtracting a negative")
        equal(evalLine("2 + 3 * 4", env: &env), 14, "precedence: multiplication before addition")
    }

    suite("thousands separators and decimals") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("1,200 + 800", env: &env), 2000, "comma-grouped thousands")
        equal(evalLine("1,234,567 + 1", env: &env), 1234568, "multiple groups")
        equal(evalLine("0.5 + 0.25", env: &env), 0.75, "decimals")
        equal(evalLine("$50 + $25", env: &env), 75, "dollar-prefixed numbers")
    }

    suite("percentages: of, plain add/subtract, on/off") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("20% of 50", env: &env), 10, "of")
        equal(evalLine("10 + 20%", env: &env), 12, "add: 20% of 10, added to 10")
        equal(evalLine("200 + 10%", env: &env), 220, "matches Soulver's documented example")
        equal(evalLine("100 - 50%", env: &env), 50, "subtract a percentage")
        equal(evalLine("10% on 200", env: &env), 220, "on: adds the percentage")
        equal(evalLine("20% off 50", env: &env), 40, "off: subtracts the percentage")
        equal(evalLine("50% * 30", env: &env), 15, "multiplying a percentage always yields a plain number")
        equal(evalLine("10% + 20%", env: &env), 30, "pure percentages add")
    }

    suite("variables") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("x = 40", env: &env), 40, "assignment evaluates to its value")
        equal(evalLine("x * 3", env: &env), 120, "later line references it")
        equal(evalLine("x", env: &env), 40, "a bare variable reference resolves")
        equal(evalLine("y = x + 10", env: &env), 50, "one variable used to define another")
        _ = evalLine("x = 5", env: &env)
        equal(evalLine("x * 2", env: &env), 10, "redefinition silently overrides for lines below it")
    }

    suite("an undefined variable does not evaluate") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("undefined_name * 2", env: &env), nil, "unknown identifier fails quietly")
    }

    suite("unit conversion") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("1 km to m", env: &env), 1000, "km to m")
        equal(evalLine("5 km in miles", env: &env).map { ($0 * 1000).rounded() / 1000 }, 3.107, "in, and miles conversion factor")
        equal(evalLine("100 cm as m", env: &env), 1, "as")
        equal(evalLine("0 c to f", env: &env), 32, "freezing point, celsius to fahrenheit")
        equal(evalLine("100 c to f", env: &env), 212, "boiling point")
        equal(evalLine("0 c to k", env: &env), 273.15, "celsius to kelvin")
    }

    suite("incompatible units do not evaluate") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("5 km + 3 kg", env: &env), nil, "length plus mass is refused rather than silently wrong")
    }

    suite("division by zero does not evaluate") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("5 / 0", env: &env), nil, "refused rather than infinity or a crash")
    }

    suite("a document evaluates top to bottom") {
        let results = evalDoc(["budget = 5000", "budget * 1.2", "10 + 5", "just some notes"])
        equal(results, [5000, 6000, 15, nil], "each line in order, prose lines nil")
    }

    suite("currency conversion resolves to a number") {
        var env: [String: MathExpression.Value] = [:]
        let result = evalLine("50 USD to EUR", env: &env)
        check(result != nil && result! > 0, "converts to a positive amount")
    }

    suite("mutation check: reintroducing the try?-flatten bug would fail here") {
        // Regression guard for the specific bug that made every dimensionless
        // calculation fail: Swift auto-flattens `try? throwingCall().get()`
        // when the success type is itself Optional, so a reconciled-but-nil
        // unit and an actual thrown error became indistinguishable.
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("2 + 2", env: &env), 4, "plain dimensionless addition must not hit the unit-mismatch path")
    }

    suite("prefix dollar sign attaches as a trailing unit, not a leading token") {
        // $50 must tokenize as (number 50, unit usd) — the same shape as
        // "50 usd" — or the parser's number-then-unit grammar cannot see it.
        let tokens = MathExpression.tokenize("$50")
        equal(tokens, [.number(50), .identifier("usd")], "number first, unit second")
    }

    suite("malformed grouping does not silently misparse") {
        var env: [String: MathExpression.Value] = [:]
        // "1,2345" is not valid thousands grouping (second group isn't three
        // digits) — the comma is dropped as punctuation and two separate
        // numbers remain with no operator between them, so the line is prose.
        equal(evalLine("1,2345", env: &env), nil, "invalid grouping does not produce a number")
    }

    suite("word wrapped as identifier is not mistaken for percent-of prose") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("weight of 50", env: &env), nil, "'of' with no leading percent is not math")
    }

    suite("case-insensitive variable names") {
        var env: [String: MathExpression.Value] = [:]
        _ = evalLine("Rate = 10", env: &env)
        equal(evalLine("rate * 2", env: &env), 20, "lookup is case-insensitive")
    }

    suite("negative percent") {
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine("100 - -10%", env: &env), 110, "subtracting a negative percentage adds")
    }

    suite("chained assignment references") {
        let results = evalDoc(["a = 10", "b = a * 2", "c = b + a", "c"])
        equal(results, [10, 20, 30, 30], "each variable available to every later line")
    }

    suite("deeply nested input is refused rather than crashing the process") {
        // A pasted line of thousands of open parens used to blow the stack
        // through unbounded recursive descent and kill the app outright. The
        // parser now stops descending past a fixed depth and the line simply
        // reads as prose.
        var env: [String: MathExpression.Value] = [:]
        equal(evalLine(String(repeating: "(", count: 4000), env: &env), nil, "4000 unclosed parens")
        equal(evalLine(String(repeating: "(", count: 4000) + "1 + 1" + String(repeating: ")", count: 4000), env: &env),
              nil, "4000 balanced parens around a real expression")
        // Unary minus recurses on itself the same way, so a long run of them
        // is the same crash by another route.
        equal(evalLine(String(repeating: "-", count: 4000) + "5", env: &env), nil, "4000 leading minus signs")
        // Two more productions recurse on themselves the same way: the
        // right-associative "^", and the target of a percent "of" phrase.
        equal(evalLine("2" + String(repeating: "^2", count: 4000), env: &env), nil, "4000 chained exponents")
        equal(evalLine(String(repeating: "100% of ", count: 4000) + "5", env: &env), nil, "4000 chained percent-of phrases")
        // Nesting a human would actually write still evaluates.
        equal(evalLine("((((((((((2 + 3))))))))))", env: &env), 5, "ten levels of real nesting still works")
    }

    suite("renaming the app moves the whole storage directory") {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-rename-\(UUID().uuidString)")
        let oldDir = base.appendingPathComponent("StickyNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: oldDir.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try? Data("[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"text\":\"kept\"}]".utf8)
            .write(to: oldDir.appendingPathComponent("notes.json"))
        try? "fake-image".data(using: .utf8)?.write(to: oldDir.appendingPathComponent("Attachments/a.png"))

        let moved = NoteStore.migrateStorageDirectoryIfNeeded(in: base)
        check(moved, "migration reports that it moved something")

        let newDir = base.appendingPathComponent("Jot", isDirectory: true)
        check(!FileManager.default.fileExists(atPath: oldDir.path), "old directory is gone, not copied-and-left-behind")
        check(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("notes.json").path), "notes moved")
        check(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("Attachments/a.png").path), "attachments moved with it")

        let ranAgain = NoteStore.migrateStorageDirectoryIfNeeded(in: base)
        check(!ranAgain, "does not run twice, and does not touch an already-migrated directory")
    }

    suite("no old directory means nothing to migrate") {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-nomigrate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        check(!NoteStore.migrateStorageDirectoryIfNeeded(in: base), "a fresh install has nothing to move")
    }

    suite("an existing Jot directory is never overwritten by a stale StickyNotes one") {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-nooverwrite-\(UUID().uuidString)")
        let oldDir = base.appendingPathComponent("StickyNotes", isDirectory: true)
        let newDir = base.appendingPathComponent("Jot", isDirectory: true)
        try? FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try? Data("[\"old\"]".utf8).write(to: oldDir.appendingPathComponent("notes.json"))
        try? Data("[\"current\"]".utf8).write(to: newDir.appendingPathComponent("notes.json"))

        check(!NoteStore.migrateStorageDirectoryIfNeeded(in: base), "refuses to run when the destination already exists")
        let survived = try? String(contentsOf: newDir.appendingPathComponent("notes.json"), encoding: .utf8)
        equal(survived, "[\"current\"]", "the real directory's content is untouched")
    }

    suite("Apple Notes sync embeds images as base64") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-notesync-img-\(UUID().uuidString)")
        let attachDir = dir.appendingPathComponent("Attachments")
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]) // PNG-ish bytes, contents don't matter here
        try? imageData.write(to: attachDir.appendingPathComponent("a.png"))

        let note = Note(text: "before text\n![240](Attachments/a.png)\nafter text")
        let html = AppleNotesSync.htmlBody(for: note, attachmentsBase: dir)

        check(html.contains("<img src=\"data:image/png;base64,"), "image line becomes a base64 <img> tag")
        check(html.contains(imageData.base64EncodedString()), "the actual image bytes are embedded")
        check(!html.contains("Attachments/a.png"), "the markdown path itself does not leak into the synced body")
        check(html.contains("<div>before text</div>"), "surrounding text lines are untouched")
        check(html.contains("<div>after text</div>"), "including the line after the image")
    }

    suite("a missing attachment file falls back to escaped text rather than dropping the line") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-notesync-missing-\(UUID().uuidString)")
        let note = Note(text: "![240](Attachments/does-not-exist.png)")
        let html = AppleNotesSync.htmlBody(for: note, attachmentsBase: dir)
        check(!html.contains("<img"), "no <img> tag when the file can't be read")
        check(html.contains("Attachments"), "the markdown reference is preserved as text instead of vanishing")
    }

    suite("a line mixing text and an image reference is not embedded as an image") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-notesync-mixed-\(UUID().uuidString)")
        let attachDir = dir.appendingPathComponent("Attachments")
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)
        try? Data([1,2,3]).write(to: attachDir.appendingPathComponent("a.png"))

        let note = Note(text: "see this: ![240](Attachments/a.png)")
        let html = AppleNotesSync.htmlBody(for: note, attachmentsBase: dir)
        check(!html.contains("<img"), "not embedded, since the editor never produces this shape")
        check(html.contains("see this"), "text is preserved rather than silently discarded")
    }

    // MARK: - Storage

    suite("notes survive a store round trip") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-roundtrip-\(UUID().uuidString)")
            .appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)

        store.save([Note(text: "alpha"), Note(text: "bravo")])
        equal(store.load().map(\.text), ["alpha", "bravo"], "round trip")

        store.save([])
        equal(store.load().map(\.text), [""], "empty input never yields an unaddressable array")
    }

    suite("loading takes a backup of what was already on disk") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-backup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)

        store.save([Note(text: "important")])
        _ = store.load()
        check(FileManager.default.fileExists(atPath: store.backupFileURL.path), "backup written")

        // Simulate the clobber that cost a note during development.
        store.save([Note()])
        equal(store.load().map(\.text), [""], "live file is now empty")

        let recovered = (try? JSONDecoder().decode([Note].self, from: Data(contentsOf: store.backupFileURL)))?.map(\.text)
        equal(recovered, ["important"], "backup still holds the real content")
    }

    suite("a blank document never overwrites a good backup") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-backup2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)

        store.save([Note(text: "keep me")])
        _ = store.load()
        store.save([Note()])
        _ = store.load()
        _ = store.load()

        let recovered = (try? JSONDecoder().decode([Note].self, from: Data(contentsOf: store.backupFileURL)))?.map(\.text)
        equal(recovered, ["keep me"], "repeated loads of an empty file leave the backup alone")
    }

    suite("a missing file yields one empty note") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-missing-\(UUID().uuidString)")
            .appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)
        equal(store.load().map(\.text), [""], "safe default")
    }

    suite("corrupt file does not crash or lose the shape") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stickynotes-corrupt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.json")
        try? Data("{ not json".utf8).write(to: url)

        let store = NoteStore(fileURL: url, allowsLegacyMigration: false)
        equal(store.load().map(\.text), [""], "falls back cleanly")
    }

    // MARK: - Global search

    suite("global search finds matches across every note") {
        let notes = [
            Note(text: "Trip to Goa\nbudget = 45000"),
            Note(text: "grocery list\neggs\nmilk"),
            Note(text: "budget for the server upgrade\nnew_ssd = 145 usd to inr")
        ]

        let hits = GlobalSearch.find("budget", in: notes)
        equal(hits.map(\.noteIndex), [0, 2], "matches in note 0 and note 2, not note 1")
        equal(hits.map(\.lineNumber), [2, 1], "line number within each note")
        equal(hits.first?.snippet, "budget = 45000", "snippet is the whole matching line, trimmed")

        equal(GlobalSearch.find("BUDGET", in: notes).count, 2, "case-insensitive")
        equal(GlobalSearch.find("", in: notes), [], "empty query returns nothing")
        equal(GlobalSearch.find("   ", in: notes), [], "whitespace-only query returns nothing")
        equal(GlobalSearch.find("nonexistent", in: notes), [], "no matches, no results")
    }

    suite("global search finds every occurrence within one note, not just the first") {
        let notes = [Note(text: "cat\ndog\ncat\ncat")]
        let hits = GlobalSearch.find("cat", in: notes)
        equal(hits.map(\.lineNumber), [1, 3, 4], "all three lines, in order")
    }

    suite("global search match range points at the exact substring") {
        let notes = [Note(text: "line one\nfind THIS word\nline three")]
        let hits = GlobalSearch.find("this", in: notes)
        check(hits.count == 1, "one match")
        if let hit = hits.first {
            let ns = notes[0].text as NSString
            equal(ns.substring(with: hit.matchRange), "THIS", "range covers the actual cased text, not the lowercase query")
        }
    }

    suite("global search result count is capped") {
        let longNote = Note(text: Array(repeating: "e", count: GlobalSearch.resultLimit + 50).joined(separator: "\n"))
        let hits = GlobalSearch.find("e", in: [longNote])
        equal(hits.count, GlobalSearch.resultLimit, "stops at the cap instead of scanning the whole thing")
    }

    // MARK: - Link shrink

    suite("a long URL is collapsed to its bare domain") {
        let text = "check this: https://www.example.com/some/very/long/path?query=1 thanks"
        let matches = LinkShrink.matches(in: text)
        check(matches.count == 1, "one link found")
        if let match = matches.first {
            let ns = text as NSString
            equal(ns.substring(with: match.range), "https://www.example.com/some/very/long/path?query=1", "the whole URL")
            equal(ns.substring(with: match.displayRange), "example.com", "www. is stripped along with the scheme")
        }
    }

    suite("a short link is not worth collapsing") {
        equal(LinkShrink.matches(in: "see http://a.co for details").count, 0, "too little would be hidden")
    }

    suite("plain text with no URL yields nothing") {
        equal(LinkShrink.matches(in: "just some notes, nothing to see here").count, 0, "no links, no matches")
    }

    suite("a host with no www. prefix is shown as-is") {
        let text = "docs at https://developer.apple.com/documentation/appkit/nstextview"
        let matches = LinkShrink.matches(in: text)
        check(matches.count == 1, "one link found")
        if let match = matches.first {
            equal((text as NSString).substring(with: match.displayRange), "developer.apple.com", "no www. to strip, host shown whole")
        }
    }

    suite("multiple links in one note are all found") {
        let text = "https://www.example.com/one/two/three and https://www.another-example.org/four/five/six"
        equal(LinkShrink.matches(in: text).count, 2, "both links found")
    }
}
