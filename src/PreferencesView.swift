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
}

struct PreferencesView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
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
                Picker("", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                Text(settings.appearance.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
        .frame(width: 480, height: 900, alignment: .topLeading)
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
