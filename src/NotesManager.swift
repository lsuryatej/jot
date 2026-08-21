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

    private let store: NoteStore
    private var pendingSave: DispatchWorkItem?
    private let saveDebounce: TimeInterval

    init(store: NoteStore = NoteStore(), saveDebounce: TimeInterval = 0.6) {
        self.store = store
        self.saveDebounce = saveDebounce
        self.notes = store.load()
        self.currentIndex = max(0, notes.count - 1)
        self.timerSource = Self.firstTimerDirective(in: notes[currentIndex])?.source
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

    // MARK: - Checklists

    /// Toggles the checkbox on the line containing `characterIndex`.
    ///
    /// The previous implementation toggled the first `[ ]` in the entire note,
    /// which made it impossible to ever uncheck anything but the first item.
    /// Lines with no checkbox gain one, so the button is never a no-op.
    ///
    /// Returns the character index the caret should land on afterwards.
    @discardableResult
    func toggleChecklist(atCharacterIndex characterIndex: Int) -> Int {
        let text = currentText
        let ns = text as NSString
        let clamped = min(max(0, characterIndex), ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let line = ns.substring(with: lineRange)

        let replacement: String
        let caretShift: Int
        if let r = line.range(of: "[ ]") {
            replacement = line.replacingCharacters(in: r, with: "[x]")
            caretShift = 0
        } else if let r = line.range(of: "[x]") {
            replacement = line.replacingCharacters(in: r, with: "[ ]")
            caretShift = 0
        } else {
            // Preserve leading indentation when introducing a checkbox.
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            replacement = indent + "[ ] " + line.dropFirst(indent.count)
            caretShift = 4
        }

        currentText = ns.replacingCharacters(in: lineRange, with: replacement)
        return clamped + caretShift
    }

    // MARK: - Timers

    /// Matches "90s timer", "5m timer", "2h timer" (case-insensitive).
    private static let timerPattern = try? NSRegularExpression(
        pattern: "([0-9]+)\\s*([smh])\\s*timer",
        options: .caseInsensitive
    )

    static func firstTimerDirective(in text: String) -> TimerDirective? {
        guard let regex = timerPattern else { return nil }
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
        guard let directive = Self.firstTimerDirective(in: text) else {
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
        timerSource = Self.firstTimerDirective(in: text)?.source
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
