// AppModel.live(): the production engine and stores (§5.3): LiveEngine plus HMBStore's JSONHistoryStore,
// UserDefaultsPresetStore, UserDefaultsSettingsStore and DiskThumbnailCache, all at their default locations
// (`~/Library/Application Support/holdmybyte/Weddings`, `holdmybyte.*` defaults keys,
// `~/Library/Caches/eu.sebastianhaas.holdmybyte/Thumbnails`).
// `HMB_FIXTURE_ENGINE=1` runs the app on FixtureEngine (demo and manual flow checks; never touches files).
import Foundation
import HMBEngine
import HMBModel
import HMBStore
import HMBUI

extension AppModel {
    @MainActor static func live() -> AppModel {
        // HMBUI cannot import the engine, so it repeats the engine's key prefix; this is where both are visible.
        precondition(AppModel.learnedEstimatesKeyPrefix == LearnedEstimates.keyPrefix,
                     "Reset Learned Estimates must remove the engine's keys")
        if DemoSupport.isEnabled {
            return AppModel(state: AppState(), engine: DemoSupport.engine(), history: DemoSupport.history(),
                            presetsStore: DemoSupport.presets(), settingsStore: DemoSupport.settings(),
                            thumbnails: DemoSupport.thumbnails())
        }
        let engine: any EngineService
        do {
            engine = try LiveEngine(supportDirectory: LiveEngine.defaultSupportDirectory)
        } catch {
            engine = UnavailableEngine(reason: String(describing: error))
        }
        return AppModel(state: AppState(), engine: engine,
                        history: JSONHistoryStore(directory: StoreLocations.weddings),
                        presetsStore: UserDefaultsPresetStore(),
                        settingsStore: UserDefaultsSettingsStore(),
                        thumbnails: DiskThumbnailCache(directory: StoreLocations.thumbnails))
    }
}
