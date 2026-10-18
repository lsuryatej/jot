import SwiftUI
import AppKit

/// The popover under the menu bar icon.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @State private var page: Page = .home

    enum Page {
        case home, visit, settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pair == nil {
                PairingView(model: model)
            } else {
                switch page {
                case .home: HomeView(model: model, page: $page)
                case .visit: VisitView(model: model, page: $page)
                case .settings: SettingsView(model: model, page: $page)
                }
            }
        }
        .padding(16)
        .frame(width: 330)
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var model: AppModel
    @Binding var page: MenuView.Page
    @State private var refusal: String?

    var body: some View {
        // Ticks every second while the menu is open, for the cooldown and
        // "busy until" lines; the popover isn't rendered when closed.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let engine = model.engine
        let phase = engine.phase(at: now)
        return VStack(alignment: .leading, spacing: 14) {
            header(engine, now: now)
            if engine.state.partner == nil, let pair = model.pair {
                waitingCard(pair)
            }
            visitCard(engine, phase: phase)
            if let open = engine.openPing(at: now) {
                replyCard(open, engine, together: phase.isTogether)
            }
            pingGrid(engine, now: now, together: phase.isTogether)
            recent(engine, now: now)
            footer(engine, now: now)
        }
    }

    private func header(_ engine: Engine, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(dotColor(engine, now: now)).frame(width: 8, height: 8)
                Text(engine.partnerName).font(.headline)
                Spacer()
                connectionBadge
            }
            Text(presenceLine(engine, now: now))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var connectionBadge: some View {
        if model.unsent > 0 {
            Text("\(model.unsent) waiting to send").font(.caption).foregroundStyle(.orange)
        } else if model.connection == .connecting {
            Text("Connecting…").font(.caption).foregroundStyle(.secondary)
        } else if model.connection == .offline {
            Text("Offline").font(.caption).foregroundStyle(.orange)
        }
    }

    private func dotColor(_ engine: Engine, now: Date) -> Color {
        guard let partner = engine.state.partner else { return .gray }
        if engine.partnerBusyUntil(at: now) != nil { return .orange }
        if engine.partnerIsQuiet(at: now) { return .purple }
        return partner.away ? .gray : .green
    }

    private func presenceLine(_ engine: Engine, now: Date) -> String {
        guard let partner = engine.state.partner else { return "Hasn't joined yet" }
        if let until = engine.partnerBusyUntil(at: now) {
            return "Busy until \(engine.clock(until)). Pings wait till then."
        }
        if engine.partnerIsQuiet(at: now) {
            return "😴 Quiet hours. Pings arrive silently."
        }
        if partner.away {
            return "Away from their Mac · " + relative(partner.presenceAt, now: now)
        }
        return "At their Mac"
    }

    private func waitingCard(_ pair: PairSecret) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for them to join").font(.subheadline.weight(.semibold))
            Text("Send them this link. Opening it on their Mac (or pasting the code into Ember) pairs you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy link") { copyToPasteboard(pair.link) }
                Button("Copy code") { copyToPasteboard(pair.code) }
            }
        }
        .card()
    }

    private func visitCard(_ engine: Engine, phase: VisitPhase) -> some View {
        Button {
            page = .visit
        } label: {
            HStack {
                Text(visitText(engine, phase: phase)).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }

    private func visitText(_ engine: Engine, phase: VisitPhase) -> String {
        switch phase {
        case .none:
            return "✈️ Set the next visit"
        case .upcoming(let days):
            let range = engine.state.visit.plan.map { engine.dayRange($0) } ?? ""
            return days == 1 ? "✈️ Tomorrow! · \(range)" : "✈️ \(days) days to go · \(range)"
        case .together(let day, let total):
            return "🫶 Together · day \(day) of \(total)"
        case .comedown:
            return "💛 Back to long distance. Set the next one?"
        }
    }

    private func replyCard(_ open: PingMark, _ engine: Engine, together: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(engine.partnerName) sent \(open.level.emoji) at \(engine.clock(open.at))")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(Reply.options(together: together)) { reply in
                    Button(reply.text) { model.reply(reply, to: open.id) }
                        .buttonStyle(.bordered)
                }
            }
            Text("Or ping back within 15 minutes for a match.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func pingGrid(_ engine: Engine, now: Date, together: Bool) -> some View {
        let wait = Int(engine.cooldownRemaining(at: now).rounded(.up))
        return VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Level.allCases) { level in
                    Button {
                        refusal = model.send(level)
                    } label: {
                        VStack(spacing: 4) {
                            Text(level.emoji).font(.system(size: 22))
                            Text(engine.customLabel(for: level) ?? level.defaultLabel(together: together))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 6)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PingButtonStyle())
                    .disabled(wait > 0)
                }
            }
            if wait > 0 {
                Text("Sent. Next one in \(wait)s.").font(.caption).foregroundStyle(.secondary)
            } else if let refusal {
                Text(refusal).font(.caption).foregroundStyle(.orange)
            } else if let note = sendNote(engine, now: now) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sendNote(_ engine: Engine, now: Date) -> String? {
        if let until = engine.partnerBusyUntil(at: now) {
            return "They'll see it at \(engine.clock(until))."
        }
        if engine.partnerIsQuiet(at: now) {
            return "It'll arrive without a sound."
        }
        if engine.state.settings.hotKey != .off {
            return "\(engine.state.settings.hotKey.display) sends \(engine.state.settings.hotKeyLevel.emoji) from anywhere."
        }
        return nil
    }

    @ViewBuilder private func recent(_ engine: Engine, now: Date) -> some View {
        let entries = Array(engine.state.history.suffix(4).reversed())
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Text(entry.kind == .match ? "Both" : (entry.fromMe ? "You" : engine.partnerName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 60, alignment: .leading)
                        Text(entry.text).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        if entry.fromMe && entry.kind == .ping {
                            Text(entry.reachedAt == nil ? "✓" : "✓✓")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(entry.reachedAt == nil ? "Sent" : "Reached their Mac")
                        }
                        Text(engine.clock(entry.at)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                let stats = engine.weekStats(at: now)
                Text("This week: \(stats.pings) pings · \(stats.matches) matches")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func footer(_ engine: Engine, now: Date) -> some View {
        HStack {
            Menu {
                Button("1 hour") { model.setBusy(for: 60) }
                Button("3 hours") { model.setBusy(for: 180) }
                Button("Until 9 am") { model.setBusyUntilMorning() }
                if engine.busyUntil(at: now) != nil {
                    Divider()
                    Button("I'm free") { model.clearBusy() }
                }
            } label: {
                if let until = engine.busyUntil(at: now) {
                    Text("🌙 Busy till \(engine.clock(until))")
                } else {
                    Text("🌙 Busy…")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button {
                page = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Ember")
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) < 30 * 24 * 3600 else { return "a while ago" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct PingButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(configuration.isPressed ? 0.35 : 0.15))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: - Visit

struct VisitView: View {
    @ObservedObject var model: AppModel
    @Binding var page: MenuView.Page
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3 * 24 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Next visit").font(.headline)
            Text("Both Macs count down to it. On the days you're together, pings become quiet signals: no sound, just the menu bar icon glowing. The day after, Ember switches back to long distance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Arrive", selection: $start, displayedComponents: .date)
            DatePicker("Leave", selection: $end, in: start..., displayedComponents: .date)
            HStack {
                Button("Back") { page = .home }
                Spacer()
                if model.state.visit.plan != nil {
                    Button("Clear", role: .destructive) {
                        model.setVisit(nil)
                        page = .home
                    }
                }
                Button("Save") {
                    let calendar = Calendar.current
                    let first = calendar.startOfDay(for: start)
                    let last = calendar.startOfDay(for: max(start, end))
                    model.setVisit(VisitPlan(start: first, end: last))
                    page = .home
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            if let plan = model.state.visit.plan {
                start = plan.start
                end = plan.end
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var page: MenuView.Page
    @State private var draft = Settings()
    @State private var confirmUnpair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Cancel") { page = .home }
                Button("Save") {
                    model.updateSettings(draft)
                    page = .home
                }
                .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("You") {
                        TextField("Your name (they see this)", text: $draft.myName)
                        TextField("Their FaceTime email or phone", text: $draft.partnerHandle)
                    }
                    section("What your pings say") {
                        ForEach(Level.allCases) { level in
                            HStack {
                                Text(level.emoji).frame(width: 36, alignment: .leading)
                                TextField(level.defaultLabel(together: false), text: labelBinding(level))
                            }
                        }
                        Text("Leave blank for the default. They read exactly what you write here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    section("Notifications") {
                        Toggle("Discreet: show only the emoji", isOn: $draft.discreet)
                        Toggle("Quiet hours: no sound", isOn: $draft.quietHoursOn)
                        if draft.quietHoursOn {
                            HStack {
                                Picker("From", selection: $draft.quietHours.start) { timeOptions }
                                Picker("to", selection: $draft.quietHours.end) { timeOptions }
                            }
                        }
                        Button("Send me a test notification") { model.sendTestNotification() }
                    }
                    section("Shortcut") {
                        Picker("Hotkey", selection: $draft.hotKey) {
                            ForEach(HotKeyChoice.allCases) { Text($0.display).tag($0) }
                        }
                        Picker("Sends", selection: $draft.hotKeyLevel) {
                            ForEach(Level.allCases) { level in
                                Text(level.emoji + " " + level.defaultLabel(together: false)).tag(level)
                            }
                        }
                        Toggle("Open Ember at login", isOn: Binding(
                            get: { model.launchesAtLogin },
                            set: { model.setLaunchesAtLogin($0) }
                        ))
                    }
                    section("Pair") {
                        HStack {
                            Button("Copy pair link") {
                                if let pair = model.pair { copyToPasteboard(pair.link) }
                            }
                            Spacer()
                            Button("Unpair…", role: .destructive) { confirmUnpair = true }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.trailing, 6)
            }
            .frame(height: 430)
        }
        .onAppear { draft = model.state.settings }
        .confirmationDialog("Unpair from \(model.engine.partnerName)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) {
                model.unpair()
                page = .home
            }
        } message: {
            Text("Ember stops listening and forgets the pair. You'll need a fresh code to connect again.")
        }
    }

    private var timeOptions: some View {
        ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { minute in
            Text(String(format: "%02d:%02d", minute / 60, minute % 60)).tag(minute)
        }
    }

    private func labelBinding(_ level: Level) -> Binding<String> {
        Binding(
            get: { draft.labels[level.rawValue] ?? "" },
            set: { draft.labels[level.rawValue] = $0 }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Pairing

struct PairingView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var code = ""
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ember").font(.title2.weight(.semibold))
            Text("A private signal between two Macs. Pair once, then one click tells them you're thinking about them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("First of you to set up").font(.subheadline.weight(.semibold))
                Button("Create a pair") {
                    saveName()
                    model.createPair()
                }
                .disabled(trimmedName.isEmpty)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Got a code from them?").font(.subheadline.weight(.semibold))
                TextField("Paste the code or link", text: $code)
                    .textFieldStyle(.roundedBorder)
                Button("Join") {
                    saveName()
                    if !model.join(code: code) {
                        error = "That code doesn't look right. Copy it again?"
                    }
                }
                .disabled(trimmedName.isEmpty || code.isEmpty)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
        }
        .onAppear { name = model.state.settings.myName }
    }

    private func saveName() {
        var settings = model.state.settings
        settings.myName = trimmedName
        model.updateSettings(settings)
    }
}

// MARK: - Bits

extension View {
    func card() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
