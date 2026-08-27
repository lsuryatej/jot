import Foundation

/// A wall-clock reminder found in note text, e.g. "remind 3pm" or "remind
/// tomorrow 9am" — distinct from `TimerDirective`, which counts down from
/// now. A reminder fires at a specific point on the clock instead.
struct ReminderDirective: Equatable {
    /// The exact matched line, trimmed. Used the same way
    /// `TimerDirective.source` is: to tell "this exact directive is already
    /// scheduled" apart from "the note changed somewhere unrelated."
    let source: String
    let fireDate: Date

    /// "Today at 3:00 PM", "Tomorrow at 9:00 AM", "Fri, Sep 4 at 10:00 AM" —
    /// what a confirmation toast shows right after a reminder directive is
    /// recognized, so a mistyped time or date is obvious immediately rather
    /// than only at the moment it fires, when it's too late to just retype
    /// it.
    static func friendlyDescription(for fireDate: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        func formatter(_ pattern: String) -> DateFormatter {
            let formatter = DateFormatter()
            // Matching the same calendar/timezone the "which day is this"
            // comparisons below use, rather than each formatter defaulting
            // to the system's own — the two must agree, or a caller passing
            // a non-default calendar (every test in this file) sees a
            // "Today"/"Tomorrow" label paired with a time computed in a
            // different timezone than the one that decided it was today.
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            return formatter
        }
        let time = formatter("h:mm a")

        if calendar.isDate(fireDate, inSameDayAs: now) {
            return "Today at \(time.string(from: fireDate))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(fireDate, inSameDayAs: tomorrow) {
            return "Tomorrow at \(time.string(from: fireDate))"
        }

        let dayAndDate = formatter("EEE, MMM d")
        return "\(dayAndDate.string(from: fireDate)) at \(time.string(from: fireDate))"
    }
}

/// Parses `remind <phrase>` lines into concrete fire dates.
///
/// Kept free of AppKit/SwiftUI and of any implicit "now", matching
/// `Checklist`/`Heading`/`OrderedList`/`CodeBlock`: every entry point takes
/// `now` and `calendar` explicitly, so a test can pin both and get a
/// deterministic answer instead of a flaky one keyed to the wall clock the
/// suite happens to run under.
///
/// Grammar (case-insensitive, one directive per line, keyword must start the
/// line):
///   - `remind in <N> <unit>` — relative, `unit` one of
///     second(s)/sec(s)/s, minute(s)/min(s)/m, hour(s)/hr(s)/h, day(s)/d,
///     week(s)/w.
///   - `remind [today|tomorrow|[next] <weekday>] [at] <time>` — absolute.
///     `<time>` is `H[:MM]am/pm`, `HH:MM` (24-hour), `noon`, or `midnight`.
///     A bare hour with no am/pm and no colon (e.g. a lone "9") is rejected
///     rather than guessed at.
///
/// With no day given, a time already passed today rolls to tomorrow rather
/// than firing immediately. An explicit "today" that has already passed is
/// rejected outright instead of silently becoming "tomorrow" — the one place
/// this parser refuses text rather than reinterpreting it, since "today"
/// stops meaning what it says the moment it's allowed to mean tomorrow.
/// A bare weekday name means its next occurrence, rolling a week forward if
/// that weekday's time has already passed today; "next <weekday>" always
/// adds one more week on top of that.
extension ReminderDirective {
    /// Every reminder directive found in `text`, in the order they appear.
    /// Duplicate identical lines are folded into one directive — a real
    /// limitation, not an oversight: nothing about the matched text
    /// distinguishes two literally identical lines from each other, the same
    /// trade `firstTimerDirective` already makes by only ever tracking one
    /// occurrence at all. Unlike a timer, every *distinct* line here becomes
    /// its own reminder rather than one directive taking over a shared slot.
    static func directives(
        in text: String,
        keyword: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ReminderDirective] {
        let keyword = keyword.trimmingCharacters(in: .whitespaces)
        let effectiveKeyword = keyword.isEmpty ? "remind" : keyword
        guard let regex = lineRegex(keyword: effectiveKeyword) else { return [] }

        let ns = text as NSString
        var results: [ReminderDirective] = []
        var seenSources = Set<String>()

        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let source = ns.substring(with: match.range(at: 0)).trimmingCharacters(in: .whitespaces)
            guard !seenSources.contains(source) else { return }
            let phrase = ns.substring(with: match.range(at: 1))
            guard let fireDate = parseTimePhrase(phrase, now: now, calendar: calendar) else { return }
            seenSources.insert(source)
            results.append(ReminderDirective(source: source, fireDate: fireDate))
        }
        return results
    }

    // MARK: - Line matching

    private static var patternCache: [String: NSRegularExpression] = [:]
    private static let patternCacheLock = NSLock()

    private static func lineRegex(keyword: String) -> NSRegularExpression? {
        patternCacheLock.lock()
        defer { patternCacheLock.unlock() }
        if let cached = patternCache[keyword] { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        guard let regex = try? NSRegularExpression(
            pattern: "^[ \\t]*" + escaped + "[ \\t]+(.+?)[ \\t]*$",
            options: [.caseInsensitive, .anchorsMatchLines]
        ) else { return nil }
        patternCache[keyword] = regex
        return regex
    }

    // MARK: - Phrase parsing

    static func parseTimePhrase(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let phrase = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !phrase.isEmpty else { return nil }
        if let relative = parseRelative(phrase, now: now) { return relative }
        return parseAbsolute(phrase, now: now, calendar: calendar)
    }

    private static let relativeRegex = try! NSRegularExpression(
        pattern: "^in\\s+(\\d+)\\s*([a-z]+)$"
    )

    private static func parseRelative(_ phrase: String, now: Date) -> Date? {
        let ns = phrase as NSString
        guard let match = relativeRegex.firstMatch(in: phrase, range: NSRange(location: 0, length: ns.length)),
              let amount = Int(ns.substring(with: match.range(at: 1))), amount > 0,
              let unitSeconds = secondsPerUnit(ns.substring(with: match.range(at: 2)))
        else { return nil }
        return now.addingTimeInterval(TimeInterval(amount) * unitSeconds)
    }

    private static func secondsPerUnit(_ raw: String) -> TimeInterval? {
        switch raw {
        case "s", "sec", "secs", "second", "seconds": return 1
        case "m", "min", "mins", "minute", "minutes": return 60
        case "h", "hr", "hrs", "hour", "hours": return 3600
        case "d", "day", "days": return 86400
        case "w", "week", "weeks": return 604_800
        default: return nil
        }
    }

    /// Weekday numbers match `Calendar.component(.weekday, from:)`: 1 =
    /// Sunday ... 7 = Saturday.
    private static let weekdayNames: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    private static let dayPartRegex = try! NSRegularExpression(
        pattern: "^(next\\s+)?(today|tomorrow|sunday|sun|monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat)\\s+(.*)$"
    )
    private static let atPrefixRegex = try! NSRegularExpression(pattern: "^at\\s+(.*)$")

    private static func parseAbsolute(_ phrase: String, now: Date, calendar: Calendar) -> Date? {
        var remainder = phrase
        var dayPart: String?
        var isNext = false

        let ns0 = phrase as NSString
        if let match = dayPartRegex.firstMatch(in: phrase, range: NSRange(location: 0, length: ns0.length)) {
            isNext = match.range(at: 1).location != NSNotFound
            dayPart = ns0.substring(with: match.range(at: 2))
            remainder = ns0.substring(with: match.range(at: 3))
        }

        let ns1 = remainder as NSString
        if let match = atPrefixRegex.firstMatch(in: remainder, range: NSRange(location: 0, length: ns1.length)) {
            remainder = ns1.substring(with: match.range(at: 1))
        }

        guard let time = parseTimeOfDay(remainder) else { return nil }

        var dayOnly: Date
        switch dayPart {
        case nil:
            dayOnly = now
        case "today":
            dayOnly = now
        case "tomorrow":
            dayOnly = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        default:
            guard let weekday = weekdayNames[dayPart!] else { return nil }
            dayOnly = nextDate(forWeekday: weekday, onOrAfter: now, calendar: calendar)
        }

        var comps = calendar.dateComponents([.year, .month, .day], from: dayOnly)
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = 0
        guard var result = calendar.date(from: comps) else { return nil }

        if dayPart == "today" {
            // Explicit "today" that has already passed is refused, not
            // rolled forward — see the type doc.
            guard result > now else { return nil }
        } else if dayPart == nil {
            if result <= now {
                result = calendar.date(byAdding: .day, value: 1, to: result) ?? result
            }
        } else if dayPart != "tomorrow" {
            // A weekday: if the computed moment has already passed (only
            // possible when today itself is that weekday), move a week out.
            if result <= now {
                result = calendar.date(byAdding: .day, value: 7, to: result) ?? result
            }
            if isNext {
                result = calendar.date(byAdding: .day, value: 7, to: result) ?? result
            }
        }

        return result
    }

    private static func nextDate(forWeekday weekday: Int, onOrAfter date: Date, calendar: Calendar) -> Date {
        var candidate = date
        var steps = 0
        while calendar.component(.weekday, from: candidate) != weekday, steps < 8 {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            steps += 1
        }
        return candidate
    }

    private static let amPmRegex = try! NSRegularExpression(
        pattern: "^(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)$"
    )
    private static let twentyFourHourRegex = try! NSRegularExpression(
        pattern: "^(\\d{1,2}):(\\d{2})$"
    )

    private static func parseTimeOfDay(_ raw: String) -> (hour: Int, minute: Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "noon" { return (12, 0) }
        if s == "midnight" { return (0, 0) }
        guard !s.isEmpty else { return nil }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let match = amPmRegex.firstMatch(in: s, range: full) {
            guard var hour = Int(ns.substring(with: match.range(at: 1))), hour >= 1, hour <= 12 else { return nil }
            var minute = 0
            if match.range(at: 2).location != NSNotFound {
                guard let mm = Int(ns.substring(with: match.range(at: 2))), mm < 60 else { return nil }
                minute = mm
            }
            let meridiem = ns.substring(with: match.range(at: 3))
            if meridiem == "am" {
                if hour == 12 { hour = 0 }
            } else if hour != 12 {
                hour += 12
            }
            return (hour, minute)
        }

        if let match = twentyFourHourRegex.firstMatch(in: s, range: full) {
            guard let hour = Int(ns.substring(with: match.range(at: 1))), hour <= 23,
                  let minute = Int(ns.substring(with: match.range(at: 2))), minute < 60
            else { return nil }
            return (hour, minute)
        }

        return nil
    }
}
