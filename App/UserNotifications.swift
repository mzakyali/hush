import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter. `requestAuthorization` is idempotent —
/// it only prompts the first time and returns the existing setting afterwards.
enum UserNotifications {
    static func post(_ message: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = "Hush"
            content.body = message
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { _ in }
        }
    }
}
