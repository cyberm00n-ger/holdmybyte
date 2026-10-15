// App lifecycle (§2.1 closing and quitting, S19): keep running while a job runs with the window closed, the quit
// alert, drops onto the Dock icon, reopening, notifications and the Dock tile.
import AppKit
import HMBModel
import HMBUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let notifications = NotificationPoster()
    let dock = DockTileController()
    /// Set by the main window once it exists (SwiftUI's `openWindow`); a no-op until then.
    var openMainWindow: () -> Void = {}
    private var bootstrapped = false
    private var pendingOpen: [URL] = []

    override init() {
        model = AppModel.live()
        super.init()
        var platform = AppPlatform.system
        let dock = dock, notifications = notifications
        platform.dock = { progress, badge in dock.update(progress: progress, badge: badge) }
        platform.post = { event in notifications.post(event) }
        model.platform = platform
        notifications.onAction = { [weak self] action, wedding in self?.handleNotification(action, wedding: wedding) }
    }

    func bootstrapOnce() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        notifications.prepare()
        await model.bootstrap()
        if !pendingOpen.isEmpty {
            model.handleDrop(pendingOpen)
            pendingOpen = []
        }
    }

    // MARK: NSApplicationDelegate

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.isRunning
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.requestQuit() ? .terminateNow : .terminateLater
    }

    /// Dropping onto the Dock icon (and Open With) behaves like a drop onto the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        openMainWindow()
        if bootstrapped { model.handleDrop(urls) } else { pendingOpen += urls }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    // MARK: Notification actions

    private func handleNotification(_ action: NotificationPoster.Action, wedding: WeddingID) {
        guard let record = model.record(wedding) else { return }
        switch action {
        case .showInFinder:
            model.revealInFinder(wedding, delivery: nil)
        case .compare:
            openMainWindow()
            model.select(.wedding(wedding))
            model.compare(record, photo: nil)
        case .open:
            openMainWindow()
            model.select(.wedding(wedding))
        }
    }
}
