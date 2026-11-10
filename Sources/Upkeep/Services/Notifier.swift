import Foundation
import UserNotifications

/// macOS notifications with an "Update all" action. Only available when running as a real
/// .app bundle: UNUserNotificationCenter aborts the process for a bare executable (`swift run`).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let categoryID = "UPKEEP_UPDATES"
    static let updateAllActionID = "UPDATE_ALL"

    var onUpdateAll: (() -> Void)?
    var onShow: (() -> Void)?

    let available = Bundle.main.bundleIdentifier != nil

    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let updateAll = UNNotificationAction(identifier: Self.updateAllActionID, title: "Update all", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [updateAll], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String, actionable: Bool) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if actionable { content.categoryIdentifier = Self.categoryID }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void)
    {
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == Self.updateAllActionID {
                onUpdateAll?()
            } else {
                onShow?()
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        completionHandler([.banner, .sound])
    }
}
