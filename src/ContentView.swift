import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @ObservedObject var notesManager: NotesManager
    @ObservedObject var settings: SettingsManager

    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var timeRemaining: String = ""

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if settings.displayMode.isEdgeDocked {
                // Docked to an edge there is room for every note at once, so
                // the stack replaces swipe navigation entirely.
                EdgeStackView(notesManager: notesManager, settings: settings)
            } else {
                VStack(spacing: 0) {
                    if settings.showsHeader {
                        headerView
                    }
                    editor
                    if settings.showsFooter {
                        footerView
                    }
                }
            }

            if notesManager.activeTimerEnd != nil {
                timerOverlay
            }
        }
        .background(backdrop)
        .overlay(litEdge)
    }

    // MARK: - Surface

    private var backdrop: some View {
        VisualEffectView(
            material: NSVisualEffectView.Material(rawValue: settings.appearance.materialRawValue) ?? .popover
        )
        .ignoresSafeArea()
    }

    /// A hairline of light along the inside of the window edge.
    ///
    /// Real glass catches light where it turns; without this the panel reads as
    /// a flat translucent rectangle rather than a pane sitting above the
    /// desktop. Drawn inside the window's own corner radius so it tracks the
    /// system shape rather than fighting it.
    @ViewBuilder
    private var litEdge: some View {
        if settings.appearance.wantsLitEdge {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.45), .white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: - Editor

    private var editor: some View {
        PlainTextEditor(
            lineHeightMultiple: settings.lineSpacing,
            listKeyword: settings.effectiveListKeyword,
            topInset: settings.showsHeader ? 12 : 38,
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

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Text("Note \(notesManager.currentIndex + 1) of \(notesManager.notes.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Checklist") {
                // Routed through the responder chain so the button and Cmd+L
                // run the same code path in the text view.
                NSApp.sendAction(#selector(ChecklistTextView.toggleChecklist(_:)), to: nil, from: nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .help("Toggle the checkbox on the current line or selection (⌘L)")

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

    // MARK: - Footer

    /// Live counts, and sum/average whenever the selection holds numbers.
    private var footerView: some View {
        HStack(spacing: 8) {
            Text(countsLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            if let math = selectionMath {
                Text(math.summary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .help("\(math.count) numbers in the selection")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private var countsLabel: String {
        TextStatistics.of(notesManager.currentText).summary
    }

    private var selectionMath: SelectionMath? {
        guard selectedRange.length > 0 else { return nil }
        let ns = notesManager.currentText as NSString
        guard selectedRange.location >= 0,
              selectedRange.location + selectedRange.length <= ns.length
        else { return nil }
        return SelectionMath.of(ns.substring(with: selectedRange))
    }

    // MARK: - Timer

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

    // MARK: - Share

    private func shareNote() {
        let text = notesManager.currentText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // The panel is often not the key window, so anchoring to
        // NSApp.keyWindow made this button silently do nothing.
        guard let anchor = NSApp.windows.first(where: { $0 is FloatingPanel })?.contentView
                ?? NSApp.keyWindow?.contentView
        else { return }

        let picker = NSSharingServicePicker(items: [text])
        let rect = NSRect(x: anchor.bounds.maxX - 40, y: anchor.bounds.maxY - 40, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.blendingMode = .behindWindow
        view.material = material
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
