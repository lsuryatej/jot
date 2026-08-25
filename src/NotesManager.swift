import Foundation
import Combine

/// A timer directive found in note text, e.g. "5m timer".
struct TimerDirective: Equatable {
    /// The exact matched text. Used to tell "the user typed a new directive"
    /// apart from "the user edited some unrelated part of a note that happens
    /// to still contain the old directive".
    let source: String
    let duration: TimeInterval
}

/// A Pomodoro directive found in note text, e.g. "pomodoro 25/5" — work
/// minutes, then break minutes, separated by a slash.
struct PomodoroDirective: Equatable {
    let source: String
    let workDuration: TimeInterval
    let breakDuration: TimeInterval
}

/// Which half of a Pomodoro cycle is currently counting down.
enum PomodoroPhase: Equatable {
    case work
    case rest
}

final class NotesManager: ObservableObject {
    @Published var notes: [Note] = [Note()]

    /// Convenience for call sites that only care about the text.
    var texts: [String] { notes.map(\.text) }

    /// Seeds the newly-current note's directive tracking on every change,
    /// covering every way this can be reassigned — swipe/keyboard
    /// navigation, `addNewNote`, `deleteNote`, `moveNote`, and a direct jump
    /// from global search (`ContentView.jumpTo`) alike — without each of
    /// those call sites needing to remember to do it themselves. See
    /// `seedIfNeeded` for why this matters.
    @Published var currentIndex: Int = 0 {
        didSet {
            guard notes.indices.contains(currentIndex) else { return }
            seedIfNeeded(noteID: notes[currentIndex].id, text: notes[currentIndex].text)
        }
    }

    /// A running countdown now survives navigating away from the note that
    /// started it — it used to be cleared on every note switch, which read
    /// as the timer just vanishing with nothing to say it was still running
    /// elsewhere. `ContentView`'s overlay already renders outside the
    /// per-note content, so it keeps showing across a switch for free once
    /// this stops being cleared.
    @Published private(set) var activeTimerEnd: Date?
    /// Set only while `activeTimerEnd` belongs to a Pomodoro cycle rather than
    /// a plain timer, so the overlay can label the countdown "Work"/"Break"
    /// instead of the bare clock a plain timer gets.
    @Published private(set) var activePomodoroPhase: PomodoroPhase?
    /// Which note the running countdown belongs to — nil when nothing is
    /// running. Lets the overlay name it when it's not the note on screen,
    /// and lets `evaluateTimer` tell "editing the note that actually owns
    /// this" apart from "editing some other, unrelated note" now that a
    /// countdown outlives navigating away from its note.
    @Published private(set) var activeTimerOwnerID: UUID?

    /// The most recently *seen* directive text in each note, keyed by note
    /// id — one shared `timerSource` string used to be enough when a timer
    /// only ever belonged to whichever note was current. Per-note now:
    /// switching to a different note that happens to already contain old
    /// directive text must not spontaneously start (or restart) anything
    /// just because that note got edited somewhere unrelated later.
    private var seenTimerSource: [UUID: String] = [:]
    /// Same role as `seenTimerSource`, for Pomodoro directives.
    private var seenPomodoroSource: [UUID: String] = [:]
    /// Notes whose directive text has already been recorded once this
    /// session, so `seedIfNeeded` only ever does that once per note rather
    /// than re-deriving it (harmlessly, but needlessly) on every visit.
    private var seededNoteIDs: Set<UUID> = []

    /// The durations a running cycle alternates between. Set when a cycle
    /// starts, read every time a phase fires to know how long the next one
    /// runs — `activeTimerEnd` alone can't say that once it's been reset for
    /// the next phase.
    private var pomodoroCycle: PomodoroDirective?

    /// Configurable via Preferences; "5m <keyword>" starts a countdown.
    var timerKeyword: String = "timer"

    /// Configurable via Preferences; "<keyword> 25/5" starts a Pomodoro cycle.
    var pomodoroKeyword: String = "pomodoro"

    private let store: NoteStore
    private var pendingSave: DispatchWorkItem?
    private let saveDebounce: TimeInterval

    init(store: NoteStore = NoteStore(), saveDebounce: TimeInterval = 0.6) {
        self.store = store
        self.saveDebounce = saveDebounce
        self.notes = store.load()
        self.currentIndex = max(0, notes.count - 1)
        // `currentIndex`'s didSet is not guaranteed to fire for this same
        // assignment (property observers on a `@Published` value set during
        // this class's own `init` are not reliable — see the font-size
        // clamp bug in `SettingsManager.init` for the same lesson learned
        // the hard way), so the initial note is seeded explicitly here too.
        // `seedIfNeeded` is idempotent, so this never double-seeds.
        if notes.indices.contains(currentIndex) {
            seedIfNeeded(noteID: notes[currentIndex].id, text: notes[currentIndex].text)
        }
    }

    // MARK: - Text

    var currentText: String {
        get { notes.indices.contains(currentIndex) ? notes[currentIndex].text : "" }
        set {
            guard notes.indices.contains(currentIndex) else { return }
            let id = notes[currentIndex].id
            notes[currentIndex].text = newValue
            evaluateTimer(in: newValue, noteID: id)
            scheduleSave()
        }
    }

    // MARK: - Per-note typography

    /// Nil means this note has never had its own font set, so display falls
    /// back to `SettingsManager.noteFontName`.
    var currentFontName: String? {
        get { notes.indices.contains(currentIndex) ? notes[currentIndex].fontName : nil }
        set {
            guard notes.indices.contains(currentIndex) else { return }
            notes[currentIndex].fontName = newValue
            scheduleSave()
        }
    }

    var currentFontSize: Double? {
        get { notes.indices.contains(currentIndex) ? notes[currentIndex].fontSize : nil }
        set {
            guard notes.indices.contains(currentIndex) else { return }
            notes[currentIndex].fontSize = newValue
            scheduleSave()
        }
    }

    // MARK: - Indexed access (edge stack)

    func text(at index: Int) -> String {
        notes.indices.contains(index) ? notes[index].text : ""
    }

    func setText(_ newValue: String, at index: Int) {
        guard notes.indices.contains(index) else { return }
        let id = notes[index].id
        notes[index].text = newValue
        // Unconditional now, not just for whichever card happens to be
        // `currentIndex`: Screen Edge mode shows every note as its own
        // editable card, and a timer/Pomodoro directive typed into any of
        // them should start counting down, not just the one that happened
        // to be current when the mode was entered.
        evaluateTimer(in: newValue, noteID: id)
        scheduleSave()
    }

    /// Unconditional, unlike addNewNote: the stack shows every note at once, so
    /// there is no ambiguity about which blank one you meant.
    func appendNote() {
        notes.append(Note())
        currentIndex = notes.count - 1
        flush()
    }

    func deleteNote(at index: Int) {
        guard notes.indices.contains(index), notes.count > 1 else {
            // Never leave the model with nothing to address.
            if notes.indices.contains(index) {
                let id = notes[index].id
                notes[index].text = ""
                forgetTimerState(for: id)
            }
            flush()
            return
        }
        let id = notes[index].id
        // Which note the user is actually looking at, captured by identity
        // before the array shifts under it. Clamping the index alone was
        // wrong for every deletion below the current one: with [A, B, C]
        // showing B, deleting A left `currentIndex` at 1, which is now C, so
        // the note on screen silently changed to one the user never asked
        // for. The clamp happened to give the right answer when the current
        // note was last, or was the one being deleted, which is why it
        // survived. `moveNote` just below already tracks the current note by
        // id across its mutation; this is the same approach.
        //
        // Beyond the visible note, `currentIndex`'s `didSet` seeds timer
        // tracking for whichever note it lands on, and `validateMenuItem` in
        // Jot.swift reads it to enable the move and switch items, so a wrong
        // index quietly spread further than the one thing it looked like.
        let currentID = notes.indices.contains(currentIndex) ? notes[currentIndex].id : nil
        forgetTimerState(for: id)
        notes.remove(at: index)
        if let currentID, currentID != id, let stillThere = notes.firstIndex(where: { $0.id == currentID }) {
            currentIndex = stillThere
        } else {
            // The current note itself was deleted, so there is no identity to
            // restore. Falling to whatever now sits at that index (clamped to
            // the end) is the existing behaviour and is what a user deleting
            // the note they are looking at expects.
            currentIndex = min(currentIndex, notes.count - 1)
        }
        flush()
    }

    /// A deleted note leaves nothing to point back to: an orphaned countdown
    /// running for a note that no longer exists would be actively confusing,
    /// not just untidy, so it's cancelled outright rather than left running.
    /// The blank-instead-of-removed path above (the last note left) hits
    /// this too, since blanking the text there bypasses `evaluateTimer`
    /// entirely — nothing else would ever notice the directive is gone.
    private func forgetTimerState(for noteID: UUID) {
        if activeTimerOwnerID == noteID {
            activeTimerEnd = nil
            activePomodoroPhase = nil
            pomodoroCycle = nil
            activeTimerOwnerID = nil
        }
        seenTimerSource[noteID] = nil
        seenPomodoroSource[noteID] = nil
        seededNoteIDs.remove(noteID)
    }

    // MARK: - Navigation

    func previousNote() {
        guard currentIndex > 0 else { return }
        purgeEmptyNotesPreservingCurrent()
        // No timer bookkeeping here any more: `currentIndex`'s `didSet`
        // seeds the note being switched to on its own, and a running
        // countdown belonging to some other note is meant to keep going
        // regardless of where navigation lands.
        currentIndex = max(0, currentIndex - 1)
        flush()
    }

    func nextNote() {
        if currentIndex < notes.count - 1 {
            purgeEmptyNotesPreservingCurrent()
            currentIndex = min(notes.count - 1, currentIndex + 1)
            flush()
        } else {
            addNewNote()
        }
    }

    func addNewNote() {
        // Refuse to stack blank notes on top of a blank note.
        guard !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notes.append(Note())
        currentIndex = notes.count - 1
        flush()
    }

    // MARK: - Reordering

    /// Moves one note to another position in the list.
    ///
    /// `to` follows the `Array.move(fromOffsets:toOffset:)` convention SwiftUI's
    /// `onMove` uses: the destination is counted in the array *before* the note
    /// is removed, so "drop before whatever sits at index 2" passes 2. Under
    /// that convention `to == from` and `to == from + 1` both leave every note
    /// where it started, which is what makes them the early-exit slots.
    ///
    /// The current note is tracked by identity across the move rather than by
    /// doing arithmetic on `currentIndex`, so reordering never changes which
    /// note the user is looking at — including when it is the one being moved.
    /// A timer running on a moved note keeps running, and no purging happens:
    /// moving is not navigating.
    func moveNote(from source: Int, to destination: Int) {
        guard source != destination, source != destination - 1 else { return }
        guard notes.indices.contains(source),
              notes.indices.contains(currentIndex),
              destination >= 0, destination <= notes.count
        else { return }

        let currentID = notes[currentIndex].id
        let note = notes.remove(at: source)
        notes.insert(note, at: destination > source ? destination - 1 : destination)
        // The current note cannot be absent here — moves remove nothing — so
        // the fallback only exists to keep the compiler and future edits honest.
        currentIndex = notes.firstIndex(where: { $0.id == currentID }) ?? min(currentIndex, notes.count - 1)
        scheduleSave()
    }

    /// Walks the current note through the list by keyboard: negative is toward
    /// the top, positive toward the bottom, clamped at both ends. Moving down
    /// one slot targets `currentIndex + 2` under the onMove convention —
    /// `+ 1` is the do-nothing slot — and `notes.count` itself is a legal
    /// destination meaning "to the very end".
    func moveCurrentNote(by delta: Int) {
        let target = delta < 0
            ? max(0, currentIndex + delta)
            : min(notes.count, currentIndex + delta + 1)
        moveNote(from: currentIndex, to: target)
    }

    // MARK: - Timers

    /// Matches "90s timer", "5m timer", "2h timer" (case-insensitive).
    ///
    /// The keyword is configurable, so the pattern is built per keyword and
    /// cached rather than compiled as a constant.
    private static var patternCache: [String: NSRegularExpression] = [:]
    private static let patternCacheLock = NSLock()

    static func timerRegex(keyword: String) -> NSRegularExpression? {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = keyword.isEmpty ? "timer" : keyword

        patternCacheLock.lock()
        defer { patternCacheLock.unlock() }

        if let cached = patternCache[effective] { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: effective)
        guard let regex = try? NSRegularExpression(
            pattern: "([0-9]+)\\s*([smh])\\s*" + escaped,
            options: .caseInsensitive
        ) else { return nil }
        patternCache[effective] = regex
        return regex
    }

    static func firstTimerDirective(in text: String, keyword: String = "timer") -> TimerDirective? {
        guard let regex = timerRegex(keyword: keyword) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let amount = Int(ns.substring(with: match.range(at: 1)))
        else { return nil }

        let unit = ns.substring(with: match.range(at: 2)).lowercased()
        let multiplier: TimeInterval
        switch unit {
        case "s": multiplier = 1
        case "h": multiplier = 3600
        default:  multiplier = 60
        }

        return TimerDirective(
            source: ns.substring(with: match.range(at: 0)),
            duration: TimeInterval(amount) * multiplier
        )
    }

    /// Matches "pomodoro 25/5", "pomodoro 60/10" (case-insensitive) — the
    /// keyword, then work minutes and break minutes separated by a slash.
    /// Keyword leads here rather than trailing like the plain timer's "5m
    /// timer": read as "a pomodoro of 25 on, 5 off" rather than a bare
    /// duration, which is how it was specified.
    private static var pomodoroPatternCache: [String: NSRegularExpression] = [:]
    private static let pomodoroPatternCacheLock = NSLock()

    static func pomodoroRegex(keyword: String) -> NSRegularExpression? {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = keyword.isEmpty ? "pomodoro" : keyword

        pomodoroPatternCacheLock.lock()
        defer { pomodoroPatternCacheLock.unlock() }

        if let cached = pomodoroPatternCache[effective] { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: effective)
        guard let regex = try? NSRegularExpression(
            pattern: escaped + "\\s+([0-9]+)\\s*/\\s*([0-9]+)",
            options: .caseInsensitive
        ) else { return nil }
        pomodoroPatternCache[effective] = regex
        return regex
    }

    static func firstPomodoroDirective(in text: String, keyword: String = "pomodoro") -> PomodoroDirective? {
        guard let regex = pomodoroRegex(keyword: keyword) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let workMinutes = Int(ns.substring(with: match.range(at: 1))),
              let breakMinutes = Int(ns.substring(with: match.range(at: 2)))
        else { return nil }

        return PomodoroDirective(
            source: ns.substring(with: match.range(at: 0)),
            workDuration: TimeInterval(workMinutes) * 60,
            breakDuration: TimeInterval(breakMinutes) * 60
        )
    }

    /// A Pomodoro directive takes over the app's one countdown slot outright:
    /// checked first, and when present a plain timer directive elsewhere in
    /// the same note is ignored rather than fought over. There is still only
    /// ever one countdown running anywhere — a fresh directive typed into
    /// *any* note silently takes the slot over from whatever was running
    /// before, by design (multiple independent, simultaneous timers is a
    /// bigger feature, tracked separately in BACKLOG.md).
    private func evaluateTimer(in text: String, noteID: UUID) {
        if let cycle = Self.firstPomodoroDirective(in: text, keyword: pomodoroKeyword) {
            seenTimerSource[noteID] = nil
            // Already running, or already fired, this exact directive.
            guard cycle.source != seenPomodoroSource[noteID] else { return }
            seenPomodoroSource[noteID] = cycle.source
            pomodoroCycle = cycle
            activePomodoroPhase = .work
            activeTimerEnd = Date().addingTimeInterval(cycle.workDuration)
            activeTimerOwnerID = noteID
            return
        }
        // No Pomodoro directive in this note right now. If this note used to
        // have one and it's the cycle actually running, editing it away
        // cancels the cycle — the same "remove the directive, it stops" rule
        // a plain timer already follows below.
        if seenPomodoroSource[noteID] != nil {
            seenPomodoroSource[noteID] = nil
            if activeTimerOwnerID == noteID, activePomodoroPhase != nil {
                activeTimerEnd = nil
                activePomodoroPhase = nil
                pomodoroCycle = nil
                activeTimerOwnerID = nil
            }
        }

        guard let directive = Self.firstTimerDirective(in: text, keyword: timerKeyword) else {
            if seenTimerSource[noteID] != nil {
                seenTimerSource[noteID] = nil
                if activeTimerOwnerID == noteID, activePomodoroPhase == nil {
                    activeTimerEnd = nil
                    activeTimerOwnerID = nil
                }
            }
            return
        }
        // Already running, or already fired, for this exact directive.
        guard directive.source != seenTimerSource[noteID] else { return }
        seenTimerSource[noteID] = directive.source
        activeTimerEnd = Date().addingTimeInterval(directive.duration)
        activePomodoroPhase = nil
        pomodoroCycle = nil
        activeTimerOwnerID = noteID
    }

    /// The first time a note is displayed this session — navigated to,
    /// created, or jumped to from search — its existing directive text, if
    /// any, is recorded as already seen. Without this, switching to a note
    /// that already contains old directive text (typed in a previous
    /// session, or just sitting there unedited) would look like "a brand
    /// new directive" the next time *any* part of that note is edited, and
    /// spontaneously start counting down.
    private func seedIfNeeded(noteID: UUID, text: String) {
        guard !seededNoteIDs.contains(noteID) else { return }
        seededNoteIDs.insert(noteID)
        seenTimerSource[noteID] = Self.firstTimerDirective(in: text, keyword: timerKeyword)?.source
        seenPomodoroSource[noteID] = Self.firstPomodoroDirective(in: text, keyword: pomodoroKeyword)?.source
    }

    /// Re-parses every note's tracking after the keyword changes in
    /// Preferences — every previously-recorded "already seen" directive was
    /// matched under the old keyword and means nothing under the new one.
    /// A currently-running plain timer is cancelled too (its own keyword no
    /// longer necessarily matches what's in its note); a running Pomodoro
    /// cycle is left alone, since it's keyed on the separate Pomodoro
    /// keyword and this change doesn't touch it.
    func timerKeywordDidChange(to keyword: String) {
        timerKeyword = keyword
        if activePomodoroPhase == nil {
            activeTimerEnd = nil
            activeTimerOwnerID = nil
        }
        seenTimerSource.removeAll()
        seededNoteIDs.removeAll()
        if notes.indices.contains(currentIndex) {
            seedIfNeeded(noteID: notes[currentIndex].id, text: notes[currentIndex].text)
        }
    }

    /// Same rationale as `timerKeywordDidChange`, for the Pomodoro keyword: a
    /// running Pomodoro cycle is cancelled, a running plain timer is left
    /// alone.
    func pomodoroKeywordDidChange(to keyword: String) {
        pomodoroKeyword = keyword
        if activePomodoroPhase != nil {
            activeTimerEnd = nil
            activePomodoroPhase = nil
            pomodoroCycle = nil
            activeTimerOwnerID = nil
        }
        seenPomodoroSource.removeAll()
        seededNoteIDs.removeAll()
        if notes.indices.contains(currentIndex) {
            seedIfNeeded(noteID: notes[currentIndex].id, text: notes[currentIndex].text)
        }
    }

    /// Marks the running countdown as finished. A plain timer stops and
    /// releases ownership; a Pomodoro phase instead flips to the other half
    /// of its cycle and starts counting that down — work becomes break,
    /// break becomes the next work block — for as long as the directive
    /// stays in its note, keeping the same owner throughout. The owning
    /// note's `seenTimerSource`/`seenPomodoroSource` entry is left alone
    /// either way, so the fired directive's own text never resurrects it.
    func timerDidFire() {
        guard let phase = activePomodoroPhase, let cycle = pomodoroCycle else {
            activeTimerEnd = nil
            activeTimerOwnerID = nil
            return
        }
        let next: PomodoroPhase = phase == .work ? .rest : .work
        activePomodoroPhase = next
        activeTimerEnd = Date().addingTimeInterval(next == .work ? cycle.workDuration : cycle.breakDuration)
    }

    // MARK: - Persistence

    /// Drops blank notes without disturbing which note the user is looking at.
    ///
    /// The old `saveNotes()` computed a filtered array and then saved the
    /// unfiltered one, so purging never actually happened. Purging now runs on
    /// navigation and quit rather than on every keystroke, since purging mid-typing
    /// would delete the very note being written.
    private func purgeEmptyNotesPreservingCurrent() {
        let current = currentText
        var kept: [Note] = []
        var newIndex = 0
        for (i, note) in notes.enumerated() {
            if !note.isBlank || i == currentIndex {
                if i == currentIndex { newIndex = kept.count }
                kept.append(note)
            }
        }
        if kept.isEmpty {
            kept = [Note()]
            newIndex = 0
        }
        notes = kept
        currentIndex = min(newIndex, kept.count - 1)
        _ = current
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.store.save(self.notes)
            self.onPersist?(self.notes)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounce, execute: work)
    }

    /// Called after every write, so external sync can follow the same rhythm.
    var onPersist: (([Note]) -> Void)?

    /// Writes immediately, cancelling any debounced save. Called on navigation
    /// and on app termination.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        store.save(notes)
        onPersist?(notes)
    }

    /// Purge and write. Called when the app is quitting.
    func flushForTermination() {
        purgeEmptyNotesPreservingCurrent()
        flush()
    }
}
