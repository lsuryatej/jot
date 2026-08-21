import SwiftUI
import Combine

class NotesManager: ObservableObject {
    @Published var notes: [String] = [""]
    @Published var currentIndex: Int = 0
    @Published var activeTimerEnd: Date? = nil
    @Published var activeTimerString: String = ""
    
    private let defaultsKey = "saved_notes"
    
    init() {
        loadNotes()
    }
    
    var currentText: String {
        get { notes[currentIndex] }
        set {
            notes[currentIndex] = newValue
            saveNotes()
            checkForTimers(in: newValue)
        }
    }
    
    private func checkForTimers(in text: String) {
        // Simple regex to look for "Xm timer"
        let pattern = "([0-9]+)m timer"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(location: 0, length: text.utf16.count)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                if let minRange = Range(match.range(at: 1), in: text),
                   let minutes = Int(String(text[minRange])) {
                    if activeTimerEnd == nil {
                        activeTimerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
                        activeTimerString = "\(minutes)m"
                    }
                    return
                }
            }
        }
        // If we reach here, no timer string found, we could reset but let's keep it running if deleted? 
        // For MVP, if they delete the text, the timer disappears.
        activeTimerEnd = nil
    }
    
    func addNewNote() {
        if currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        notes.append("")
        currentIndex = notes.count - 1
        saveNotes()
        activeTimerEnd = nil
    }
    
    func previousNote() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
    
    func nextNote() {
        if currentIndex < notes.count - 1 {
            currentIndex += 1
        } else {
            addNewNote()
        }
    }
    
    // Checklists: toggle [ ] to [x] for the line the cursor is on.
    // In plain text SwiftUI TextEditor we can't easily get cursor position,
    // so we'll just toggle the first [ ] we find, or provide a button.
    func toggleFirstChecklist() {
        if let range = currentText.range(of: "[ ]") {
            currentText = currentText.replacingCharacters(in: range, with: "[x]")
        } else if let range = currentText.range(of: "[x]") {
            currentText = currentText.replacingCharacters(in: range, with: "[ ]")
        }
    }
    
    private func saveNotes() {
        var cleanedNotes = notes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if cleanedNotes.isEmpty {
            cleanedNotes = [""]
        }
        UserDefaults.standard.set(notes, forKey: defaultsKey)
    }
    
    private func loadNotes() {
        if let saved = UserDefaults.standard.stringArray(forKey: defaultsKey), !saved.isEmpty {
            notes = saved
            currentIndex = notes.count - 1
        }
    }
}
