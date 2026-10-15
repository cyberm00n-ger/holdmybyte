import Foundation
import HMBModel
import Synchronization

/// A small file-backed `EngineService` for bench and CLI tests: scans `*.jpg` files, "compresses" each photo into
/// a deterministic small file per delivery, honours stop and resume, and counts what it was asked to do.
final class BenchFakeEngine: EngineService {
    struct Counters { var scans = 0; var runs = 0; var preflights = 0; var stops = 0 }
    private let counters = Mutex(Counters())
    private let stopRequested = Mutex<Set<WeddingID>>([])
    /// Output bytes = source bytes × fraction.
    let fraction: Double
    let score: Double

    init(fraction: Double = 0.12, score: Double = 80) { self.fraction = fraction; self.score = score }

    var counts: Counters { counters.withLock { $0 } }

    func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> {
        counters.withLock { $0.scans += 1 }
        return AsyncThrowingStream { continuation in
            var photos: [SourcePhoto] = []
            for root in items {
                let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                    .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for file in files {
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    photos.append(SourcePhoto(id: PhotoID(photos.count), url: file, relativePath: file.lastPathComponent, byteCount: size,
                                              pixelWidth: 6000, pixelHeight: 4000, captureDate: nil, camera: nil, kind: .jpeg,
                                              modified: Date(timeIntervalSince1970: 0)))
                }
            }
            let total = photos.reduce(Int64(0)) { $0 + $1.byteCount }
            continuation.yield(.finished(ScanResult(photos: photos, sourceRoots: items, suggestedName: "Test Wedding", weddingDate: nil,
                                                    camera: nil, totalBytes: total, rawCount: 0, notices: [])))
            continuation.finish()
        }
    }

    func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] {
        let source = photos.reduce(Int64(0)) { $0 + $1.byteCount }
        return Dictionary(uniqueKeysWithValues: deliveries.map {
            ($0.id, DeliveryEstimate(bytes: Int64(Double(source) * fraction), fractionOfSource: fraction, secondsPerPhoto: 0.01))
        })
    }

    func preflight(_ request: JobRequest) async -> Preflight {
        counters.withLock { $0.preflights += 1 }
        return Preflight(outputFolder: request.outputFolder, estimatedBytes: nil, notices: [])
    }

    func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> {
        counters.withLock { $0.runs += 1 }
        stopRequested.withLock { _ = $0.remove(request.wedding) }
        return AsyncStream { continuation in
            Task {
                continuation.yield(.phase(request.wedding, .running))
                var done = 0
                for photo in request.photos {
                    if self.stopRequested.withLock({ $0.contains(request.wedding) }) {
                        continuation.yield(.phase(request.wedding, .stopped))
                        continuation.finish()
                        return
                    }
                    var results: [PhotoResult] = []
                    for preset in request.deliveries {
                        let relative = preset.folderName + "/" + (photo.relativePath as NSString).deletingPathExtension + "." + preset.format.fileExtension
                        let target = request.outputFolder.appending(path: relative)
                        let bytes = max(1, Int(Double(photo.byteCount) * self.fraction))
                        if !(resume && FileManager.default.fileExists(atPath: target.path)) {
                            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try? Data(repeating: UInt8(truncatingIfNeeded: photo.id.index), count: bytes).write(to: target)
                        }
                        results.append(PhotoResult(photo: photo.id, delivery: preset.id, status: .done,
                                                   score: preset.isLossy ? self.score : nil, target: preset.quality.floor ?? (preset.isLossy ? 74 : nil),
                                                   inBytes: photo.byteCount, outBytes: Int64(bytes), outRelativePath: relative,
                                                   encoder: "fake", byteExact: preset.isLossy ? nil : true, probes: preset.isLossy ? 2 : 0,
                                                   seconds: 0.01))
                    }
                    done += 1
                    continuation.yield(.results(request.wedding, results))
                    continuation.yield(.progress(JobProgress(wedding: request.wedding, photosDone: done, photosTotal: request.photos.count,
                                                             photosInFlight: 0, secondsPerPhoto: 0.01, etaSeconds: nil, summaries: [])))
                    await Task.yield()
                }
                continuation.yield(.phase(request.wedding, .finished))
                continuation.finish()
            }
        }
    }

    func pause(_ wedding: WeddingID) async {}
    func stop(_ wedding: WeddingID) async {
        counters.withLock { $0.stops += 1 }
        stopRequested.withLock { _ = $0.insert(wedding) }
    }
    func unfinishedJobs() async -> [UnfinishedJob] { [] }
    func discardJournal(_ wedding: WeddingID) async {}
    func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID, maxPixelSize: Int?) async throws -> ComparePair {
        throw CocoaError(.featureUnsupported)
    }
}

/// A fresh temporary folder per test, removed by `cleanup()`.
struct TemporaryFolder {
    let url: URL
    init(_ name: String = "hmb-bench-tests") throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }

    /// `count` fake source photos (`IMG0001.jpg`, …) of `bytes` each inside `folder`.
    func makePhotos(_ count: Int, bytes: Int = 4000, in folder: String = "source") throws -> URL {
        let directory = url.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 1...count {
            try Data(repeating: 0xFF, count: bytes + i).write(to: directory.appending(path: String(format: "IMG%04d.jpg", i)))
        }
        return directory
    }
}

/// The repository root (Tests/HMBBenchTests/Support/ → three levels up).
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
