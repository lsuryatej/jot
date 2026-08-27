import Foundation

// Coverage for wall-clock reminders: the pure parser in
// ReminderDirective.swift, and NotesManager's scheduling/cancelling of them
// through a fake `ReminderScheduling` — the real `SystemReminderScheduler`
// touches `UNUserNotificationCenter`, which needs a real app bundle and a
// user-facing authorization prompt this swiftc-only binary has neither of.

final class SpyReminderScheduler: ReminderScheduling {
    struct ScheduledCall: Equatable {
        let identifier: String
        let fireDate: Date
        let title: String
        let body: String
    }

    private(set) var scheduled: [ScheduledCall] = []
    private(set) var cancelled: [String] = []

    func schedule(identifier: String, fireDate: Date, title: String, body: String) {
        scheduled.append(ScheduledCall(identifier: identifier, fireDate: fireDate, title: title, body: body))
    }

    func cancel(identifiers: [String]) {
        cancelled.append(contentsOf: identifiers)
    }
}

/// A fixed reference point so every test is deterministic regardless of when
/// the suite actually runs: Wednesday 2026-08-26, 14:30:00 UTC.
private func referenceNow(calendar: Calendar) -> Date {
    var comps = DateComponents()
    comps.year = 2026
    comps.month = 8
    comps.day = 26
    comps.hour = 14
    comps.minute = 30
    comps.second = 0
    return calendar.date(from: comps)!
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// Renders the requested fields of `date` as a space-joined string, so a
/// test can assert against one readable literal instead of chaining
/// force-unwraps through nested Optionals.
private func describe(_ date: Date?, _ calendar: Calendar, _ fields: [Calendar.Component]) -> String {
    guard let date else { return "nil" }
    let c = calendar.dateComponents(Set(fields), from: date)
    return fields.map { field -> String in
        switch field {
        case .day: return "\(c.day ?? -1)"
        case .hour: return "\(c.hour ?? -1)"
        case .minute: return "\(c.minute ?? -1)"
        case .weekday: return "\(c.weekday ?? -1)"
        default: return "?"
        }
    }.joined(separator: " ")
}

func runReminderDirectiveTests() {
    let calendar = utcCalendar()
    let now = referenceNow(calendar: calendar) // Wed 2026-08-26 14:30 UTC

    suite("reminder: relative phrases") {
        equal(ReminderDirective.parseTimePhrase("in 30 minutes", now: now, calendar: calendar),
              now.addingTimeInterval(30 * 60), "in 30 minutes")
        equal(ReminderDirective.parseTimePhrase("in 2 hours", now: now, calendar: calendar),
              now.addingTimeInterval(2 * 3600), "in 2 hours")
        equal(ReminderDirective.parseTimePhrase("in 1 day", now: now, calendar: calendar),
              now.addingTimeInterval(86400), "in 1 day")
        equal(ReminderDirective.parseTimePhrase("IN 45s", now: now, calendar: calendar),
              now.addingTimeInterval(45), "compact unit, case-insensitive")

        check(ReminderDirective.parseTimePhrase("in 0 minutes", now: now, calendar: calendar) == nil,
              "a zero amount is rejected, not treated as \"immediately\"")
        check(ReminderDirective.parseTimePhrase("in soon", now: now, calendar: calendar) == nil,
              "no amount at all")
    }

    suite("reminder: bare time today or tomorrow") {
        // now is 14:30 UTC.
        equal(describe(ReminderDirective.parseTimePhrase("3pm", now: now, calendar: calendar), calendar, [.day, .hour, .minute]),
              "26 15 0", "a time still ahead today stays today")
        equal(describe(ReminderDirective.parseTimePhrase("9am", now: now, calendar: calendar), calendar, [.day, .hour]),
              "27 9", "a time already passed today rolls to tomorrow")
        equal(describe(ReminderDirective.parseTimePhrase("3:45pm", now: now, calendar: calendar), calendar, [.hour, .minute]),
              "15 45", "hour and minute with am/pm")
        equal(describe(ReminderDirective.parseTimePhrase("15:00", now: now, calendar: calendar), calendar, [.day, .hour]),
              "26 15", "24-hour clock form")
    }

    suite("reminder: noon and midnight") {
        // now is 14:30, so noon (12:00) has already passed today.
        equal(describe(ReminderDirective.parseTimePhrase("noon", now: now, calendar: calendar), calendar, [.day, .hour]),
              "27 12", "noon already passed today rolls to tomorrow")
        equal(describe(ReminderDirective.parseTimePhrase("midnight", now: now, calendar: calendar), calendar, [.hour]),
              "0", "midnight means 00:00")
    }

    suite("reminder: explicit today / tomorrow") {
        equal(describe(ReminderDirective.parseTimePhrase("today 3pm", now: now, calendar: calendar), calendar, [.day, .hour]),
              "26 15", "explicit today, still ahead")

        check(ReminderDirective.parseTimePhrase("today 9am", now: now, calendar: calendar) == nil,
              "explicit today that has already passed is refused outright, not rolled to tomorrow")

        let tomorrow = ReminderDirective.parseTimePhrase("tomorrow 9am", now: now, calendar: calendar)
        equal(describe(tomorrow, calendar, [.day, .hour]), "27 9", "explicit tomorrow, any time of day")

        let tomorrowAt = ReminderDirective.parseTimePhrase("tomorrow at 9am", now: now, calendar: calendar)
        equal(tomorrowAt, tomorrow, "\"at\" is optional")
    }

    suite("reminder: weekdays") {
        // now is Wednesday 2026-08-26 (weekday 4).
        equal(describe(ReminderDirective.parseTimePhrase("friday 10am", now: now, calendar: calendar), calendar, [.weekday, .day]),
              "6 28", "the coming Friday (weekday 6), two days out")

        // Wednesday itself, a time still ahead today.
        equal(describe(ReminderDirective.parseTimePhrase("wednesday 6pm", now: now, calendar: calendar), calendar, [.day]),
              "26", "today's own weekday with a time still ahead means today")

        // Wednesday, but a time already past today rolls a full week out (Sept 2).
        equal(describe(ReminderDirective.parseTimePhrase("wednesday 9am", now: now, calendar: calendar), calendar, [.day]),
              "2", "today's own weekday with a time already past rolls a full week")

        // "next friday" skips the coming one (Aug 28) and lands the week after (Sept 4).
        equal(describe(ReminderDirective.parseTimePhrase("next friday 10am", now: now, calendar: calendar), calendar, [.day]),
              "4", "\"next\" always adds one more week on top of the bare weekday")

        check(ReminderDirective.parseTimePhrase("someday 3pm", now: now, calendar: calendar) == nil,
              "not a real day word")
    }

    suite("reminder: rejects unparseable time shapes") {
        check(ReminderDirective.parseTimePhrase("9", now: now, calendar: calendar) == nil,
              "a bare hour with no am/pm and no colon is ambiguous, rejected")
        check(ReminderDirective.parseTimePhrase("25:00", now: now, calendar: calendar) == nil,
              "hour out of range")
        check(ReminderDirective.parseTimePhrase("3:99pm", now: now, calendar: calendar) == nil,
              "minute out of range")
        check(ReminderDirective.parseTimePhrase("13pm", now: now, calendar: calendar) == nil,
              "hour out of 12-hour range")
        check(ReminderDirective.parseTimePhrase("", now: now, calendar: calendar) == nil, "empty phrase")
    }

    suite("reminder: friendlyDescription phrases the confirmation toast") {
        let calendar = utcCalendar()
        var todayLater = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        todayLater.hour = 18
        todayLater.minute = 0
        let laterToday = calendar.date(from: todayLater)!
        equal(ReminderDirective.friendlyDescription(for: laterToday, now: now, calendar: calendar),
              "Today at 6:00 PM", "same calendar day reads as \"Today\"")

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: laterToday)!
        equal(ReminderDirective.friendlyDescription(for: tomorrow, now: now, calendar: calendar),
              "Tomorrow at 6:00 PM", "the next calendar day reads as \"Tomorrow\"")

        let nextWeek = calendar.date(byAdding: .day, value: 8, to: now)!
        var comps = calendar.dateComponents([.year, .month, .day], from: nextWeek)
        comps.hour = 10
        comps.minute = 0
        let farOut = calendar.date(from: comps)!
        equal(ReminderDirective.friendlyDescription(for: farOut, now: now, calendar: calendar),
              "Thu, Sep 3 at 10:00 AM", "anything further out names the weekday and date")
    }

    suite("reminder: directives(in:keyword:) finds every line, dedupes identical ones") {
        let text = "remind 3pm\nsome other line\nremind tomorrow 9am"
        let found = ReminderDirective.directives(in: text, keyword: "remind", now: now, calendar: calendar)
        equal(found.count, 2, "two distinct reminder lines")
        equal(found.first?.source, "remind 3pm", "first source captured verbatim")
        equal(found.last?.source, "remind tomorrow 9am", "second source captured verbatim")

        let withDuplicate = ReminderDirective.directives(
            in: "remind 3pm\nremind 3pm", keyword: "remind", now: now, calendar: calendar
        )
        equal(withDuplicate.count, 1, "two identical lines fold into one directive")

        let unrelated = ReminderDirective.directives(in: "buy milk\nremind whenever", keyword: "remind", now: now, calendar: calendar)
        equal(unrelated.count, 0, "an unparseable phrase after the keyword yields nothing")

        let caseInsensitive = ReminderDirective.directives(in: "REMIND 3pm", keyword: "remind", now: now, calendar: calendar)
        equal(caseInsensitive.count, 1, "keyword matches case-insensitively")

        let midLine = ReminderDirective.directives(in: "please remind 3pm", keyword: "remind", now: now, calendar: calendar)
        equal(midLine.count, 0, "the keyword must start the line, like list/theme/code")

        let customKeyword = ReminderDirective.directives(in: "ping 3pm", keyword: "ping", now: now, calendar: calendar)
        equal(customKeyword.count, 1, "a configured keyword other than the default")
    }
}

func runReminderNotesManagerTests() {
    suite("NotesManager: a new reminder directive schedules exactly once") {
        let scheduler = SpyReminderScheduler()
        let manager = makeManager(reminderScheduler: scheduler)
        manager.currentText = "remind in 30 minutes"
        equal(scheduler.scheduled.count, 1, "one notification scheduled")
        equal(scheduler.scheduled.first?.body, "remind in 30 minutes", "body carries the directive text")

        // Editing something unrelated in the same note must not reschedule.
        manager.currentText = "remind in 30 minutes\nbuy milk"
        equal(scheduler.scheduled.count, 1, "still just the one — retyping the same directive doesn't reschedule")
    }

    suite("NotesManager: a new reminder publishes a confirmation message") {
        let scheduler = SpyReminderScheduler()
        let manager = makeManager(reminderScheduler: scheduler)
        check(manager.reminderConfirmation == nil, "nothing to confirm before any directive exists")

        manager.currentText = "remind in 10 minutes"
        check(manager.reminderConfirmation?.hasPrefix("Reminder set for") == true,
              "a single new directive gets a plain-language confirmation: \(manager.reminderConfirmation ?? "nil")")

        // Retyping the same, already-scheduled directive is not a new
        // confirmation-worthy event — evaluateReminders only publishes one
        // for genuinely new sources, matching what it schedules.
        manager.reminderConfirmation = nil
        manager.currentText = "remind in 10 minutes\nbuy milk"
        check(manager.reminderConfirmation == nil, "no fresh confirmation for text that didn't add a new directive")
    }

    suite("NotesManager: multiple reminders stack instead of replacing each other") {
        let scheduler = SpyReminderScheduler()
        let manager = makeManager(reminderScheduler: scheduler)
        manager.currentText = "remind in 10 minutes\nremind in 2 hours"
        equal(scheduler.scheduled.count, 2, "both lines scheduled independently")
        check(scheduler.cancelled.isEmpty, "neither cancels the other — unlike the shared timer slot")
    }

    suite("NotesManager: removing a reminder line cancels its notification") {
        let scheduler = SpyReminderScheduler()
        let manager = makeManager(reminderScheduler: scheduler)
        manager.currentText = "remind in 10 minutes"
        let identifier = scheduler.scheduled.first?.identifier
        manager.currentText = "nothing here now"
        equal(scheduler.cancelled, identifier.map { [$0] } ?? [], "the exact identifier that was scheduled gets cancelled")
    }

    suite("NotesManager: deleting the note cancels its pending reminders") {
        let scheduler = SpyReminderScheduler()
        let manager = makeManager(reminderScheduler: scheduler)
        manager.currentText = "remind in 10 minutes"
        equal(scheduler.scheduled.count, 1, "scheduled once")
        manager.deleteNote(at: 0)
        equal(scheduler.cancelled.count, 1, "cancelled on delete, not left dangling for a note that no longer exists")
    }

    suite("NotesManager: a note loaded from a previous session is seeded, not re-scheduled") {
        let scheduler = SpyReminderScheduler()
        // Seed the store directly, as if this text was saved in a prior run.
        let manager = makeManager(seed: ["remind in 10 minutes"], reminderScheduler: scheduler)
        equal(scheduler.scheduled.count, 0,
              "existing directive text is recorded as already seen on first display, never (re)scheduled just for being loaded")

        // Editing something else in the same note still must not schedule it now.
        manager.currentText = "remind in 10 minutes\nanother line"
        equal(scheduler.scheduled.count, 0, "the pre-existing directive stays inert")
    }

    suite("NotesManager: changing the reminder keyword stops recognizing the old one") {
        let scheduler = SpyReminderScheduler()
        let manager = makeManager(reminderScheduler: scheduler)
        manager.currentText = "remind in 10 minutes"
        equal(scheduler.scheduled.count, 1, "scheduled under the original keyword")

        manager.reminderKeywordDidChange(to: "ping")
        manager.currentText = "remind in 10 minutes\nping in 5 minutes"
        equal(scheduler.scheduled.count, 2, "\"ping in 5 minutes\" is newly recognized under the new keyword")
        check(scheduler.scheduled.last?.body == "ping in 5 minutes", "the new keyword's directive is the one just scheduled")
    }
}
