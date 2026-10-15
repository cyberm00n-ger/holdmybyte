// Side effects of `AppModel` that touch the system (open panels, Finder, the file system, the Dock, notifications).
// The app target installs the live hooks; tests and the snapshot harness use `.inert` or their own closures.
import AppKit
import Foundation
import HMBModel
import SwiftUI

/// What the model tells the app shell about (notifications are posted by the app target, which knows whether the
/// app is frontmost and whether it is bundled).
public enum AppEvent: Sendable, Equatable {
    case finished(WeddingID, Copy.NotificationText, playSound: Bool)
    case pausedByDrive(WeddingID, Copy.NotificationText)
}

@MainActor
public struct AppPlatform {
    /// Files and folders to compress (⌘O). nil when cancelled.
    public var chooseItems: () -> [URL]?
    /// A folder (output location or Locate…). nil when cancelled.
    public var chooseFolder: (_ prompt: String, _ startingAt: URL?) -> URL?
    /// Reveals and selects the items in Finder.
    public var reveal: ([URL]) -> Void
    public var fileExists: (URL) -> Bool
    public var isDirectory: (URL) -> Bool
    /// Names of the mounted volumes ("Macintosh HD", "Wedding SSD").
    public var mountedVolumeNames: () -> Set<String>
    /// Registers a callback for volume mount and unmount.
    public var observeVolumes: (@escaping @MainActor () -> Void) -> Void
    public var now: () -> Date
    /// VoiceOver announcement.
    public var announce: (String) -> Void
    /// Notifications, sound.
    public var post: (AppEvent) -> Void
    /// Dock tile: progress (nil when idle) and badge (unviewed finished weddings).
    public var dock: (_ progress: Double?, _ badge: Int) -> Void
    /// Answers a pending `applicationShouldTerminate` (.terminateLater).
    public var replyToTerminate: (Bool) -> Void
    /// Brings the main window back (Dock, menu-bar extra, quit alert while closed).
    public var openMainWindow: () -> Void
    /// Opens the Settings scene.
    public var openSettings: () -> Void
    /// Remembers the sidebar choice (§2.1).
    public var defaults: UserDefaults

    public init(chooseItems: @escaping () -> [URL]?, chooseFolder: @escaping (String, URL?) -> URL?,
                reveal: @escaping ([URL]) -> Void, fileExists: @escaping (URL) -> Bool, isDirectory: @escaping (URL) -> Bool,
                mountedVolumeNames: @escaping () -> Set<String>,
                observeVolumes: @escaping (@escaping @MainActor () -> Void) -> Void,
                now: @escaping () -> Date, announce: @escaping (String) -> Void, post: @escaping (AppEvent) -> Void,
                dock: @escaping (Double?, Int) -> Void, replyToTerminate: @escaping (Bool) -> Void,
                openMainWindow: @escaping () -> Void, openSettings: @escaping () -> Void, defaults: UserDefaults) {
        self.chooseItems = chooseItems; self.chooseFolder = chooseFolder; self.reveal = reveal
        self.fileExists = fileExists; self.isDirectory = isDirectory; self.mountedVolumeNames = mountedVolumeNames
        self.observeVolumes = observeVolumes; self.now = now; self.announce = announce; self.post = post
        self.dock = dock; self.replyToTerminate = replyToTerminate; self.openMainWindow = openMainWindow
        self.openSettings = openSettings; self.defaults = defaults
    }

    /// No side effects at all: panels return nil, nothing exists, nothing is posted. The default of `AppModel`, so
    /// a model built for snapshots or previews never touches the system.
    public static var inert: AppPlatform {
        AppPlatform(chooseItems: { nil }, chooseFolder: { _, _ in nil }, reveal: { _ in },
                    fileExists: { _ in true }, isDirectory: { $0.hasDirectoryPath },
                    mountedVolumeNames: { [] }, observeVolumes: { _ in }, now: { Date() }, announce: { _ in },
                    post: { _ in }, dock: { _, _ in }, replyToTerminate: { _ in }, openMainWindow: {}, openSettings: {},
                    defaults: UserDefaults(suiteName: "holdmybyte.inert.\(UUID().uuidString)") ?? .standard)
    }

    /// The real system: NSOpenPanel, NSWorkspace, FileManager.
    public static var system: AppPlatform {
        AppPlatform(
            chooseItems: {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.allowedContentTypes = [.image, .folder]
                panel.prompt = "Choose"
                panel.message = Copy.Empty.subtitle
                return panel.runModal() == .OK ? panel.urls : nil
            },
            chooseFolder: { prompt, start in
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = prompt
                panel.directoryURL = start
                return panel.runModal() == .OK ? panel.url : nil
            },
            reveal: { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            isDirectory: { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            mountedVolumeNames: {
                let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                                 options: [.skipHiddenVolumes]) ?? []
                return Set(urls.compactMap { try? $0.resourceValues(forKeys: [.volumeNameKey]).volumeName })
            },
            observeVolumes: { callback in
                let center = NSWorkspace.shared.notificationCenter
                for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
                    center.addObserver(forName: name, object: nil, queue: .main) { _ in
                        MainActor.assumeIsolated { callback() }
                    }
                }
            },
            now: { Date() },
            announce: { text in
                AccessibilityNotification.Announcement(text).post()
            },
            post: { _ in },
            dock: { _, _ in },
            replyToTerminate: { NSApplication.shared.reply(toApplicationShouldTerminate: $0) },
            openMainWindow: {},
            openSettings: {},
            defaults: .standard)
    }
}
