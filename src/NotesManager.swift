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
    @Published var notes: [String] = [""]
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
        self.timerSource = Self.firstTimerDirective(in: notes[currentIndex], keyword: timerKeyword)?.source
    }

    // MARK: - Text

    var currentText: String {
        get { notes.indices.contains(currentIndex) ? notes[currentIndex] : "" }
        set {
            guard notes.indices.contains(currentIndex) else { return }
            notes[currentIndex] = newValue
            evaluateTimer(in: newValue)
            scheduleSave()
        }
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
        notes.append("")
        currentIndex = notes.count - 1
        adoptTimerState(for: "")
        flush()
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
        var kept: [String] = []
        var newIndex = 0
        for (i, note) in notes.enumerated() {
            let isBlank = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isBlank || i == currentIndex {
                if i == currentIndex { newIndex = kept.count }
                kept.append(note)
            }
        }
        if kept.isEmpty {
            kept = [""]
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
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounce, execute: work)
    }

    /// Writes immediately, cancelling any debounced save. Called on navigation
    /// and on app termination.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        store.save(notes)
    }

    /// Purge and write. Called when the app is quitting.
    func flushForTermination() {
        purgeEmptyNotesPreservingCurrent()
        flush()
    }
}
