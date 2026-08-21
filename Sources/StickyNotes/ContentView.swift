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

struct ContentView: View {
    @StateObject private var notesManager = NotesManager()
    @State private var timeRemaining: String = ""
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Note \(notesManager.currentIndex + 1) of \(notesManager.notes.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("Toggle Checklist") {
                        notesManager.toggleFirstChecklist()
                    }
                    .font(.caption)
                    .buttonStyle(PlainButtonStyle())
                    .padding(.leading, 10)
                    
                    Spacer()
                    Button(action: shareNote) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                
                // Text Editor
                TextEditor(text: $notesManager.currentText)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
            }
            
            // Timer Overlay
            if notesManager.activeTimerEnd != nil {
                Text(timeRemaining)
                    .font(.system(.headline, design: .monospaced))
                    .padding(8)
                    .background(Color.red.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 50)
                    .padding(.trailing, 20)
                    .onReceive(timer) { _ in
                        updateTimer()
                    }
            }
        }
        .background(VisualEffectView().ignoresSafeArea())
        .gesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width > 0 {
                        notesManager.previousNote()
                    } else if value.translation.width < 0 {
                        notesManager.nextNote()
                    }
                }
        )
        .onAppear {
            updateTimer()
        }
    }
    
    func updateTimer() {
        guard let endDate = notesManager.activeTimerEnd else { return }
        let diff = endDate.timeIntervalSince(Date())
        if diff <= 0 {
            timeRemaining = "00:00"
            // Optionally play a sound here
            NSSound(named: "Glass")?.play()
            notesManager.activeTimerEnd = nil
        } else {
            let m = Int(diff) / 60
            let s = Int(diff) % 60
            timeRemaining = String(format: "%02d:%02d", m, s)
        }
    }
    
    func shareNote() {
        let sharingPicker = NSSharingServicePicker(items: [notesManager.currentText])
        if let window = NSApp.keyWindow {
            let view = window.contentView!
            let frame = NSRect(x: view.bounds.maxX - 40, y: view.bounds.maxY - 40, width: 1, height: 1)
            sharingPicker.show(relativeTo: frame, of: view, preferredEdge: .minY)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = .popover // Translucent background
        view.blendingMode = .behindWindow
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
