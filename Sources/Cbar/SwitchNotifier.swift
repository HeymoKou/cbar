import Foundation
import UserNotifications
import CbarCore

/// The system notification for a switch cbar made on its own.
///
/// Permission is asked for on first use, not at launch: someone who never arms
/// auto-switch is never asked. macOS remembers the answer, so later calls go
/// straight through (or are dropped, if the answer was no — said once in the log
/// rather than on every switch).
final class SwitchNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SwitchNotifier()
    private var loggedRefusal = false

    func post(title: String, body: String) {
        // `current()` traps in a process with no bundle; cbar always has one,
        // but a bare binary run from `.build` does not.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            guard granted else {
                if self?.loggedRefusal == false {
                    self?.loggedRefusal = true
                    CbarLog.write("switch notifications are off for cbar in System Settings"
                                  + (error.map { " (\($0.localizedDescription))" } ?? ""))
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error { CbarLog.write("switch notification not delivered: \(error.localizedDescription)") }
            }
        }
    }

    /// Without this a banner is suppressed whenever cbar is the active app —
    /// which it is while its panel is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }
}
