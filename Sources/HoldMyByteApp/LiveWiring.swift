// AppModel.live(): the production engine and stores (§5.3).
//
// Merge note (Docs/WP3-NOTES.md, Q2): HMBStore's JSONHistoryStore, UserDefaultsPresetStore, UserDefaultsSettingsStore
// and DiskThumbnailCache (WP4) do not exist on this branch yet. Until WP4 merges, the `Interim…` stores in
// InterimStores.swift stand in; at merge, the four lines marked `// WP4` are replaced by WP4's types.
// `HMB_FIXTURE_ENGINE=1` runs the app on FixtureEngine (demo and manual flow checks; never touches files).
import Foundation
import HMBEngine
import HMBModel
import HMBStore
import HMBUI

extension AppModel {
    @MainActor static func live() -> AppModel {
        let support = LiveEngine.defaultSupportDirectory
        let engine: any EngineService
        let thumbnails: any ThumbnailProviding
        if DemoSupport.isEnabled {
            engine = DemoSupport.engine()
            thumbnails = DemoSupport.thumbnails()
        } else {
            do {
                engine = try LiveEngine(supportDirectory: support)
            } catch {
                engine = UnavailableEngine(reason: String(describing: error))
            }
            thumbnails = InterimThumbnails()                                            // WP4: DiskThumbnailCache
        }
        let history = InterimHistoryStore(directory: support.appending(path: "Weddings", directoryHint: .isDirectory)) // WP4
        return AppModel(state: AppState(), engine: engine, history: history,
                        presetsStore: InterimPresetStore(),                             // WP4: UserDefaultsPresetStore
                        settingsStore: InterimSettingsStore(),                          // WP4: UserDefaultsSettingsStore
                        thumbnails: thumbnails)
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
