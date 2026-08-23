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
}

struct PreferencesView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        // The window is resizable down to a short strip, so the form scrolls
        // rather than clipping.
        ScrollView {
            settingsSections
        }
    }

    private var settingsSections: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Display") {
                Picker("", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(settings.displayMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.displayMode.isEdgeDocked {
                    HStack(spacing: 12) {
                        Picker("Edge", selection: $settings.screenEdge) {
                            ForEach(ScreenEdge.allCases) { edge in
                                Text(edge.title).tag(edge)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)

                        Text("Width")
                            .font(.caption)
                        Slider(value: $settings.edgeWidth, in: 240...600)
                            .frame(width: 120)
                        Text("\(Int(settings.edgeWidth))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }
            }

            Divider()

            section("Appearance") {
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

                Toggle("Show the header bar", isOn: $settings.showsHeader)

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

            Divider()

            section("Typography") {
                Picker("Font", selection: $settings.noteFontName) {
                    ForEach(NoteFont.all, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                HStack(spacing: 12) {
                    Text("Size")
                        .font(.caption)
                    Slider(value: $settings.noteFontSize, in: SettingsManager.fontSizeRange, step: 1)
                        .frame(width: 140)
                    Text("\(Int(settings.noteFontSize))pt")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }

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

            Divider()

            section("Shortcut") {
                HStack(spacing: 12) {
                    HotKeyRecorder(combo: $settings.hotKey)
                    Button("Reset") { settings.hotKey = .default }
                        .disabled(settings.hotKey == .default)
                }
                Text("Shows and hides the note from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            section("List keyword") {
                HStack(spacing: 12) {
                    TextField("list", text: $settings.listKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("First line \"\(settings.effectiveListKeyword)\" makes the note a checklist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            section("Timer keyword") {
                HStack(spacing: 12) {
                    TextField("timer", text: $settings.timerKeyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("e.g. \"5m \(settings.effectiveTimerKeyword)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            section("Timer celebration") {
                Picker("Confetti", selection: $settings.celebrationStyle) {
                    ForEach(CelebrationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)

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
                .frame(width: 220)
            }

            Divider()

            Toggle("Show word count and selection totals", isOn: $settings.showsFooter)

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

            Divider()

            Toggle("Sync notes to an Apple Notes folder", isOn: $settings.syncsToAppleNotes)
            Text("Pushes each note into a \"Jot\" folder in Apple Notes. One direction only — edits made there are not read back. macOS will ask for permission the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
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
