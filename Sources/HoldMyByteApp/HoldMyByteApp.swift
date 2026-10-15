// The app (§2.1 scene skeleton): one main Window, Settings, the transient MenuBarExtra, a Help window.
import AppKit
import HMBModel
import HMBUI
import SwiftUI

@main
struct HoldMyByteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        let model = delegate.model
        Window("holdmybyte", id: WindowID.main) {
            MainWindowContent(model: model, delegate: delegate)
        }
        .defaultSize(Tokens.Layout.windowDefault)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .environment(model)
                .hmbAccent()
        }

        MenuBarExtra(isInserted: Binding(get: { model.showsTransientStatusItem },
                                         set: { model.showsTransientStatusItem = $0 })) {
            StatusMenu(model: model)
        } label: {
            StatusItemLabel(fraction: model.overallFraction)
        }

        Window(Copy.Help.qualityMenuItem, id: WindowID.quality) {
            QualityExplainer()
                .frame(width: 360)
                .fixedSize()
                .hmbAccent()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum WindowID {
    static let main = "main"
    static let quality = "quality"
}

/// The main window's root: hands the window-opening actions to the delegate and the model, then shows RootView.
struct MainWindowContent: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        RootView(model: model)
            .onAppear {
                let open = openWindow
                delegate.openMainWindow = {
                    NSApplication.shared.activate()
                    open(id: WindowID.main)
                }
                model.platform.openMainWindow = { delegate.openMainWindow() }
                let settings = openSettings
                model.platform.openSettings = { settings() }
            }
            .task { await delegate.bootstrapOnce() }
    }
}
