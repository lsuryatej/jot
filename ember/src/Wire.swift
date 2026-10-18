import Foundation

// Everything that crosses the wire between the two Macs. ntfy only ever sees
// the sealed form of an `Envelope` (see `PairSecret`), so none of this is
// readable on the server.
//
// Raw values and case names are the wire format: renaming one breaks pings
// between an old and a new build, so add cases, never rename them.

/// How strongly a ping lands.
enum Level: String, Codable, CaseIterable, Identifiable {
    case missYou, spicy, spicier, fire

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .missYou: "💛"
        case .spicy: "🌶️"
        case .spicier: "🌶️🌶️"
        case .fire: "🔥"
        }
    }

    /// Used when the sender hasn't written their own wording. Kept tame on
    /// purpose: it shows on a lock screen and in a screen share.
    func defaultLabel(together: Bool) -> String {
        switch self {
        case .missYou: "Miss you"
        case .spicy: "Thinking about you"
        case .spicier: "In the mood"
        case .fire: together ? "Come find me." : "Call me. Now."
        }
    }

    /// A built-in macOS sound per level, so you can tell them apart without
    /// looking. Names are from /System/Library/Sounds.
    var sound: String {
        switch self {
        case .missYou: "Purr"
        case .spicy: "Pop"
        case .spicier: "Funk"
        case .fire: "Hero"
        }
    }
}

/// An answer to a ping. Distance replies are about getting on a call; together
/// replies are about getting out of the room.
enum Reply: String, Codable, CaseIterable, Identifiable {
    case faceTime, giveMe20, same, rainCheck
    case onMyWay, afterThis, notNow

    var id: String { rawValue }

    static let distance: [Reply] = [.faceTime, .giveMe20, .same, .rainCheck]
    static let together: [Reply] = [.onMyWay, .afterThis, .notNow]

    static func options(together: Bool) -> [Reply] { together ? Self.together : distance }

    var text: String {
        switch self {
        case .faceTime: "📞 FaceTime now"
        case .giveMe20: "⏳ Give me 20"
        case .same: "😏 Same"
        case .rainCheck: "🌧️ Rain check"
        case .onMyWay: "👀 On my way"
        case .afterThis: "⏳ After this"
        case .notNow: "🌧️ Not now"
        }
    }

    /// What the person who sent the ping is told. Different from `text`
    /// where the button label would read oddly as a notification.
    var incomingText: String {
        switch self {
        case .faceTime: "📞 FaceTiming you now"
        default: text
        }
    }

    /// Minutes until both Macs nudge, for the "give me a bit" replies.
    var timerMinutes: Int? {
        switch self {
        case .giveMe20: 20
        default: nil
        }
    }

    /// A "no" lands quietly. Nobody needs a sound effect for a rain check.
    var isDecline: Bool { self == .rainCheck || self == .notNow }
}

/// Quiet hours as minutes after local midnight. `start > end` wraps past
/// midnight, which is the usual case (01:00 to 08:00 is not, 23:00 to 07:00 is).
struct QuietHours: Codable, Equatable {
    var start: Int
    var end: Int

    static let `default` = QuietHours(start: 60, end: 8 * 60)

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard start != end else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end
            ? (minute >= start && minute < end)
            : (minute >= start || minute < end)
    }

    /// When the quiet stretch containing (or following) `date` ends.
    func endDate(after date: Date, calendar: Calendar = .current) -> Date {
        let match = DateComponents(hour: end / 60, minute: end % 60)
        return calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime) ?? date
    }
}

/// A visit, by calendar day. Both ends are inclusive: a 12 to 15 Nov visit is
/// four days together.
struct VisitPlan: Codable, Equatable {
    var start: Date
    var end: Date
}

/// The shared visit, with the time it was last changed. Whichever Mac changed
/// it last wins, and clearing it is a change too (`plan == nil`), so a cleared
/// visit can't be resurrected by the other Mac's stale copy.
struct VisitState: Codable, Equatable {
    var plan: VisitPlan?
    var updatedAt: Date

    static let empty = VisitState(plan: nil, updatedAt: .distantPast)
}

/// One person's side of the shared state, sent whenever it changes.
struct Snapshot: Codable, Equatable {
    var name: String
    var busyUntil: Date?
    var away: Bool
    var presenceAt: Date
    var quietHours: QuietHours?
    var visit: VisitState
}

enum Payload: Codable, Equatable {
    /// `label` is the sender's own wording for this level, or nil for the
    /// default. It travels with the ping so they read what you wrote.
    case ping(Level, label: String?)
    case reply(Reply, to: UUID)
    /// Sent automatically when a ping reaches the other Mac: the "✓✓".
    case received(UUID)
    /// `wantsReply` asks the other Mac to send its own snapshot back. Sent on
    /// launch, so a Mac that was off for a day catches up on the other's
    /// state, which ntfy only keeps for 12 hours.
    case snapshot(Snapshot, wantsReply: Bool)
}

struct Envelope: Codable, Equatable {
    var id: UUID
    /// The sending install, so a Mac can drop its own messages when ntfy
    /// echoes them back.
    var from: UUID
    var sentAt: Date
    var payload: Payload
}

/// Dates go over as Foundation's own Double, not milliseconds: it round-trips
/// exactly, so a message decodes equal to what was sent.
enum Wire {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
