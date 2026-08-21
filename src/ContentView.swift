import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var notesManager = NotesManager()
    @State private var timeRemaining: String = ""
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            mainContent
            
            if notesManager.activeTimerEnd != nil {
                timerOverlay
            }
        }
        .background(VisualEffectView().ignoresSafeArea())
        .gesture(swipeGesture)
        .onAppear {
            updateTimer()
        }
    }
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            headerView
            
            TextEditor(text: $notesManager.currentText)
                .font(.system(.body, design: .monospaced))
                .padding()
                .scrollContentBackground(.hidden)
                .background(Color.clear)
        }
    }
    
    private var headerView: some View {
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
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
    }
    
    private var timerOverlay: some View {
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
    
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50, coordinateSpace: .local)
            .onEnded { value in
                if value.translation.width > 0 {
                    notesManager.previousNote()
                } else if value.translation.width < 0 {
                    notesManager.nextNote()
                }
            }
    }
    
    func updateTimer() {
        guard let endDate = notesManager.activeTimerEnd else { return }
        let diff = endDate.timeIntervalSince(Date())
        if diff <= 0 {
            timeRemaining = "00:00"
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
        view.material = .popover
        view.blendingMode = .behindWindow
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
