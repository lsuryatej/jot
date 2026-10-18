import AppKit
import UserNotifications

/// Shows `Alert`s through Notification Center and reports which button was
/// pressed.
///
/// Sounds are played here with `NSSound` rather than attached to the
/// notification: Notification Center only plays sounds bundled inside the
/// app, and the built-in macOS ones are what make each level recognisable by
/// ear. The app is always running when it shows one, so this is safe.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action {
        case reply(Reply, to: UUID)
        case call
        case open
    }

    /// Called on the main queue.
    var onAction: ((Action) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        center.setNotificationCategories(Self.categories())
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted {
                NSLog("Ember: notifications not allowed (\(error?.localizedDescription ?? "turned off in System Settings"))")
            }
        }
    }

    static func categories() -> Set<UNNotificationCategory> {
        func replies(_ options: [Reply]) -> [UNNotificationAction] {
            options.map { UNNotificationAction(identifier: "reply." + $0.rawValue, title: $0.text, options: []) }
        }
        return [
            UNNotificationCategory(
                identifier: Alert.Category.pingDistance.rawValue,
                actions: replies(Reply.distance), intentIdentifiers: [], options: []
            ),
            UNNotificationCategory(
                identifier: Alert.Category.pingTogether.rawValue,
                actions: replies(Reply.together), intentIdentifiers: [], options: []
            ),
            UNNotificationCategory(
                identifier: Alert.Category.call.rawValue,
                actions: [UNNotificationAction(identifier: "call", title: "📞 FaceTime", options: [.foreground])],
                intentIdentifiers: [], options: []
            ),
        ]
    }

    func show(_ alert: Alert) {
        deliver(alert, trigger: nil, sound: nil)
        if let sound = alert.sound {
            NSSound(named: NSSound.Name(sound))?.play()
        }
    }

    /// Scheduled alerts may fire while the app is busy elsewhere, so they
    /// carry the system sound instead.
    func schedule(_ alert: Alert, at date: Date) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        deliver(alert, trigger: trigger, sound: alert.sound == nil ? nil : .default)
    }

    private func deliver(_ alert: Alert, trigger: UNNotificationTrigger?, sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = sound
        content.threadIdentifier = "ember"
        if let category = alert.category {
            content.categoryIdentifier = category.rawValue
        }
        if let pingID = alert.pingID {
            content.userInfo = ["pingID": pingID.uuidString]
        }
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger)
        center.add(request) { error in
            if let error { NSLog("Ember: could not show a notification: \(error.localizedDescription)") }
        }
    }

    /// Shown even while the menu is open; without this macOS swallows
    /// notifications from the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let pingID = (content.userInfo["pingID"] as? String).flatMap(UUID.init(uuidString:))
        let action = Self.action(
            identifier: response.actionIdentifier,
            category: content.categoryIdentifier,
            pingID: pingID
        )
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
        completionHandler()
    }

    static func action(identifier: String, category: String, pingID: UUID?) -> Action {
        if identifier.hasPrefix("reply."),
           let reply = Reply(rawValue: String(identifier.dropFirst("reply.".count))),
           let pingID {
            return .reply(reply, to: pingID)
        }
        if identifier == "call" {
            return .call
        }
        // Clicking the body of a "FaceTime" or "time's up" alert calls; any
        // other click just opens the menu.
        if identifier == UNNotificationDefaultActionIdentifier, category == Alert.Category.call.rawValue {
            return .call
        }
        return .open
    }
}
