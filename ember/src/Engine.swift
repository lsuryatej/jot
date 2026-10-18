import Foundation

// The whole app's behaviour, minus the I/O. `Engine` takes what happened (you
// pressed a button, a message arrived, a minute passed) and returns what
// should happen next as `Effect`s. AppModel carries those out. Keeping it
// free of AppKit and networking is what lets tests drive two engines against
// each other with a fake clock.

/// A notification to show. The sound is played by the app rather than by
/// Notification Center, so each level can have its own.
struct Alert: Equatable {
    enum Category: String {
        case pingDistance = "ping.distance"
        case pingTogether = "ping.together"
        case call
    }

    var id: String
    var title: String
    var body: String
    var category: Category? = nil
    var sound: String? = nil
    var pingID: UUID? = nil
}

enum Effect: Equatable {
    case publish(Envelope)
    case notify(Alert)
    case schedule(Alert, at: Date)
    /// Make the menu bar icon glow: the across-the-room signal.
    case signal
    case startFaceTime
}

enum SendRefusal: Error, Equatable {
    case coolingDown(seconds: Int)
}

enum HotKeyChoice: String, Codable, CaseIterable, Identifiable {
    case off, controlOptionE, controlOptionCommandE, optionShiftE

    var id: String { rawValue }

    var display: String {
        switch self {
        case .off: "Off"
        case .controlOptionE: "⌃⌥E"
        case .controlOptionCommandE: "⌃⌥⌘E"
        case .optionShiftE: "⌥⇧E"
        }
    }
}

struct Settings: Codable, Equatable {
    var myName = ""
    /// The other person's FaceTime address: an email or phone number.
    var partnerHandle = ""
    /// Your own wording per level, keyed by `Level.rawValue`. It travels with
    /// the ping, so what you write here is what they read.
    var labels: [String: String] = [:]
    var quietHoursOn = true
    var quietHours = QuietHours.default
    /// Notifications show only the emoji, for screen shares and nosy friends.
    var discreet = false
    var hotKey = HotKeyChoice.controlOptionE
    var hotKeyLevel = Level.spicy
}

struct PingMark: Codable, Equatable {
    var id: UUID
    var level: Level
    var at: Date
    var matched: Bool
}

struct HistoryEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case ping, reply, match }

    var id: UUID
    var at: Date
    var fromMe: Bool
    var kind: Kind
    var text: String
    /// When the other Mac confirmed it arrived. Only set on your own pings.
    var reachedAt: Date? = nil
}

struct EngineState: Codable, Equatable {
    var settings = Settings()
    var busyUntil: Date?
    var away = false
    var presenceAt = Date.distantPast
    var visit = VisitState.empty
    var partner: Snapshot?
    /// When the snapshot in `partner` was sent. A queued message flushed
    /// after a reconnect can arrive after a newer one; older ones are ignored.
    var partnerAt: Date?
    var lastSent: PingMark?
    var lastReceived: PingMark?
    var repliedTo: UUID?
    /// Pings that arrived while you were busy, shown together when it ends.
    var held: [PingMark] = []
    var history: [HistoryEntry] = []
    var seen: [UUID] = []
    /// One-off visit notices already shown ("tomorrow!", "together mode on").
    var announced: [String] = []
}

enum VisitPhase: Equatable {
    case none
    case upcoming(days: Int)
    case together(day: Int, of: Int)
    /// The day after a visit ends.
    case comedown

    var isTogether: Bool {
        if case .together = self { return true }
        return false
    }

    static func of(_ plan: VisitPlan?, at now: Date, calendar: Calendar) -> VisitPhase {
        guard let plan else { return .none }
        let today = calendar.startOfDay(for: now)
        let first = calendar.startOfDay(for: plan.start)
        let last = calendar.startOfDay(for: max(plan.start, plan.end))
        let days = { (from: Date, to: Date) in calendar.dateComponents([.day], from: from, to: to).day ?? 0 }

        let untilStart = days(today, first)
        if untilStart > 0 { return .upcoming(days: untilStart) }
        let sinceEnd = days(last, today)
        if sinceEnd <= 0 { return .together(day: days(first, today) + 1, of: days(first, last) + 1) }
        return sinceEnd == 1 ? .comedown : .none
    }
}

final class Engine {
    private(set) var state: EngineState
    let deviceID: UUID
    var calendar: Calendar

    /// Long enough to stop a held-down hotkey from sending ten pings.
    static let cooldown: TimeInterval = 60
    /// Two pings this close together, one each way, are a match.
    static let matchWindow: TimeInterval = 15 * 60
    /// Older than this on arrival (the Mac was asleep) and a ping is news,
    /// not a call to action: it shows quietly and can't make a match.
    static let staleAfter: TimeInterval = 10 * 60
    /// How long a ping stays answerable from the menu.
    static let openFor: TimeInterval = 60 * 60
    static let historyLimit = 200
    static let seenLimit = 500

    init(state: EngineState = EngineState(), deviceID: UUID, calendar: Calendar = .current) {
        self.state = state
        self.deviceID = deviceID
        self.calendar = calendar
    }

    // MARK: - Reading

    var partnerName: String {
        let name = state.partner?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Them" : name
    }

    func phase(at now: Date) -> VisitPhase {
        .of(state.visit.plan, at: now, calendar: calendar)
    }

    /// Your own words for a level, or nil to let the receiver use the default.
    func customLabel(for level: Level) -> String? {
        let text = (state.settings.labels[level.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }

    /// How a ping reads, with the emoji in front.
    func text(for level: Level, label: String?, together: Bool) -> String {
        level.emoji + " " + (label ?? level.defaultLabel(together: together))
    }

    func snapshot(at now: Date) -> Snapshot {
        Snapshot(
            name: state.settings.myName,
            busyUntil: busyUntil(at: now),
            away: state.away,
            presenceAt: state.presenceAt,
            quietHours: state.settings.quietHoursOn ? state.settings.quietHours : nil,
            visit: state.visit
        )
    }

    func busyUntil(at now: Date) -> Date? {
        guard let until = state.busyUntil, until > now else { return nil }
        return until
    }

    func partnerBusyUntil(at now: Date) -> Date? {
        guard let until = state.partner?.busyUntil, until > now else { return nil }
        return until
    }

    /// Both of you are on IST, so their quiet hours are checked against this
    /// Mac's clock.
    func partnerIsQuiet(at now: Date) -> Bool {
        state.partner?.quietHours?.contains(now, calendar: calendar) ?? false
    }

    func isQuiet(at now: Date) -> Bool {
        state.settings.quietHoursOn && state.settings.quietHours.contains(now, calendar: calendar)
    }

    func cooldownRemaining(at now: Date) -> TimeInterval {
        guard let last = state.lastSent else { return 0 }
        return max(0, Self.cooldown - now.timeIntervalSince(last.at))
    }

    /// Their latest ping, if it's recent and you haven't answered it yet.
    func openPing(at now: Date) -> PingMark? {
        guard let ping = state.lastReceived,
              !ping.matched,
              state.repliedTo != ping.id,
              now.timeIntervalSince(ping.at) < Self.openFor
        else { return nil }
        return ping
    }

    func weekStats(at now: Date) -> (pings: Int, matches: Int) {
        let recent = state.history.filter { now.timeIntervalSince($0.at) < 7 * 24 * 3600 }
        return (recent.filter { $0.kind == .ping }.count, recent.filter { $0.kind == .match }.count)
    }

    // MARK: - Things you do

    func send(_ level: Level, at now: Date) throws -> [Effect] {
        let wait = cooldownRemaining(at: now)
        guard wait <= 0 else { throw SendRefusal.coolingDown(seconds: Int(wait.rounded(.up))) }

        let together = phase(at: now).isTogether
        let label = customLabel(for: level)
        let envelope = makeEnvelope(.ping(level, label: label), at: now)
        record(HistoryEntry(id: envelope.id, at: now, fromMe: true, kind: .ping, text: text(for: level, label: label, together: together)))
        state.lastSent = PingMark(id: envelope.id, level: level, at: now, matched: false)

        var effects: [Effect] = [.publish(envelope)]
        if var theirs = state.lastReceived, !theirs.matched, now.timeIntervalSince(theirs.at) <= Self.matchWindow {
            theirs.matched = true
            state.lastReceived = theirs
            state.lastSent?.matched = true
            effects += match(mine: level, theirs: theirs.level, together: together, at: now)
        }
        return effects
    }

    func reply(_ reply: Reply, to pingID: UUID, at now: Date) -> [Effect] {
        let envelope = makeEnvelope(.reply(reply, to: pingID), at: now)
        record(HistoryEntry(id: envelope.id, at: now, fromMe: true, kind: .reply, text: reply.text))
        state.repliedTo = pingID

        var effects: [Effect] = [.publish(envelope)]
        if let minutes = reply.timerMinutes {
            effects += timer(minutes: minutes, for: pingID, from: now, at: now)
        }
        if reply == .faceTime {
            effects.append(.startFaceTime)
        }
        return effects
    }

    /// Sent on launch: here's my state, send me yours.
    func hello(at now: Date) -> [Effect] {
        state.away = false
        state.presenceAt = now
        return [publishSnapshot(at: now, wantsReply: true)]
    }

    func setBusy(until: Date?, at now: Date) -> [Effect] {
        state.busyUntil = until
        var effects: [Effect] = []
        if busyUntil(at: now) == nil {
            state.busyUntil = nil
            effects += releaseHeld(at: now)
        }
        effects.append(publishSnapshot(at: now))
        return effects
    }

    func setAway(_ away: Bool, at now: Date) -> [Effect] {
        guard state.away != away else { return [] }
        state.away = away
        state.presenceAt = now
        return [publishSnapshot(at: now)]
    }

    func setVisit(_ plan: VisitPlan?, at now: Date) -> [Effect] {
        state.visit = VisitState(plan: plan, updatedAt: now)
        return [publishSnapshot(at: now)] + visitNotices(at: now)
    }

    func updateSettings(_ settings: Settings, at now: Date) -> [Effect] {
        let before = snapshot(at: now)
        state.settings = settings
        return snapshot(at: now) == before ? [] : [publishSnapshot(at: now)]
    }

    // MARK: - Things that happen

    func receive(_ envelope: Envelope, at now: Date) -> [Effect] {
        guard envelope.from != deviceID, !state.seen.contains(envelope.id) else { return [] }
        state.seen.append(envelope.id)
        if state.seen.count > Self.seenLimit { state.seen.removeFirst(state.seen.count - Self.seenLimit) }

        switch envelope.payload {
        case .ping(let level, let label):
            return receivePing(envelope, level: level, label: label, at: now)
        case .reply(let reply, let pingID):
            return receiveReply(envelope, reply: reply, to: pingID, at: now)
        case .received(let pingID):
            if let index = state.history.lastIndex(where: { $0.id == pingID }) {
                state.history[index].reachedAt = envelope.sentAt
            }
            return []
        case .snapshot(let snapshot, let wantsReply):
            return receiveSnapshot(snapshot, sentAt: envelope.sentAt, wantsReply: wantsReply, at: now)
        }
    }

    /// Called every half minute or so: ends a busy stretch that has run out
    /// and shows the visit milestones.
    func tick(at now: Date) -> [Effect] {
        var effects: [Effect] = []
        if let until = state.busyUntil, until <= now {
            state.busyUntil = nil
            effects += releaseHeld(at: now)
            effects.append(publishSnapshot(at: now))
        }
        return effects + visitNotices(at: now)
    }

    // MARK: - Receiving

    private func receivePing(_ envelope: Envelope, level: Level, label: String?, at now: Date) -> [Effect] {
        let stale = now.timeIntervalSince(envelope.sentAt) > Self.staleAfter
        let together = phase(at: now).isTogether
        let body = text(for: level, label: label.map { String($0.prefix(80)) }, together: together)

        record(HistoryEntry(id: envelope.id, at: envelope.sentAt, fromMe: false, kind: .ping, text: body))
        let mark = PingMark(id: envelope.id, level: level, at: envelope.sentAt, matched: false)
        state.lastReceived = mark

        var effects: [Effect] = [.publish(makeEnvelope(.received(envelope.id), at: now))]

        if busyUntil(at: now) != nil {
            state.held.append(mark)
            return effects
        }

        if !stale, var mine = state.lastSent, !mine.matched,
           abs(envelope.sentAt.timeIntervalSince(mine.at)) <= Self.matchWindow {
            mine.matched = true
            state.lastSent = mine
            state.lastReceived?.matched = true
            return effects + match(mine: mine.level, theirs: level, together: together, at: now)
        }

        var alert = Alert(
            id: envelope.id.uuidString,
            title: partnerName,
            body: body,
            category: together ? .pingTogether : .pingDistance,
            sound: (together || isQuiet(at: now)) ? nil : level.sound,
            pingID: envelope.id
        )
        if stale {
            alert.title = partnerName + ", earlier"
            alert.body = body + " · " + clock(envelope.sentAt)
            alert.sound = nil
        }
        if state.settings.discreet {
            alert.title = "Ember"
            alert.body = level.emoji
        }
        effects.append(.notify(alert))
        if !stale { effects.append(.signal) }
        return effects
    }

    private func receiveReply(_ envelope: Envelope, reply: Reply, to pingID: UUID, at now: Date) -> [Effect] {
        let stale = now.timeIntervalSince(envelope.sentAt) > Self.staleAfter
        let together = phase(at: now).isTogether
        record(HistoryEntry(id: envelope.id, at: envelope.sentAt, fromMe: false, kind: .reply, text: reply.incomingText))

        let quiet = stale || together || reply.isDecline || isQuiet(at: now)
        var alert = Alert(
            id: envelope.id.uuidString,
            title: partnerName,
            body: reply.incomingText,
            category: reply == .faceTime && !together ? .call : nil,
            sound: quiet ? nil : (reply == .faceTime ? "Glass" : "Tink"),
            pingID: pingID
        )
        if stale { alert.body += " · " + clock(envelope.sentAt) }

        var effects: [Effect] = [.notify(alert)]
        if !stale && !reply.isDecline { effects.append(.signal) }
        if let minutes = reply.timerMinutes {
            effects += timer(minutes: minutes, for: pingID, from: envelope.sentAt, at: now)
        }
        return effects
    }

    private func receiveSnapshot(_ snapshot: Snapshot, sentAt: Date, wantsReply: Bool, at now: Date) -> [Effect] {
        var effects: [Effect] = []
        let theirVisitIsNewer = snapshot.visit.updatedAt > state.visit.updatedAt
        if theirVisitIsNewer {
            let changed = snapshot.visit.plan != state.visit.plan
            state.visit = snapshot.visit
            if changed { effects.append(.notify(visitChangedAlert(snapshot.visit.plan))) }
        }
        if sentAt >= (state.partnerAt ?? .distantPast) {
            state.partner = snapshot
            state.partnerAt = sentAt
        }

        // A Mac that has been off sends an old visit; answering with ours is
        // what brings it up to date.
        let ourVisitIsNewer = state.visit.updatedAt > snapshot.visit.updatedAt
        if wantsReply || ourVisitIsNewer {
            effects.append(publishSnapshot(at: now))
        }
        return effects + visitNotices(at: now)
    }

    // MARK: - Pieces

    private func match(mine: Level, theirs: Level, together: Bool, at now: Date) -> [Effect] {
        let tender = mine == .missYou && theirs == .missYou
        let body: String
        if tender {
            body = "💛 You were thinking of each other at the same time."
        } else if together {
            body = "🔥 It's mutual. Find each other."
        } else {
            body = "🔥 It's mutual. Call them."
        }
        record(HistoryEntry(id: UUID(), at: now, fromMe: false, kind: .match, text: tender ? "💛 Match" : "🔥 Match"))

        var alert = Alert(
            id: "match-" + UUID().uuidString,
            title: "It's a match",
            body: body,
            category: (tender || together) ? nil : .call,
            sound: (together || isQuiet(at: now)) ? nil : "Glass"
        )
        if state.settings.discreet {
            alert.title = "Ember"
            alert.body = tender ? "💛💛" : "🔥🔥"
        }
        return [.notify(alert), .signal]
    }

    private func timer(minutes: Int, for pingID: UUID, from start: Date, at now: Date) -> [Effect] {
        let due = start.addingTimeInterval(TimeInterval(minutes * 60))
        guard due > now else { return [] }
        let together = phase(at: due).isTogether
        let alert = Alert(
            id: "timer-" + pingID.uuidString,
            title: "⏰ Time's up",
            body: together ? "\(minutes) minutes are up. 👀" : "\(minutes) minutes are up. Call?",
            category: together ? nil : .call,
            sound: "Glass"
        )
        return [.schedule(alert, at: due)]
    }

    private func releaseHeld(at now: Date) -> [Effect] {
        guard !state.held.isEmpty else { return [] }
        let held = state.held
        state.held = []
        let list = held.map { "\($0.level.emoji) \(clock($0.at))" }.joined(separator: ", ")
        let together = phase(at: now).isTogether
        return [.notify(Alert(
            id: "held-" + UUID().uuidString,
            title: "While you were busy",
            body: state.settings.discreet ? list : "\(partnerName): \(list)",
            category: together ? .pingTogether : .pingDistance,
            pingID: held.last?.id
        ))]
    }

    private func visitNotices(at now: Date) -> [Effect] {
        guard let plan = state.visit.plan, !isQuiet(at: now) else { return [] }
        let stamp = "\(Int(plan.start.timeIntervalSince1970))-\(Int(plan.end.timeIntervalSince1970))"
        let notice: (key: String, alert: Alert)
        switch phase(at: now) {
        case .upcoming(days: 1):
            notice = ("eve-" + stamp, Alert(id: "eve-" + stamp, title: "✈️ Tomorrow", body: "You see \(partnerName) tomorrow."))
        case .together(day: 1, of: _):
            notice = ("start-" + stamp, Alert(id: "start-" + stamp, title: "🫶 Together mode", body: "Pings turn into quiet signals until the visit ends. Have fun."))
        case .comedown:
            notice = ("end-" + stamp, Alert(id: "end-" + stamp, title: "💛 Back to long distance", body: "Miss them already? Set the next visit from the menu bar."))
        default:
            return []
        }
        guard !state.announced.contains(notice.key) else { return [] }
        state.announced.append(notice.key)
        if state.announced.count > 30 { state.announced.removeFirst(state.announced.count - 30) }
        return [.notify(notice.alert)]
    }

    private func visitChangedAlert(_ plan: VisitPlan?) -> Alert {
        guard let plan else {
            return Alert(id: "visit-" + UUID().uuidString, title: partnerName, body: "Cleared the next visit.")
        }
        return Alert(id: "visit-" + UUID().uuidString, title: partnerName, body: "✈️ Visit set: \(dayRange(plan))")
    }

    func dayRange(_ plan: VisitPlan) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        let start = formatter.string(from: plan.start)
        let end = formatter.string(from: plan.end)
        return calendar.isDate(plan.start, inSameDayAs: plan.end) ? start : "\(start) to \(end)"
    }

    func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func publishSnapshot(at now: Date, wantsReply: Bool = false) -> Effect {
        .publish(makeEnvelope(.snapshot(snapshot(at: now), wantsReply: wantsReply), at: now))
    }

    private func makeEnvelope(_ payload: Payload, at now: Date) -> Envelope {
        Envelope(id: UUID(), from: deviceID, sentAt: now, payload: payload)
    }

    private func record(_ entry: HistoryEntry) {
        state.history.append(entry)
        if state.history.count > Self.historyLimit {
            state.history.removeFirst(state.history.count - Self.historyLimit)
        }
    }
}

// Decoding that tolerates fields a newer build added or an older one never
// wrote, so an update never throws away pairing, settings, or history.
// In extensions so the memberwise initialisers survive.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension Settings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        self.init(
            myName: c.value(.myName, or: d.myName),
            partnerHandle: c.value(.partnerHandle, or: d.partnerHandle),
            labels: c.value(.labels, or: d.labels),
            quietHoursOn: c.value(.quietHoursOn, or: d.quietHoursOn),
            quietHours: c.value(.quietHours, or: d.quietHours),
            discreet: c.value(.discreet, or: d.discreet),
            hotKey: c.value(.hotKey, or: d.hotKey),
            hotKeyLevel: c.value(.hotKeyLevel, or: d.hotKeyLevel)
        )
    }
}

extension EngineState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        settings = c.value(.settings, or: settings)
        busyUntil = try? c.decodeIfPresent(Date.self, forKey: .busyUntil)
        away = c.value(.away, or: away)
        presenceAt = c.value(.presenceAt, or: presenceAt)
        visit = c.value(.visit, or: visit)
        partner = try? c.decodeIfPresent(Snapshot.self, forKey: .partner)
        partnerAt = try? c.decodeIfPresent(Date.self, forKey: .partnerAt)
        lastSent = try? c.decodeIfPresent(PingMark.self, forKey: .lastSent)
        lastReceived = try? c.decodeIfPresent(PingMark.self, forKey: .lastReceived)
        repliedTo = try? c.decodeIfPresent(UUID.self, forKey: .repliedTo)
        held = c.value(.held, or: held)
        history = c.value(.history, or: history)
        seen = c.value(.seen, or: seen)
        announced = c.value(.announced, or: announced)
    }
}
