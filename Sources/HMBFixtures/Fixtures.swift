import Foundation
import HMBModel

/// Domain fixtures for previews, snapshots and tests (Docs/SPEC.md §5.0 item 4). All values are deterministic.
public enum Fixtures {
    // MARK: Finn und Lissy (DATENLAGE §8)

    public static let finnUndLissyID = FixtureFactory.weddingID(1)
    public static let finnUndLissyFolder = FixtureFactory.weddingsFolder.appending(path: "Finn und Lissy", directoryHint: .isDirectory)

    /// 535 photos (10.95 GB, ILCE-7RM5, July 12, 2026), four deliveries, finished clean:
    /// Couple 1.35 GB, scores 74.0–76.2, median 74.5 · Website 159 MB, ≥ 70 · Social 155 MB, ≥ 85 ·
    /// Archive 8.55 GB, 535 byte-exact.
    public static let finnUndLissy: WeddingRecord = {
        let name = "Finn und Lissy"
        let photos = finnUndLissyPhotos
        let presets = DeliveryPreset.builtIns
        let seed = FixtureRandom.seed(name)
        let perDelivery: [[PhotoResult]] = [
            FixtureFactory.results(photos: photos, preset: presets[0], wedding: name, outputTotal: 1_350_000_000,
                                   scores: FixtureFactory.scores(count: 535, min: 74.0, max: 76.2, median: 74.5, seed: seed &+ 1),
                                   seed: seed &+ 11),
            FixtureFactory.results(photos: photos, preset: presets[1], wedding: name, outputTotal: 159_000_000,
                                   scores: FixtureFactory.scores(count: 535, min: 70.0, max: 79.4, median: 72.3, seed: seed &+ 2),
                                   seed: seed &+ 12),
            FixtureFactory.results(photos: photos, preset: presets[2], wedding: name, outputTotal: 155_000_000,
                                   scores: FixtureFactory.scores(count: 535, min: 85.0, max: 89.6, median: 86.1, seed: seed &+ 3),
                                   seed: seed &+ 13),
            FixtureFactory.results(photos: photos, preset: presets[3], wedding: name, outputTotal: 8_550_000_000,
                                   scores: nil, seed: seed &+ 14),
        ]
        let started = FixtureFactory.date(2026, 7, 14, 9, 12, 5)
        let finished = started.addingTimeInterval(252)
        return WeddingRecord(
            id: finnUndLissyID, name: name, createdAt: started.addingTimeInterval(-48), weddingDate: photos.first?.captureDate,
            camera: "ILCE-7RM5", sourceRoots: [finnUndLissyFolder.appending(path: "fertig", directoryHint: .isDirectory)],
            sourceBookmarks: [], photos: photos, deliveries: presets,
            deliveryCompletedAt: Dictionary(uniqueKeysWithValues: presets.map { ($0.id.rawValue, finished) }),
            outputFolder: finnUndLissyFolder.appending(path: "Finn und Lissy – Deliveries", directoryHint: .isDirectory),
            outputBookmark: nil, naming: .default, phase: .finished, results: interleave(perDelivery),
            startedAt: started, finishedAt: finished, activeSeconds: 252, viewed: true)
    }()

    static let finnUndLissyPhotos: [SourcePhoto] = FixtureFactory.photos(
        count: 535, totalBytes: 10_950_000_000, root: finnUndLissyFolder.appending(path: "fertig", directoryHint: .isDirectory),
        firstCapture: FixtureFactory.date(2026, 7, 12, 12, 31, 4), hours: 11.2, camera: "ILCE-7RM5",
        pixelSize: (9504, 6336), filePrefix: "DSC", firstNumber: 1207, seed: FixtureRandom.seed("Finn und Lissy", "photos"))

    // MARK: Anna und Ben (queued)

    public static let annaUndBenID = FixtureFactory.weddingID(2)

    /// 412 photos, Couple’s Package + Website, queued at position 1, nothing processed yet.
    public static let annaUndBen: WeddingRecord = {
        let folder = FixtureFactory.weddingsFolder.appending(path: "Anna und Ben", directoryHint: .isDirectory)
        let root = folder.appending(path: "Export", directoryHint: .isDirectory)
        let photos = FixtureFactory.photos(count: 412, totalBytes: 8_652_000_000, root: root,
                                           firstCapture: FixtureFactory.date(2026, 8, 22, 11, 2, 40), hours: 12.5,
                                           camera: "ILCE-1", pixelSize: (8640, 5760), filePrefix: "_DSC", firstNumber: 4410,
                                           seed: FixtureRandom.seed("Anna und Ben", "photos"))
        let deliveries = DeliveryPreset.builtIns.filter { DeliveryPreset.defaultOnIDs.contains($0.id) }
        return WeddingRecord(
            id: annaUndBenID, name: "Anna und Ben", createdAt: FixtureFactory.date(2026, 10, 15, 9, 40),
            weddingDate: photos.first?.captureDate, camera: "ILCE-1", sourceRoots: [root], sourceBookmarks: [],
            photos: photos, deliveries: deliveries, deliveryCompletedAt: [:],
            outputFolder: folder.appending(path: "Anna und Ben – Deliveries", directoryHint: .isDirectory),
            outputBookmark: nil, naming: .default, phase: .queued(position: 1), results: [],
            startedAt: nil, finishedAt: nil, activeSeconds: 0, viewed: false)
    }()

    // MARK: Setup inputs

    /// What a scan of Finn und Lissy's `fertig` folder returns.
    public static let scanResult = ScanResult(
        photos: finnUndLissy.photos, sourceRoots: finnUndLissy.sourceRoots, suggestedName: "Finn und Lissy",
        weddingDate: finnUndLissy.weddingDate, camera: "ILCE-7RM5", totalBytes: finnUndLissy.sourceBytes,
        rawCount: 0, notices: [])

    /// Estimates for the built-in deliveries on `scanResult` ("≈ 1.4 GB", "−87 %"; Couple + Website ≈ 1.6 GB, about 5 min).
    public static let estimates: [DeliveryID: DeliveryEstimate] = [
        .couple: DeliveryEstimate(bytes: 1_400_000_000, fractionOfSource: 0.128, secondsPerPhoto: 0.46),
        .website: DeliveryEstimate(bytes: 161_000_000, fractionOfSource: 0.0147, secondsPerPhoto: 0.09),
        .social: DeliveryEstimate(bytes: 152_000_000, fractionOfSource: 0.0139, secondsPerPhoto: 0.06),
        .archive: DeliveryEstimate(bytes: 8_560_000_000, fractionOfSource: 0.782, secondsPerPhoto: 0.35),
    ]

    // MARK: Variants

    /// Photos 42 and 208 (indices 41, 207) are unreadable in every delivery; photo 319 (index 318) failed to encode
    /// for Website (only if the record has a Website delivery). Everything else is unchanged.
    public static func withIssues(_ record: WeddingRecord) -> WeddingRecord {
        var record = record
        let unreadable: Set<Int> = [41, 207].filter { $0 < record.photos.count }.reduce(into: []) { $0.insert($1) }
        let encodeFailed = 318
        for i in record.results.indices {
            let index = record.results[i].photo.index
            if unreadable.contains(index) {
                record.results[i] = failed(record.results[i], .unreadable)
            } else if index == encodeFailed, record.results[i].delivery == .website {
                record.results[i] = failed(record.results[i], .encodeFailed)
            }
        }
        return record
    }

    /// Finn und Lissy where `count` Couple’s Package photos were kept as original (spread over the wedding).
    public static func keptOriginal(_ count: Int) -> WeddingRecord {
        var record = finnUndLissy
        let n = record.photos.count
        let picked = Set((0..<max(0, min(count, n))).map { ($0 * 2 + 1) * n / (2 * max(count, 1)) })
        for i in record.results.indices where record.results[i].delivery == .couple && picked.contains(record.results[i].photo.index) {
            var result = record.results[i]
            result.status = .keptOriginal
            result.outBytes = result.inBytes
            result.score = nil
            result.encoder = "copy"
            result.chroma = nil
            record.results[i] = result
        }
        return record
    }

    /// `record` while running (or paused, stopped, interrupted: pass `phase`): the first `done` photos are finished
    /// in every delivery, the next `inFlight` are `.working`, the rest have no result yet (queued).
    /// The progress uses 0.47 s per photo; its ETA is nil until 10 photos have finished.
    public static func inProgress(_ record: WeddingRecord, done: Int, inFlight: Int = 4,
                                  phase: JobPhase = .running) -> (record: WeddingRecord, progress: JobProgress) {
        var record = record
        let done = max(0, min(done, record.photos.count))
        let working = min(inFlight, record.photos.count - done)
        let finished = record.results.filter { $0.photo.index < done }
        let inFlightResults = record.photos[done..<(done + working)].flatMap { photo in
            record.deliveries.map { PhotoResult(photo: photo.id, delivery: $0.id, status: .working, inBytes: photo.byteCount) }
        }
        record.results = finished + inFlightResults
        record.phase = phase
        record.finishedAt = nil
        record.deliveryCompletedAt = [:]
        record.viewed = false
        record.activeSeconds = Double(done) * 0.47
        let summaries = record.deliveries.map { preset in
            DeliverySummary.make(preset: preset, photos: record.photos, results: finished.filter { $0.delivery == preset.id })
        }
        let secondsPerPhoto: Double? = done > 0 ? 0.47 : nil
        let eta: Double? = done >= 10 ? Double(record.photos.count - done) * 0.47 : nil
        let progress = JobProgress(wedding: record.id, photosDone: done, photosTotal: record.photos.count,
                                   photosInFlight: phase == .running ? working : 0,
                                   secondsPerPhoto: secondsPerPhoto, etaSeconds: eta, summaries: summaries)
        return (record, progress)
    }

    /// `record` with nothing delivered: phase `.failed(reason:)`, no results.
    public static func failed(_ record: WeddingRecord, reason: String = "“Wedding SSD” was disconnected before any photo was finished.") -> WeddingRecord {
        var record = record
        record.phase = .failed(reason: reason)
        record.results = []
        record.deliveryCompletedAt = [:]
        record.finishedAt = nil
        return record
    }

    /// `record` restricted to the given deliveries (results included), e.g. a single-delivery Done view.
    public static func only(_ deliveries: [DeliveryID], of record: WeddingRecord) -> WeddingRecord {
        var record = record
        record.deliveries = record.deliveries.filter { deliveries.contains($0.id) }
        record.results = record.results.filter { deliveries.contains($0.delivery) }
        record.deliveryCompletedAt = record.deliveryCompletedAt.filter { key, _ in deliveries.contains(DeliveryID(rawValue: key)) }
        return record
    }

    static func failed(_ result: PhotoResult, _ failure: PhotoFailure) -> PhotoResult {
        PhotoResult(photo: result.photo, delivery: result.delivery, status: .failed(failure), inBytes: result.inBytes,
                    probes: result.probes, seconds: result.seconds)
    }

    /// Per-photo order (photo 0 in every delivery, then photo 1, …), as the engine reports them.
    static func interleave(_ perDelivery: [[PhotoResult]]) -> [PhotoResult] {
        guard let count = perDelivery.map(\.count).max() else { return [] }
        return (0..<count).flatMap { i in perDelivery.compactMap { i < $0.count ? $0[i] : nil } }
    }
}
