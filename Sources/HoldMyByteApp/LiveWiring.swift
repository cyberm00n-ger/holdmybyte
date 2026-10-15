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

/// Used when the live engine cannot start (e.g. the Metal device or the codecs are unavailable): every scan fails,
/// so a drop shows "No photos found" rather than pretending to work; nothing is ever written.
final class UnavailableEngine: EngineService {
    struct Unavailable: Error, CustomStringConvertible { let description: String }
    let reason: String
    init(reason: String) { self.reason = reason }

    func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> {
        let reason = reason
        return AsyncThrowingStream { $0.finish(throwing: Unavailable(description: reason)) }
    }
    func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] {
        throw Unavailable(description: reason)
    }
    func preflight(_ request: JobRequest) async -> Preflight {
        Preflight(outputFolder: request.outputFolder, estimatedBytes: nil, notices: [.notWritable(volume: request.outputFolder.lastPathComponent)])
    }
    func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> {
        let reason = reason
        return AsyncStream { continuation in
            continuation.yield(.phase(request.wedding, .failed(reason: reason)))
            continuation.finish()
        }
    }
    func pause(_ wedding: WeddingID) async {}
    func stop(_ wedding: WeddingID) async {}
    func unfinishedJobs() async -> [UnfinishedJob] { [] }
    func discardJournal(_ wedding: WeddingID) async {}
    func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID, maxPixelSize: Int?) async throws -> ComparePair {
        throw Unavailable(description: reason)
    }
}
