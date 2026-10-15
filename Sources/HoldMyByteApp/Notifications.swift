// S19 notifications: posted only when the app is not frontmost (and only from a bundled app: an unbundled
// `swift run` binary has no notification centre). The finished notifications offer Show in Finder and Compare.
import AppKit
import HMBModel
import HMBUI
import UserNotifications

@MainActor
final class NotificationPoster: NSObject, UNUserNotificationCenterDelegate {
    enum Action { case showInFinder, compare, open }

    static let finishedCategory = "finished"
    static let showAction = "show-in-finder"
    static let compareAction = "compare"

    var onAction: (Action, WeddingID) -> Void = { _, _ in }
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func prepare() {
        guard let center else { return }
        center.delegate = self
        let finished = UNNotificationCategory(
            identifier: Self.finishedCategory,
            actions: [UNNotificationAction(identifier: Self.showAction, title: Copy.Notification.showInFinder),
                      UNNotificationAction(identifier: Self.compareAction, title: Copy.Notification.compare, options: [.foreground])],
            intentIdentifiers: [])
        center.setNotificationCategories([finished])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ event: AppEvent) {
        switch event {
        case .finished(let id, let text, let playSound):
            if playSound { NSSound(named: NSSound.Name("Glass"))?.play() }
            if text.body != nil { deliver(text, wedding: id, category: Self.finishedCategory) }
        case .pausedByDrive(let id, let text):
            deliver(text, wedding: id, category: nil)
        }
    }

    private func deliver(_ text: Copy.NotificationText, wedding: WeddingID, category: String?) {
        guard let center, !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        if let body = text.body { content.body = body }
        if let category { content.categoryIdentifier = category }
        content.userInfo = ["wedding": wedding.description]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// UserNotifications may call its delegate off the main thread; a main-actor-isolated conformance would then trap
    /// at runtime, so the callback is nonisolated and hops to the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        defer { completionHandler() }
        guard let raw = response.notification.request.content.userInfo["wedding"] as? String,
              let uuid = UUID(uuidString: raw) else { return }
        let action: Action = switch response.actionIdentifier {
        case Self.showAction: .showInFinder
        case Self.compareAction: .compare
        default: .open
        }
        let wedding = WeddingID(uuid)
        Task { @MainActor in self.onAction(action, wedding) }
    }
}
