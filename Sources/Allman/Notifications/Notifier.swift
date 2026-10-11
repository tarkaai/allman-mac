// Native notifications for inbound LinkedIn messages, with an inline Reply
// action that sends through the CLI and an Open action that reveals the thread.

import Foundation
@preconcurrency import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notificationsEnabled"
    static let category = "sh.allman.message"
    static let replyAction = "REPLY"
    static let openAction = "OPEN"

    /// (accountId, convId) — convId is empty for a summary/error notification.
    var onOpenConversation: ((String?, String) -> Void)?
    /// (accountId, convId, text)
    var onReply: ((String?, String, String) -> Void)?

    private(set) var authorized = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Reply on LinkedIn…"
        )
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open", options: [.foreground])
        let cat = UNNotificationCategory(identifier: Self.category, actions: [reply, open], intentIdentifiers: [], options: [])
        center.setNotificationCategories([cat])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func notifyMessage(accountId: String? = nil, convId: String, sender: String, body: String, urn: String) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = body.isEmpty ? "Sent an attachment" : body
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = convId
        var info: [String: Any] = ["convId": convId, "urn": urn]
        if let accountId { info["accountId"] = accountId }
        content.userInfo = info
        let req = UNNotificationRequest(identifier: "msg:\(urn)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func notifySummary(count: Int, convCount: Int) {
        guard isEnabled, count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(count) new LinkedIn message\(count == 1 ? "" : "s")"
        content.body = "in \(convCount) conversation\(convCount == 1 ? "" : "s") while you were away"
        content.sound = .default
        content.userInfo = ["summary": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "summary:\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    func notifyError(title: String, body: String) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["error": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "err:\(title)", content: content, trigger: nil))
    }

    func clear(convId: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.threadIdentifier == convId }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let convId = info["convId"] as? String
        let accountId = info["accountId"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if action == Self.replyAction, let convId, let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                onReply?(accountId, convId, text)
            } else if let convId {
                onOpenConversation?(accountId, convId)
            } else {
                onOpenConversation?(accountId, "")
            }
        }
    }
}
