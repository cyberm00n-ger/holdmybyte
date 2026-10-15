// WP0 stub; WP3 owns this file (@main, AppDelegate, AppCommands, AppModel.live(), Dock, notifications).
import SwiftUI
import HMBEngine
import HMBModel
import HMBStore
import HMBUI

@main
struct HoldMyByteApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup("holdmybyte") {
            RootView(model: model)
        }
        .defaultSize(Tokens.Layout.windowDefault)
        Settings {
            SettingsView(model: model)
        }
    }
}

extension AppModel {
    /// WP3 wires LiveEngine and the HMBStore stores here (§5.3). Until then: the stub engine and in-memory stores.
    @MainActor static func live() -> AppModel {
        AppModel(state: AppState(), engine: LiveEngine(primitives: .fakes()), history: ScaffoldHistory(),
                 presetsStore: ScaffoldPresets(), settingsStore: ScaffoldSettings(), thumbnails: ScaffoldThumbnails())
    }
}

private actor ScaffoldHistory: HistoryStoring {
    func loadAll() async throws -> [WeddingRecord] { [] }
    func save(_ record: WeddingRecord) async throws {}
    func remove(_ id: WeddingID) async throws {}
    func removeAll() async throws {}
}

private struct ScaffoldPresets: PresetStoring {
    func load() -> (presets: [DeliveryPreset], defaultOn: [DeliveryID]) { (DeliveryPreset.builtIns, DeliveryPreset.defaultOnIDs) }
    func save(presets: [DeliveryPreset], defaultOn: [DeliveryID]) {}
}

private struct ScaffoldSettings: SettingsStoring {
    func load() -> AppSettings { AppSettings() }
    func save(_ settings: AppSettings) {}
}

private struct ScaffoldThumbnails: ThumbnailProviding {
    func thumbnail(for photo: SourcePhoto, maxPixelSize: Int) async -> SendableImage? { nil }
}
