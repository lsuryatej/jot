import Foundation
import UserNotifications

/// Every reminder notification's identifier starts with this, so the
/// `UNUserNotificationCenterDelegate` in `AppDelegate` can tell "this is one
/// of ours, fire the in-app celebration too" apart from any other
/// notification without needing to ask `NotesManager` anything.
let reminderIdentifierPrefix = "jot-reminder-"

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
    /// The previous version called `UNUserNotificationCenter.add(_:)`
    /// immediately after firing off `requestAuthorization` without waiting
    /// for either to actually resolve — so a request could reach `add`
    /// before the user had answered the permission prompt at all, and
    /// `add`'s completion was never even checked, meaning a `.denied`
    /// answer (or any other failure — a malformed trigger, anything) failed
    /// completely silently. Reported directly as "reminder still not
    /// working" with nothing else to go on, which is exactly what a silent
    /// failure looks like from the outside. Every path below now either
    /// schedules for real or explains why not, out loud.
    func schedule(identifier: String, fireDate: Date, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.add(identifier: identifier, fireDate: fireDate, title: title, body: body, to: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        NSLog("Jot: reminder authorization request failed: \(error.localizedDescription)")
                    }
                    guard granted else {
                        NotificationCenter.default.post(name: .jotReminderNotAuthorized, object: nil)
                        return
                    }
                    Self.add(identifier: identifier, fireDate: fireDate, title: title, body: body, to: center)
                }
            case .denied:
                NotificationCenter.default.post(name: .jotReminderNotAuthorized, object: nil)
            @unknown default:
                NotificationCenter.default.post(name: .jotReminderNotAuthorized, object: nil)
            }
        }
    }

    private static func add(identifier: String, fireDate: Date, title: String, body: String, to center: UNUserNotificationCenter) {
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
        center.add(request) { error in
            if let error {
                NSLog("Jot: failed to schedule reminder \(identifier): \(error.localizedDescription)")
            }
        }
    }

    func cancel(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
