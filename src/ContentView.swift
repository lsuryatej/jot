import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @ObservedObject var notesManager: NotesManager
    @ObservedObject var settings: SettingsManager

    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var timeRemaining: String = ""
    /// Set when a global search result lands in the single-note editor; reset
    /// to nil by PlainTextEditor once it's scrolled/selected the match.
    @State private var scrollTarget: NSRange?
    /// Set when a result lands while docked to an edge, where every note is
    /// already visible and there's a card to scroll to instead of a range.
    @State private var edgeScrollIndex: Int?
    @State private var showingGlobalSearch = false
    /// What a swipe landed on, shown briefly when the header bar is hidden
    /// and nothing else on screen says which note you are now reading.
    @State private var swipeFeedback: String?
    @State private var swipeFeedbackDismiss: DispatchWorkItem?
    @State private var reminderToastDismiss: DispatchWorkItem?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Chrome text follows the paper's ink, not SwiftUI's semantic colors:
    /// `.secondary` tracks the system's mode, so a light-mode user on True
    /// Dark would read dark header text on a near-black strip — the same
    /// trap the body ink already solves.
    private var ink: InkTheme {
        settings.effectiveInk
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if settings.displayMode.isEdgeDocked {
                // Docked to an edge there is room for every note at once, so
                // the stack replaces swipe navigation entirely.
                EdgeStackView(notesManager: notesManager, settings: settings, scrollToIndex: $edgeScrollIndex)
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

            swipeFeedbackOverlay
            reminderToastOverlay

            if showingGlobalSearch {
                GlobalSearchView(notesManager: notesManager, isPresented: $showingGlobalSearch) { result in
                    jumpTo(result)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(backdrop)
        .overlay(litEdge)
        .onReceive(NotificationCenter.default.publisher(for: .jotRequestGlobalSearch)) { _ in
            showingGlobalSearch.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jotRequestToggleChrome)) { _ in
            toggleChrome()
        }
        .onChange(of: notesManager.reminderConfirmation) { _, newValue in
            guard newValue != nil else { return }
            showReminderToast()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jotReminderNotAuthorized)) { _ in
            // Reuses the same confirmation toast/timer: this is exactly the
            // same "say what just happened with the reminder you typed"
            // moment, just the failure case of it rather than the success
            // one — the two should never both be trying to say something at
            // the same time.
            notesManager.reminderConfirmation = "Notifications are off — enable in System Settings"
            showReminderToast()
        }
    }

    // MARK: - Chrome

    /// One shortcut, one on/off state: header and footer flip together
    /// rather than needing two keystrokes to reach a clean, focus-mode
    /// screen. If they were showing different things (mixed state, reachable
    /// only via Settings), showing both first reads as "turn the chrome on"
    /// before the next press turns it fully off, rather than a surprise jump.
    private func toggleChrome() {
        let showing = settings.showsHeader || settings.showsFooter
        settings.showsHeader = !showing
        settings.showsFooter = !showing
    }

    // MARK: - Global search

    private func jumpTo(_ result: GlobalSearchResult) {
        if settings.displayMode.isEdgeDocked {
            edgeScrollIndex = result.noteIndex
            return
        }
        if notesManager.currentIndex != result.noteIndex {
            notesManager.currentIndex = result.noteIndex
        }
        scrollTarget = result.matchRange
    }

    // MARK: - Surface

    private var backdrop: some View {
        Group {
            if let paper = settings.effectivePaperColor {
                // An opaque paper replaces the blur entirely.
                Rectangle().fill(Color(nsColor: paper))
            } else {
                VisualEffectView(
                    material: NSVisualEffectView.Material(rawValue: settings.effectiveMaterialRawValue) ?? .popover
                )
                    // A tint is a wash over the material, not a replacement
                    // for it — the desktop still comes through underneath.
                    .overlay(tintWash.ignoresSafeArea())
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var tintWash: some View {
        if let tint = settings.effectiveTint.overlayColor {
            Rectangle()
                .fill(Color(nsColor: tint))
                .opacity(settings.glassTint.overlayOpacity)
        }
    }

    /// A hairline of light along the inside of the window edge.
    ///
    /// Real glass catches light where it turns; without this the panel reads as
    /// a flat translucent rectangle rather than a pane sitting above the
    /// desktop. Drawn inside the window's own corner radius so it tracks the
    /// system shape rather than fighting it.
    @ViewBuilder
    private var litEdge: some View {
        if settings.effectiveWantsLitEdge {
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
            lineHeightMultiple: settings.effectiveLineSpacing,
            baseFont: settings.resolvedEditorFont(
                perNoteName: notesManager.currentFontName,
                perNoteSize: notesManager.currentFontSize
            ),
            letterSpacing: settings.effectiveLetterSpacing,
            ink: settings.effectiveInk,
            guide: settings.effectiveGuide,
            listKeyword: settings.effectiveListKeyword,
            codeKeyword: settings.effectiveCodeKeyword,
            topInset: settings.showsHeader ? 12 : 38,
            text: Binding(
                get: { notesManager.currentText },
                set: { notesManager.currentText = $0 }
            ),
            selectedRange: $selectedRange,
            scrollTarget: $scrollTarget,
            onSwipe: { direction in
                navigate(direction)
            }
        )
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Text("Note \(notesManager.currentIndex + 1) of \(notesManager.notes.count)")
                .font(.caption)
                .foregroundStyle(Color(nsColor: ink.secondary))

            Button("Checklist") {
                // Posted directly to the text view rather than routed through
                // NSApp.sendAction's responder-chain walk — that indirection
                // was the actual cause of a real, reported bug where a rapid
                // second click on Highlight corrupted text instead of
                // unwrapping it. See the notification's own doc comment in
                // PreferencesView.swift.
                NotificationCenter.default.post(name: .jotRequestToggleChecklistFromHeader, object: nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .help("Toggle the checkbox on the current line or selection (⌘L)")

            Button("Highlight") {
                NotificationCenter.default.post(name: .jotRequestToggleHighlightFromHeader, object: nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .help("Highlight the selection, or start a highlight at the caret (⇧⌘H)")

            Spacer()

            fontControls

            Button(action: shareNote) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("Share this note")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: settings.effectiveChromeColor).opacity(0.8))
    }

    /// Font and size for the open note specifically — the header is already
    /// optional (Cmd+/ hides it along with the footer), so putting this here
    /// rather than only in Settings costs nothing when you don't want it, and
    /// saves a trip to Settings for something you reach for per note. Kept
    /// to a bare name menu and a stepper, no labels, so it sits quietly next
    /// to the Checklist/Highlight buttons rather than crowding them.
    private var fontControls: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(NoteFont.all, id: \.self) { name in
                    Button(name) { notesManager.currentFontName = name }
                }
                if notesManager.currentFontName != nil {
                    Divider()
                    Button("Use default") { notesManager.currentFontName = nil }
                }
            } label: {
                Text(settings.resolvedFontName(perNote: notesManager.currentFontName))
                    .font(.caption)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("This note's font — Settings has a separate default for new notes")

            Stepper(
                value: Binding(
                    get: { notesManager.currentFontSize ?? settings.noteFontSize },
                    set: { notesManager.currentFontSize = SettingsManager.clampedFontSize($0) }
                ),
                in: SettingsManager.fontSizeRange,
                step: 1
            ) {
                Text("\(Int(settings.resolvedFontSize(perNote: notesManager.currentFontSize)))pt")
                    .font(.caption)
            }
            .fixedSize()
            .help("This note's size")
        }
    }

    // MARK: - Footer

    /// Live counts, and sum/average whenever the selection holds numbers.
    private var footerView: some View {
        HStack(spacing: 8) {
            Text(countsLabel)
                .font(.caption2)
                .foregroundStyle(Color(nsColor: ink.secondary))

            Spacer()

            if let math = selectionMath {
                Text(math.summary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color(nsColor: ink.text))
                    .help("\(math.count) numbers in the selection")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: settings.effectiveChromeColor).opacity(0.6))
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

    /// A plain timer is unlabeled red, matching its look before Pomodoro
    /// existed. A Pomodoro phase adds its name and swaps to green for the
    /// break half, the closest thing this chip has to a status color, so a
    /// glance says whether you're meant to be working or not without reading
    /// the clock.
    /// The owning note's title, shown only when it differs from the note on
    /// screen. On the note that actually owns the countdown, "Work"/the
    /// clock alone is enough — the same look this chip had before it could
    /// outlive navigating away. Anywhere else, without this, the chip says
    /// a timer is running but gives no hint which note to go find it on.
    private var timerOwnerLabel: String? {
        guard let ownerID = notesManager.activeTimerOwnerID,
              notesManager.notes.indices.contains(notesManager.currentIndex),
              notesManager.notes[notesManager.currentIndex].id != ownerID,
              let owner = notesManager.notes.first(where: { $0.id == ownerID })
        else { return nil }
        return owner.title
    }

    private var timerOverlay: some View {
        HStack(spacing: 6) {
            if let owner = timerOwnerLabel {
                Text(owner)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: 90, alignment: .leading)
            }
            if let phase = notesManager.activePomodoroPhase {
                Text(phase == .work ? "Work" : "Break")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
            }
            Text(timeRemaining.isEmpty ? "--:--" : timeRemaining)
                .font(.system(.headline, design: .monospaced))
        }
        .padding(8)
        .background((notesManager.activePomodoroPhase == .rest ? Color.green : Color.red).opacity(0.8))
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
            // The timer's whole payoff: a sound and, if the user wants it,
            // a burst of confetti over everything else on screen.
            CelebrationWindowController.fire(
                style: settings.celebrationStyle,
                sound: settings.timerSound
            )
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

    // MARK: - Swipe feedback

    /// Swiping moves between notes; with the header hidden there is no
    /// "Note N of M" anywhere to say where you landed, so a chip says it
    /// briefly instead. Shown only when it is saying something the screen
    /// does not already show.
    @ViewBuilder
    private var swipeFeedbackOverlay: some View {
        if let swipeFeedback {
            Text(swipeFeedback)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: settings.effectiveHairlineColor).opacity(settings.effectiveWantsLitEdge ? 0.18 : 0.10), lineWidth: 1))
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func navigate(_ direction: SwipeDirection) {
        switch direction {
        case .right: notesManager.previousNote()
        case .left:  notesManager.nextNote()
        }
        showSwipeFeedback()
    }

    private func showSwipeFeedback() {
        guard !settings.showsHeader,
              notesManager.notes.indices.contains(notesManager.currentIndex)
        else { return }

        let note = notesManager.notes[notesManager.currentIndex]
        withAnimation(.easeOut(duration: 0.15)) {
            swipeFeedback = "\(note.title) · \(notesManager.currentIndex + 1)/\(notesManager.notes.count)"
        }

        // A quick run of swipes restarts the clock rather than stacking
        // dismissals that fight each other.
        swipeFeedbackDismiss?.cancel()
        let dismiss = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.3)) { swipeFeedback = nil }
        }
        swipeFeedbackDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: dismiss)
    }

    // MARK: - Reminder feedback

    /// A brief "Reminder set for …" confirmation the moment a `remind`
    /// directive is typed, so a wrong time or date is obvious immediately —
    /// answers the same question the swipe chip does ("did what I just do
    /// actually take?"), just for a different action. Shown regardless of
    /// display mode: reminders can be set from a windowed note or an edge
    /// card alike, unlike the swipe chip, which only ever matters with the
    /// header hidden.
    @ViewBuilder
    private var reminderToastOverlay: some View {
        if let message = notesManager.reminderConfirmation {
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: settings.effectiveHairlineColor).opacity(settings.effectiveWantsLitEdge ? 0.18 : 0.10), lineWidth: 1))
                .frame(maxWidth: .infinity)
                .padding(.top, settings.showsHeader ? 44 : 10)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Longer on screen than the swipe chip (2.5s vs 1.4s): this is telling
    /// you something you need to actually read and check, not just
    /// confirming where you already know you landed.
    private func showReminderToast() {
        reminderToastDismiss?.cancel()
        let dismiss = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.3)) { notesManager.reminderConfirmation = nil }
        }
        reminderToastDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: dismiss)
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
