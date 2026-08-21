import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @StateObject private var notesManager = NotesManager()
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var timeRemaining: String = ""

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                headerView
                editor
            }

            if notesManager.activeTimerEnd != nil {
                timerOverlay
            }
        }
        .background(VisualEffectView().ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .stickyNotesWillTerminate)) { _ in
            // Debounced saves must not be lost when the process exits.
            notesManager.flushForTermination()
        }
    }

    private var editor: some View {
        PlainTextEditor(
            text: Binding(
                get: { notesManager.currentText },
                set: { notesManager.currentText = $0 }
            ),
            selectedRange: $selectedRange,
            onSwipe: { direction in
                switch direction {
                case .right: notesManager.previousNote()
                case .left:  notesManager.nextNote()
                }
            }
        )
    }

    private var headerView: some View {
        HStack(spacing: 10) {
            Text("Note \(notesManager.currentIndex + 1) of \(notesManager.notes.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Toggle Checklist") {
                notesManager.toggleChecklist(atCharacterIndex: selectedRange.location)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .help("Toggle the checkbox on the current line")

            Spacer()

            Button(action: shareNote) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("Share this note")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
    }

    private var timerOverlay: some View {
        Text(timeRemaining.isEmpty ? "--:--" : timeRemaining)
            .font(.system(.headline, design: .monospaced))
            .padding(8)
            .background(Color.red.opacity(0.8))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 50)
            .padding(.trailing, 20)
            .onAppear { updateTimer() }
            .onReceive(tick) { _ in updateTimer() }
    }

    private func updateTimer() {
        guard let endDate = notesManager.activeTimerEnd else { return }
        let remaining = endDate.timeIntervalSince(Date())

        guard remaining > 0 else {
            timeRemaining = "00:00"
            NSSound(named: "Glass")?.play()
            notesManager.timerDidFire()
            return
        }

        let total = Int(remaining.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        timeRemaining = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    private func shareNote() {
        let text = notesManager.currentText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // The panel is a non-activating panel, so it is frequently not the key
        // window. Anchoring to NSApp.keyWindow made this button silently do
        // nothing; anchor to the panel itself instead.
        guard let panel = NSApp.windows.first(where: { $0 is FloatingPanel }),
              let anchor = panel.contentView
        else { return }

        let picker = NSSharingServicePicker(items: [text])
        let rect = NSRect(x: anchor.bounds.maxX - 40, y: anchor.bounds.maxY - 40, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
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
