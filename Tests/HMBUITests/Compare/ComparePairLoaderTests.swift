// Compare loading (Docs/SPEC.md §2.4 S14): the staged loader must survive Compare leaving the screen and coming
// back (window closed and reopened) without getting stuck on the screen-resolution pair or the HUD spinner.
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Testing

/// FixtureEngine's pairs, each after a short delay, so a load can be interrupted half-way.
struct SlowCompareEngine: EngineService {
    var base = FixtureEngine()
    var delay: Duration = .milliseconds(80)

    func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> { base.scan(items) }
    func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] {
        try await base.estimate(photos: photos, deliveries: deliveries)
    }
    func preflight(_ request: JobRequest) async -> Preflight { await base.preflight(request) }
    func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> { base.run(request, resume: resume) }
    func pause(_ wedding: WeddingID) async { await base.pause(wedding) }
    func stop(_ wedding: WeddingID) async { await base.stop(wedding) }
    func unfinishedJobs() async -> [UnfinishedJob] { await base.unfinishedJobs() }
    func discardJournal(_ wedding: WeddingID) async { await base.discardJournal(wedding) }
    func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID, maxPixelSize: Int?) async throws -> ComparePair {
        try await Task.sleep(for: delay)
        return try await base.comparePair(record: record, photo: photo, delivery: delivery, maxPixelSize: maxPixelSize)
    }
}

@MainActor @Suite struct ComparePairLoaderTests {
    static func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func resumesAfterBeingCancelledMidLoad() async throws {
        let record = Fixtures.finnUndLissy
        let engine = SlowCompareEngine()
        let thumbnails = FixtureThumbnails(photoFolder: nil)
        let key = ComparePairLoader.Key(wedding: record.id, photo: PhotoID(3), delivery: .couple)
        let loader = ComparePairLoader()

        loader.show(key, record: record, engine: engine, thumbnails: thumbnails, screenPixels: 1024, upcoming: [])
        loader.cancel()                                   // Compare left the screen before anything arrived
        try await Task.sleep(for: .milliseconds(300))
        #expect(loader.stage != .full)

        // Back on screen: the same photo is shown again and must finish loading.
        loader.show(key, record: record, engine: engine, thumbnails: thumbnails, screenPixels: 1024, upcoming: [PhotoID(4)])
        await Self.waitUntil { loader.stage == .full }
        #expect(loader.stage == .full && loader.pair != nil && !loader.isLoading)
    }

    @Test func differencesAreComputedAgainAfterBeingCancelled() async throws {
        let record = Fixtures.finnUndLissy
        let engine = SlowCompareEngine(delay: .zero)
        let thumbnails = FixtureThumbnails(photoFolder: nil)
        let key = ComparePairLoader.Key(wedding: record.id, photo: PhotoID(5), delivery: .couple)
        let loader = ComparePairLoader()
        let tint: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0, 0.6, 0.6)

        loader.show(key, record: record, engine: engine, thumbnails: thumbnails, screenPixels: 1024, upcoming: [])
        await Self.waitUntil { loader.stage == .full }
        loader.updateDifferences(wanted: true, tint: tint)
        loader.cancel()                                   // left the screen while the differences were computing
        #expect(!loader.isComputingDifferences)
        loader.updateDifferences(wanted: true, tint: tint)
        await Self.waitUntil { loader.differences != nil }
        #expect(loader.differences != nil && !loader.isComputingDifferences)
    }
}
