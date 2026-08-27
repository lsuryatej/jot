import Foundation
import UserNotifications

/// What `NotesManager` needs from a reminder backend: schedule one, or
/// cancel some. Kept as a protocol so the logic that decides *which*
/// reminders are new or removed (in `NotesManager`) stays testable without
/// ever touching `UNUserNotificationCenter`, which needs a real app bundle
/// and user interaction (an authorization prompt) neither this project's
/// swiftc-only test binary nor a headless run has.
protocol ReminderScheduling {
    func schedule(identifier: String, fireDate: Date, title: String, body: String)
    func cancel(identifiers: [String])
}

/// Schedules wall-clock reminders as real macOS notifications. A pending
/// `UNNotificationRequest` is owned by the system, not this process — it
/// fires at its clock time whether or not Jot is running, the same guarantee
/// any other app's local notifications get, which is the entire point of a
/// reminder over the existing countdown timer.
///
/// Authorization is requested lazily, the first time anyone actually types a
/// `remind` directive, rather than at launch: this is the first permission
/// prompt for a feature that touches no network at all, and asking only when
/// the feature is used keeps that consistent with the rest of the app's
/// privacy stance (see BACKLOG.md).
final class SystemReminderScheduler: ReminderScheduling {
    private var didRequestAuthorization = false

    func schedule(identifier: String, fireDate: Date, title: String, body: String) {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        // Adding a request with an identifier that is already pending
        // replaces it — exactly what's wanted when the same directive text
        // is re-evaluated (e.g. after a relaunch) rather than a duplicate.
        UNUserNotificationCenter.current().add(request)
    }

    func cancel(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
