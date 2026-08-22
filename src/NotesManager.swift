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

final class NotesManager: ObservableObject {
    @Published var notes: [Note] = [Note()]

    /// Convenience for call sites that only care about the text.
    var texts: [String] { notes.map(\.text) }
    @Published var currentIndex: Int = 0
    @Published private(set) var activeTimerEnd: Date?

    /// The directive backing the current timer, retained even after the timer
    /// fires. Without this, an expired "5m timer" still sitting in the text
    /// restarts itself on the next keystroke, forever.
    private var timerSource: String?

    /// Configurable via Preferences; "5m <keyword>" starts a countdown.
    var timerKeyword: String = "timer"

    private let store: NoteStore
    private var pendingSave: DispatchWorkItem?
    private let saveDebounce: TimeInterval

    init(store: NoteStore = NoteStore(), saveDebounce: TimeInterval = 0.6) {
        self.store = store
        self.saveDebounce = saveDebounce
        self.notes = store.load()
        self.currentIndex = max(0, notes.count - 1)
        self.timerSource = Self.firstTimerDirective(in: notes[currentIndex].text, keyword: timerKeyword)?.source
    }

    // MARK: - Text

    var currentText: String {
        get { notes.indices.contains(currentIndex) ? notes[currentIndex].text : "" }
        set {
            guard notes.indices.contains(currentIndex) else { return }
            notes[currentIndex].text = newValue
            evaluateTimer(in: newValue)
            scheduleSave()
        }
    }

    // MARK: - Indexed access (edge stack)

    func text(at index: Int) -> String {
        notes.indices.contains(index) ? notes[index].text : ""
    }

    func setText(_ newValue: String, at index: Int) {
        guard notes.indices.contains(index) else { return }
        notes[index].text = newValue
        if index == currentIndex { evaluateTimer(in: newValue) }
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
            if notes.indices.contains(index) { notes[index].text = "" }
            flush()
            return
        }
        notes.remove(at: index)
        currentIndex = min(currentIndex, notes.count - 1)
        flush()
    }

    // MARK: - Navigation

    func previousNote() {
        guard currentIndex > 0 else { return }
        purgeEmptyNotesPreservingCurrent()
        currentIndex = max(0, currentIndex - 1)
        adoptTimerState(for: currentText)
        flush()
    }

    func nextNote() {
        if currentIndex < notes.count - 1 {
            purgeEmptyNotesPreservingCurrent()
            currentIndex = min(notes.count - 1, currentIndex + 1)
            adoptTimerState(for: currentText)
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
        adoptTimerState(for: "")
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

    private func evaluateTimer(in text: String) {
        guard let directive = Self.firstTimerDirective(in: text, keyword: timerKeyword) else {
            activeTimerEnd = nil
            timerSource = nil
            return
        }
        // Already running, or already fired, for this exact directive.
        guard directive.source != timerSource else { return }
        timerSource = directive.source
        activeTimerEnd = Date().addingTimeInterval(directive.duration)
    }

    /// Called when switching notes: a timer belongs to the note that started it.
    /// An existing directive in the incoming note is recorded as already-seen so
    /// it does not spontaneously start counting down.
    private func adoptTimerState(for text: String) {
        activeTimerEnd = nil
        timerSource = Self.firstTimerDirective(in: text, keyword: timerKeyword)?.source
    }

    /// Re-parses the current note after the keyword changes in Preferences.
    func timerKeywordDidChange(to keyword: String) {
        timerKeyword = keyword
        activeTimerEnd = nil
        timerSource = Self.firstTimerDirective(in: currentText, keyword: keyword)?.source
    }

    /// Marks the running timer as finished without clearing `timerSource`.
    func timerDidFire() {
        activeTimerEnd = nil
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
