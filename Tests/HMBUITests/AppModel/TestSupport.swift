// Helpers for the WP3 intent tests: a spy around FixtureEngine, small scans, polling.
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Synchronization
import Testing

/// Forwards to `engines[min(runIndex, count − 1)]` for `run` (so a retry can use a clean engine) and to the first
/// engine otherwise; records every request.
final class SpyEngine: EngineService {
    let engines: [FixtureEngine]
    private let log = Mutex<(runs: [(JobRequest, Bool)], scans: [[URL]], pauses: [WeddingID], stops: [WeddingID])>(([], [], [], []))

    init(_ engines: FixtureEngine...) { self.engines = engines }
    convenience init(_ configuration: FixtureEngine.Configuration) { self.init(FixtureEngine(configuration)) }

    var runs: [(request: JobRequest, resume: Bool)] { log.withLock { $0.runs.map { (request: $0.0, resume: $0.1) } } }
    var scans: [[URL]] { log.withLock { $0.scans } }
    var pauses: [WeddingID] { log.withLock { $0.pauses } }

    func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> {
        log.withLock { $0.scans.append(items) }
        return engines[0].scan(items)
    }
    func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] {
        try await engines[0].estimate(photos: photos, deliveries: deliveries)
    }
    func preflight(_ request: JobRequest) async -> Preflight { await engines[0].preflight(request) }
    func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> {
        let index = log.withLock { log -> Int in
            log.runs.append((request, resume))
            return min(log.runs.count - 1, engines.count - 1)
        }
        return engines[index].run(request, resume: resume)
    }
    func pause(_ wedding: WeddingID) async {
        log.withLock { $0.pauses.append(wedding) }
        for engine in engines { await engine.pause(wedding) }
    }
    func stop(_ wedding: WeddingID) async {
        log.withLock { $0.stops.append(wedding) }
        for engine in engines { await engine.stop(wedding) }
    }
    func unfinishedJobs() async -> [UnfinishedJob] { await engines[0].unfinishedJobs() }
    func discardJournal(_ wedding: WeddingID) async { for engine in engines { await engine.discardJournal(wedding) } }
    func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID, maxPixelSize: Int?) async throws -> ComparePair {
        try await engines[0].comparePair(record: record, photo: photo, delivery: delivery, maxPixelSize: maxPixelSize)
    }
}

enum TestData {
    /// The first `count` photos of Finn und Lissy as a scan (name "Finn und Lissy").
    static func scan(_ count: Int = 40, name: String = "Finn und Lissy", rawCount: Int = 0, notices: [ScanNotice] = []) -> ScanResult {
        let photos = Array(Fixtures.scanResult.photos.prefix(count))
        return ScanResult(photos: photos, sourceRoots: Fixtures.scanResult.sourceRoots, suggestedName: name,
                          weddingDate: photos.first?.captureDate, camera: "ILCE-7RM5",
                          totalBytes: photos.reduce(0) { $0 + $1.byteCount }, rawCount: rawCount, notices: notices)
    }

    static let folder = URL(fileURLWithPath: "/Users/sebastian/Weddings/Finn und Lissy/fertig", isDirectory: true)

    static func configuration(_ scan: ScanResult = TestData.scan(), secondsPerPhoto: Double = 0,
                              failures: [FixtureEngine.Failure] = [], pausePoint: FixtureEngine.PausePoint? = nil,
                              unfinished: [UnfinishedJob] = [], scanDuration: Duration = .zero,
                              preflightNotices: [ScanNotice] = [], failJob: String? = nil) -> FixtureEngine.Configuration {
        FixtureEngine.Configuration(scanResult: scan, scanDuration: scanDuration, preflightNotices: preflightNotices,
                                    secondsPerPhoto: secondsPerPhoto, failures: failures, pausePoint: pausePoint,
                                    failJob: failJob, unfinished: unfinished)
    }
}

/// Records the platform side effects a test cares about.
@MainActor
final class PlatformLog {
    var revealed: [[URL]] = []
    var events: [AppEvent] = []
    var dock: [(Double?, Int)] = []
    var terminateReplies: [Bool] = []
    var announcements: [String] = []
    var chooseFolder: URL?
    var chooseItems: [URL]?
    var existing: Set<String>?           // nil: everything exists
    var directories: Set<String> = []
    var volumes: Set<String> = ["Macintosh HD"]
    var volumeCallback: (@MainActor () -> Void)?

    func platform() -> AppPlatform {
        AppPlatform(
            chooseItems: { [unowned self] in self.chooseItems },
            chooseFolder: { [unowned self] _, _ in self.chooseFolder },
            reveal: { [unowned self] in self.revealed.append($0) },
            fileExists: { [unowned self] url in self.existing.map { $0.contains(url.standardizedFileURL.path) } ?? true },
            isDirectory: { [unowned self] url in self.directories.contains(url.standardizedFileURL.path) || url.hasDirectoryPath },
            mountedVolumeNames: { [unowned self] in self.volumes },
            observeVolumes: { [unowned self] callback in self.volumeCallback = callback },
            now: { Date() },
            announce: { [unowned self] in self.announcements.append($0) },
            post: { [unowned self] in self.events.append($0) },
            dock: { [unowned self] in self.dock.append(($0, $1)) },
            replyToTerminate: { [unowned self] in self.terminateReplies.append($0) },
            openMainWindow: {},
            openSettings: {},
            defaults: UserDefaults(suiteName: "holdmybyte.tests.\(UUID().uuidString)")!)
    }
}

@MainActor
struct Harness {
    let model: AppModel
    let engine: SpyEngine
    let history: InMemoryHistory
    let log: PlatformLog

    init(engine: SpyEngine, records: [WeddingRecord] = [], state: AppState = AppState()) {
        var state = state
        state.records = records
        self.engine = engine
        history = InMemoryHistory(records)
        log = PlatformLog()
        model = AppModel(state: state, engine: engine, history: history, presetsStore: InMemoryPresets(),
                         settingsStore: InMemorySettings(), thumbnails: FixtureThumbnails(photoFolder: nil))
        model.platform = log.platform()
    }

    init(_ configuration: FixtureEngine.Configuration = TestData.configuration(), records: [WeddingRecord] = []) {
        self.init(engine: SpyEngine(configuration), records: records)
    }

    /// Drop → ready → start; returns the new wedding's id once it is committed.
    func dropAndStart(_ urls: [URL] = [TestData.folder]) async throws -> WeddingID {
        model.handleDrop(urls)
        try await waitUntil("scan ready") { if case .ready? = model.state.draft?.scan { true } else { false } }
        try await waitUntil("estimates") { model.draftEstimatedBytes != nil }
        let draftID = try #require(model.state.draft?.wedding)
        model.startDraft()
        try await waitUntil("committed") { model.record(draftID) != nil && model.state.draft == nil }
        return draftID
    }

    func phase(_ id: WeddingID) -> JobPhase? { model.record(id)?.phase }
}

struct Timeout: Error, CustomStringConvertible { let description: String }

@MainActor
func waitUntil(_ what: String, timeout: Double = 10, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw Timeout(description: "timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

