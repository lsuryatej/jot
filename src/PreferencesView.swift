import SwiftUI
import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// The registered hot key intercepts keystrokes system-wide, so it has to be
    /// released while the recorder is listening or the current shortcut can
    /// never be pressed to re-record it.
    static let jotBeginHotKeyRecording = Notification.Name("JotBeginHotKeyRecording")
    static let jotEndHotKeyRecording = Notification.Name("JotEndHotKeyRecording")
    /// Posted by the text view's Cmd+N handling; observed by AppDelegate,
    /// which is the one place that knows how to reveal/focus correctly.
    static let jotRequestNewNote = Notification.Name("JotRequestNewNote")
    /// Posted by the text view's Cmd+Shift+F handling and by the Find menu's
    /// "Search All Notes" item; observed by ContentView, which owns the
    /// overlay's visibility state.
    static let jotRequestGlobalSearch = Notification.Name("JotRequestGlobalSearch")
    /// Posted by the text view's Ctrl-Cmd-Up / Ctrl-Cmd-Down handling; observed
    /// by AppDelegate, which owns the one NotesManager and can see whether the
    /// panel is visible at all.
    static let jotRequestMoveNoteUp = Notification.Name("JotRequestMoveNoteUp")
    static let jotRequestMoveNoteDown = Notification.Name("JotRequestMoveNoteDown")
    /// Posted by the text view's Cmd-Option-Left / Cmd-Option-Right handling;
    /// observed by AppDelegate for the same reason the move-note pair is —
    /// switching which note is on screen instead of reordering the list.
    static let jotRequestNextNote = Notification.Name("JotRequestNextNote")
    static let jotRequestPreviousNote = Notification.Name("JotRequestPreviousNote")
    /// Posted by the text view's Cmd+/ handling and the View menu's item;
    /// observed by ContentView, which owns `showsHeader`/`showsFooter`.
    static let jotRequestToggleChrome = Notification.Name("JotRequestToggleChrome")
    /// Posted by the header's Checklist/Highlight buttons; observed by
    /// `ChecklistTextView` itself, which applies the toggle directly rather
    /// than through `NSApp.sendAction(_:to: nil, from: nil)`'s responder-
    /// chain walk. That indirection was the actual bug behind a rapid
    /// second click on the Highlight button corrupting text instead of
    /// unwrapping it — the toggle logic itself round-trips cleanly under
    /// direct, repeated calls (covered by
    /// `HighlightTests.swift`'s "toggle twice in a row" case), so the fault
    /// was in how the click reached the view, not in what happened once it
    /// arrived. A view observing a notification and acting on itself has no
    /// such ambiguity to have.
    static let jotRequestToggleChecklistFromHeader = Notification.Name("JotRequestToggleChecklistFromHeader")
    static let jotRequestToggleHighlightFromHeader = Notification.Name("JotRequestToggleHighlightFromHeader")
    /// Posted when the text view's "rates off" / "no rates" hint is clicked;
    /// observed by AppDelegate, the one place that owns the settings window.
    static let jotRequestPrivacySettings = Notification.Name("JotRequestPrivacySettings")
    /// Posted by AppDelegate at a settings window that is already open, to
    /// move it to a given pane. A fresh window picks its pane at init instead.
    static let jotShowSettingsPane = Notification.Name("JotShowSettingsPane")
}

/// A settings pane. Replaces the old single long scroll — five sections
/// scanned top to bottom in one column got unwieldy once per-note typography,
/// Pomodoro, and the rest piled on. Grouped the way a person looks for a
/// setting, not the order features shipped in.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case appearance
    case typography
    case notesAndTimers
    case shortcuts
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .typography: return "Typography"
        case .notesAndTimers: return "Notes & Timers"
        case .shortcuts: return "Shortcuts"
        case .privacy: return "Privacy & Sync"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .typography: return "textformat"
        case .notesAndTimers: return "timer"
        case .shortcuts: return "keyboard"
        case .privacy: return "lock.shield"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var notesManager: NotesManager
    @State private var category: SettingsCategory?

    /// `category` starts wherever the caller opened the window to, so a fresh
    /// window opened from the currency hint lands on Privacy & Sync without a
    /// visible jump from General.
    init(settings: SettingsManager, notesManager: NotesManager, category: SettingsCategory = .general) {
        self.settings = settings
        self.notesManager = notesManager
        _category = State(initialValue: category)
    }

    /// The font picker edits whichever note is currently open, not the app-wide
    /// default — so changing it on one note no longer changes every other one.
    /// Falls back to the picked default for display when this note has never
    /// had its own font set, same fallback `resolvedFontName` uses everywhere
    /// else.
    private var currentFontName: Binding<String> {
        Binding(
            get: { notesManager.currentFontName ?? settings.noteFontName },
            set: { notesManager.currentFontName = $0 }
        )
    }

    private var currentFontSize: Binding<Double> {
        Binding(
            get: { notesManager.currentFontSize ?? settings.noteFontSize },
            set: { notesManager.currentFontSize = SettingsManager.clampedFontSize($0) }
        )
    }

    /// A plain `HStack` of buttons rather than `List(selection:)` inside a
    /// `NavigationSplitView` — the first version of this shipped with every
    /// sidebar row unclickable. Both are documented to work in a normal
    /// SwiftUI `Scene`, but this window isn't one: it's a bare `NSWindow`
    /// with an `NSHostingController` rootView, built imperatively in
    /// `AppDelegate.showPreferences()`, and `List`'s selection plumbing
    /// leans on AppKit responder/first-responder wiring that a `Scene` sets
    /// up for free and this hosting path apparently doesn't. A `Button`
    /// closure has no such dependency — it either fires or it doesn't, so
    /// there's nothing left to debug blind if it ever regresses again.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                pane(for: category ?? .general)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        // `maxWidth`/`maxHeight: .infinity` alongside the floor, not just a
        // floor alone: `NSHostingController` sizes the window to this view's
        // *ideal* size, and a `minWidth`-only frame still reports a smaller
        // ideal width for whichever pane's content happens to need less
        // horizontal room — General's five-item radio-group picker list is
        // wider than Typography's controls, so switching from one to the
        // other could visibly shrink the window (dragging the fixed-width
        // sidebar's own space down with it) instead of the window staying
        // exactly as wide as the user left it. `maxWidth: .infinity` makes
        // this view's ideal size "however big the window already is" rather
        // than something content can shrink out from under.
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .jotShowSettingsPane)) { note in
            guard let pane = note.object as? SettingsCategory else { return }
            category = pane
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { item in
                sidebarRow(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: 172)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarRow(_ item: SettingsCategory) -> some View {
        let isSelected = (category ?? .general) == item
        return Button {
            category = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .frame(width: 16)
                Text(item.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func pane(for category: SettingsCategory) -> some View {
        switch category {
        case .general: generalPane
        case .appearance: appearancePane
        case .typography: typographyPane
        case .notesAndTimers: notesAndTimersPane
        case .privacy: privacyPane
        case .shortcuts: shortcutsPane
        }
    }

    // MARK: - General

    private var generalPane: some View {
        Form {
            Section("Display") {
                Picker("Mode", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.displayMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.displayMode.isEdgeDocked {
                    Picker("Edge", selection: $settings.screenEdge) {
                        ForEach(ScreenEdge.allCases) { edge in
                            Text(edge.title).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)

                    HStack(spacing: 12) {
                        Text("Width")
                            .font(.caption)
                        Slider(value: $settings.edgeWidth, in: 240...600)
                            .frame(width: 140)
                        Text("\(Int(settings.edgeWidth))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }

            Section("Shortcut") {
                HStack(spacing: 12) {
                    HotKeyRecorder(combo: $settings.hotKey)
                    Button("Reset") { settings.hotKey = .default }
                        .disabled(settings.hotKey == .default)
                }
                Text("Shows and hides the note from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance

    private var appearancePane: some View {
        Form {
            Section("Paper") {
                Picker("Paper", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                Text(settings.appearance.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.themeOverride != nil {
                    Text("A theme note is controlling the look. These picks take over again when that note stops being one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if GlassTint.applies(to: settings.appearance) {
                    HStack(spacing: 12) {
                        Text("Tint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(GlassTint.allCases) { tint in
                            tintSwatch(tint)
                        }
                    }
                }

                Picker("Guides", selection: $settings.guide) {
                    ForEach(PaperGuide.allCases) { guide in
                        Text(guide.title).tag(guide)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)
            }

            Section("Chrome") {
                Toggle("Show the header bar", isOn: $settings.showsHeader)
                Toggle("Show word count and selection totals", isOn: $settings.showsFooter)
                Text("Cmd+/ toggles both at once from anywhere in the note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text("Line spacing")
                        .font(.caption)
                    Slider(value: $settings.lineSpacing, in: 1.0...2.2)
                        .frame(width: 140)
                    Text(String(format: "%.1f", settings.lineSpacing))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Typography

    private var typographyPane: some View {
        Form {
            Section("This note") {
                Text("Applies only to the note you have open right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Picker("Font", selection: currentFontName) {
                        ForEach(NoteFont.all, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)

                    if notesManager.currentFontName != nil {
                        Button("Reset") { notesManager.currentFontName = nil }
                            .help("Go back to the built-in default font for this note")
                    }
                }

                HStack(spacing: 12) {
                    Text("Size")
                        .font(.caption)
                    Slider(value: currentFontSize, in: SettingsManager.fontSizeRange, step: 1)
                        .frame(width: 140)
                    Text("\(Int(currentFontSize.wrappedValue))pt")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)

                    if notesManager.currentFontSize != nil {
                        Button("Reset") { notesManager.currentFontSize = nil }
                            .help("Go back to the built-in default size for this note")
                    }
                }
            }

            Section("Default for new notes") {
                HStack(spacing: 12) {
                    Picker("Font", selection: $settings.noteFontName) {
                        ForEach(NoteFont.all, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)

                    // The size reads as its own label, and the Stepper is
                    // left bare with `labelsHidden()`. A *titled* Stepper
                    // inside a grouped `Form` claims the form's label column
                    // and lays itself out across the row's full width, and
                    // the `.fixedSize()` this used to carry then pinned that
                    // spread-out width as non-negotiable: this one row
                    // reported a 742pt minimum, so the whole pane demanded
                    // 915pt inside a 620pt window and the fixed-width
                    // sidebar was compressed to a 25pt sliver with no row
                    // left under the cursor. That made Settings a dead end
                    // on this pane, escapable only by resizing the window.
                    // Measured: with this section alone the pane needs
                    // 915pt; with either other section alone, 620pt.
                    // Covered by `tests/ui/SettingsWindowTests.swift`.
                    Text("\(Int(settings.noteFontSize))pt")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Stepper(
                        "",
                        value: $settings.noteFontSize,
                        in: SettingsManager.fontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                }
            }

            Section("Spacing") {
                HStack(spacing: 12) {
                    Text("Letter spacing")
                        .font(.caption)
                    Slider(value: $settings.letterSpacing, in: 0...3)
                        .frame(width: 140)
                    Text(String(format: "%.1f", settings.letterSpacing))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notes & Timers

    private var notesAndTimersPane: some View {
        Form {
            Section("Keywords") {
                LabeledContent("List") {
                    TextField("list", text: $settings.listKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
                Text("First line \"\(settings.effectiveListKeyword)\" makes the note a checklist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Code") {
                    TextField("code", text: $settings.codeKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
                Text("First line \"\(settings.effectiveCodeKeyword)\" renders the note as monospaced code. Checklists, headings, highlights, links, and math stay switched off inside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Timer") {
                    TextField("timer", text: $settings.timerKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
                Text("e.g. \"5m \(settings.effectiveTimerKeyword)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Pomodoro") {
                    TextField("pomodoro", text: $settings.pomodoroKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
                Text("e.g. \"\(settings.effectivePomodoroKeyword) 25/5\" — work minutes, then break minutes. Fires the celebration below at the end of each half, then starts the next one automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Celebration") {
                Picker("Confetti", selection: $settings.celebrationStyle) {
                    ForEach(CelebrationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)

                Text(settings.celebrationStyle.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Sound", selection: $settings.timerSound) {
                    ForEach(CelebrationSound.allCases) { sound in
                        Text(sound.title).tag(sound)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts

    /// A reference list, not yet a remapping surface — every combo below is
    /// fixed in code (`PlainTextEditor.performKeyEquivalent`,
    /// `MainMenu.swift`) and chosen to avoid colliding with standard macOS
    /// editing shortcuts (Cut/Copy/Paste/Undo/Redo/Select All, which just
    /// work and aren't listed here). The one exception is the global
    /// show/hide hotkey at the top, which already has its own recorder — it
    /// has to be user-choosable since it needs to work system-wide,
    /// including when some other app owns whatever combo Jot shipped with.
    private var shortcutsPane: some View {
        Form {
            Section("Global") {
                HStack(spacing: 12) {
                    Text("Show or hide Jot from anywhere")
                        .font(.caption)
                    Spacer()
                    HotKeyRecorder(combo: $settings.hotKey)
                    Button("Reset") { settings.hotKey = .default }
                        .disabled(settings.hotKey == .default)
                }
            }

            Section("Notes") {
                ShortcutRow(action: "New note", combo: "⌘N")
                ShortcutRow(action: "Next note", combo: "⌘⌥→")
                ShortcutRow(action: "Previous note", combo: "⌘⌥←")
                ShortcutRow(action: "Move note up", combo: "⌃⌘↑")
                ShortcutRow(action: "Move note down", combo: "⌃⌘↓")
                ShortcutRow(action: "Close / hide", combo: "⌘W")
            }

            Section("Formatting") {
                ShortcutRow(action: "Toggle checklist", combo: "⌘L")
                ShortcutRow(action: "Toggle highlight", combo: "⇧⌘H")
                ShortcutRow(action: "Nest / un-nest checklist item", combo: "⇥ / ⇧⇥")
                ShortcutRow(action: "Read clipboard image as text (OCR)", combo: "⇧⌘V")
            }

            Section("Search") {
                ShortcutRow(action: "Find in this note", combo: "⌘F")
                ShortcutRow(action: "Search every note", combo: "⇧⌘F")
                ShortcutRow(action: "Find next / previous", combo: "⌘G / ⇧⌘G")
                ShortcutRow(action: "Use selection for find", combo: "⌘E")
            }

            Section("View") {
                ShortcutRow(action: "Toggle header & footer", combo: "⌘/")
            }

            Section("App") {
                ShortcutRow(action: "Settings", combo: "⌘,")
                ShortcutRow(action: "Hide Jot", combo: "⌘H")
                ShortcutRow(action: "Quit", combo: "⌘Q")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Privacy & Sync

    private var privacyPane: some View {
        Form {
            Section("Network") {
                Toggle("Fetch live currency exchange rates", isOn: $settings.fetchesLiveCurrencyRates)
                Text("Off by default: the only network request this app can make. On, it checks a public rate API once a day; off, conversions use the last cached rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Automatically check for app updates", isOn: $settings.checksForUpdates)
                Text("Checks GitHub once a day for a newer release. No note content or identifying information is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Apple Notes") {
                Toggle("Sync notes to an Apple Notes folder", isOn: $settings.syncsToAppleNotes)
                Text("Pushes each note into a \"Jot\" folder in Apple Notes. One direction only — edits made there are not read back. macOS will ask for permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// One circular swatch in the tint row. The fill is the wash at four
    /// times its on-paper opacity so it reads at swatch size. "None" stays
    /// empty with a dashed ring — a filled grey disc would read as its own
    /// colour choice rather than the absence of one.
    private func tintSwatch(_ tint: GlassTint) -> some View {
        let isSelected = settings.glassTint == tint
        let ringStyle = StrokeStyle(
            lineWidth: isSelected ? 2 : 1,
            dash: tint == .none && !isSelected ? [2, 2] : []
        )
        return Button {
            settings.glassTint = tint
        } label: {
            Circle()
                .fill(tint.overlayColor.map { Color(nsColor: $0).opacity(tint.overlayOpacity * 4) } ?? .clear)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: ringStyle
                    )
                )
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(tint.title)
        .accessibilityLabel(tint.title)
    }
}

/// One row in the Shortcuts reference list: what it does, and the fixed
/// combo that does it, styled like a keycap.
private struct ShortcutRow: View {
    let action: String
    let combo: String

    var body: some View {
        HStack {
            Text(action)
                .font(.caption)
            Spacer()
            Text(combo)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)
        }
    }
}

/// Records a global shortcut by consuming the next keystroke.
///
/// A local NSEvent monitor is enough here and avoids a custom-drawn NSView: the
/// Settings window is key while recording, so the keystroke reaches us.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(isRecording ? "Press a shortcut…" : combo.displayString)
                .font(.system(.body, design: .monospaced))
                .frame(width: 150)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press any combination, or Escape to cancel" : "Click to change the shortcut")
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        NotificationCenter.default.post(name: .jotBeginHotKeyRecording, object: nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let modifiers = KeyCombo.carbonModifiers(from: event.modifierFlags.rawValue)
            // A bare key would swallow ordinary typing system-wide.
            guard modifiers != 0 else {
                NSSound.beep()
                return nil
            }

            combo = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        NotificationCenter.default.post(name: .jotEndHotKeyRecording, object: nil)
    }
}
