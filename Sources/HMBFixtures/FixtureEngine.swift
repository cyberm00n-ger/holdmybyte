import CoreGraphics
import Foundation
import HMBModel
import Synchronization

/// A scripted `EngineService` for previews, snapshots and UI tests. It never touches the file system:
/// scans return `configuration.scanResult`, jobs replay deterministic results (`FixtureFactory.result`) at
/// `configuration.secondsPerPhoto`, and compare pairs are synthetic images.
public final class FixtureEngine: EngineService {
    public struct Failure: Sendable, Hashable {
        public var photo: PhotoID
        public var delivery: DeliveryID?          // nil: every delivery
        public var failure: PhotoFailure
        public init(photo: PhotoID, delivery: DeliveryID? = nil, failure: PhotoFailure) {
            self.photo = photo; self.delivery = delivery; self.failure = failure
        }
    }

    public struct PausePoint: Sendable, Hashable {
        public var afterPhotos: Int               // pause once this many photos of the run are finished
        public var reason: PauseReason
        public init(afterPhotos: Int, reason: PauseReason) { self.afterPhotos = afterPhotos; self.reason = reason }
    }

    public struct Configuration: Sendable {
        public var scanResult: ScanResult
        /// Total simulated scan time (progress is reported in five steps).
        public var scanDuration: Duration
        /// Thrown by `scan` instead of finishing.
        public var scanError: String?
        public var estimates: [DeliveryID: DeliveryEstimate]
        public var estimateDuration: Duration
        public var preflightNotices: [ScanNotice]
        /// Simulated wall time per photo; 0 replays as fast as possible.
        public var secondsPerPhoto: Double
        /// Seconds per photo reported in progress events (the ETA model), independent of the replay speed.
        public var reportedSecondsPerPhoto: Double
        public var failures: [Failure]
        public var pausePoint: PausePoint?
        /// `run` reports `.failed(reason:)` immediately.
        public var failJob: String?
        public var unfinished: [UnfinishedJob]
        /// `comparePair` reports the original as unavailable on this volume.
        public var compareUnavailableVolume: String?

        public init(scanResult: ScanResult = Fixtures.scanResult, scanDuration: Duration = .zero, scanError: String? = nil,
                    estimates: [DeliveryID: DeliveryEstimate] = Fixtures.estimates, estimateDuration: Duration = .zero,
                    preflightNotices: [ScanNotice] = [], secondsPerPhoto: Double = 0, reportedSecondsPerPhoto: Double = 0.47,
                    failures: [Failure] = [], pausePoint: PausePoint? = nil, failJob: String? = nil,
                    unfinished: [UnfinishedJob] = [], compareUnavailableVolume: String? = nil) {
            self.scanResult = scanResult; self.scanDuration = scanDuration; self.scanError = scanError
            self.estimates = estimates; self.estimateDuration = estimateDuration
            self.preflightNotices = preflightNotices; self.secondsPerPhoto = secondsPerPhoto
            self.reportedSecondsPerPhoto = reportedSecondsPerPhoto; self.failures = failures
            self.pausePoint = pausePoint; self.failJob = failJob; self.unfinished = unfinished
            self.compareUnavailableVolume = compareUnavailableVolume
        }
    }

    public struct ScanFailed: Error, CustomStringConvertible { public var description: String }

    private struct State {
        var pauseRequested: Set<WeddingID> = []
        var stopRequested: Set<WeddingID> = []
        var finished: [WeddingID: [PhotoResult]] = [:]       // results so far, per job (for resume)
        var unfinished: [WeddingID: UnfinishedJob] = [:]
        var pausePointUsed: Set<WeddingID> = []
        var runs: [WeddingID: Int] = [:]
    }

    public let configuration: Configuration
    private let state: Mutex<State>
    private let thumbnails = FixtureThumbnails(photoFolder: nil)

    public init(_ configuration: Configuration = Configuration()) {
        self.configuration = configuration
        var initial = State()
        for job in configuration.unfinished {
            initial.unfinished[job.request.wedding] = job
            initial.finished[job.request.wedding] = job.results
        }
        state = Mutex(initial)
    }

    /// How many times `run` was called for `wedding` (for tests).
    public func runCount(_ wedding: WeddingID) -> Int { state.withLock { $0.runs[wedding] ?? 0 } }

    // MARK: EngineService

    public func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> {
        let configuration = configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                let total = configuration.scanResult.photos.count
                for step in 1...5 {
                    if configuration.scanDuration > .zero { try? await Task.sleep(for: configuration.scanDuration / 5) }
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    if step < 5 { continuation.yield(.progress(found: total * step / 5)) }
                }
                if let error = configuration.scanError {
                    continuation.finish(throwing: ScanFailed(description: error))
                } else {
                    continuation.yield(.finished(configuration.scanResult))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] {
        if configuration.estimateDuration > .zero { try await Task.sleep(for: configuration.estimateDuration) }
        try Task.checkCancellation()
        let sourceBytes = photos.reduce(Int64(0)) { $0 + $1.byteCount }
        let scale = configuration.scanResult.totalBytes > 0 ? Double(sourceBytes) / Double(configuration.scanResult.totalBytes) : 1
        var result: [DeliveryID: DeliveryEstimate] = [:]
        for preset in deliveries {
            if let known = configuration.estimates[preset.id], preset.isBuiltIn {
                result[preset.id] = DeliveryEstimate(bytes: Int64(Double(known.bytes) * scale),
                                                     fractionOfSource: known.fractionOfSource,
                                                     secondsPerPhoto: known.secondsPerPhoto)
            } else {
                let fraction = FixtureFactory.typicalFraction(for: preset)
                result[preset.id] = DeliveryEstimate(bytes: Int64(Double(sourceBytes) * fraction), fractionOfSource: fraction,
                                                     secondsPerPhoto: preset.isFullSize ? 0.45 : 0.08)
            }
        }
        return result
    }

    public func preflight(_ request: JobRequest) async -> Preflight {
        let estimates = (try? await estimate(photos: request.photos, deliveries: request.deliveries)) ?? [:]
        let bytes = estimates.values.reduce(Int64(0)) { $0 + $1.bytes }
        return Preflight(outputFolder: request.outputFolder, estimatedBytes: bytes, notices: configuration.preflightNotices)
    }

    public func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let task = Task { await self.replay(request, resume: resume, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func pause(_ wedding: WeddingID) async { _ = state.withLock { $0.pauseRequested.insert(wedding) } }
    public func stop(_ wedding: WeddingID) async { _ = state.withLock { $0.stopRequested.insert(wedding) } }

    public func unfinishedJobs() async -> [UnfinishedJob] {
        state.withLock { state in
            state.unfinished.values.map { job in
                UnfinishedJob(request: job.request, results: state.finished[job.request.wedding] ?? job.results)
            }.sorted { $0.request.name < $1.request.name }
        }
    }

    public func discardJournal(_ wedding: WeddingID) async {
        state.withLock {
            $0.unfinished[wedding] = nil
            $0.finished[wedding] = nil
        }
    }

    public func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID,
                            maxPixelSize: Int?) async throws -> ComparePair {
        guard let source = record.photos.first(where: { $0.id == photo }),
              let preset = record.deliveries.first(where: { $0.id == delivery }) else {
            throw ScanFailed(description: "no such photo or delivery")
        }
        let result = record.results.last { $0.photo == photo && $0.delivery == delivery }
        let edge = min(maxPixelSize ?? 2048, preset.size.longEdge ?? Int.max)
        let original = thumbnails.image(for: source, maxPixelSize: edge)
        let delivered = SendableImage(Self.degraded(original.cgImage, step: preset.quality == .balanced ? 6 : 4))
        let unavailable = configuration.compareUnavailableVolume
        return ComparePair(original: unavailable == nil ? original : nil, delivered: delivered,
                           originalBytes: source.byteCount, deliveredBytes: result?.outBytes ?? source.byteCount,
                           comparedAtLongEdge: preset.size.longEdge, unavailableVolume: unavailable)
    }

    // MARK: Replay

    private func replay(_ request: JobRequest, resume: Bool, into continuation: AsyncStream<EngineEvent>.Continuation) async {
        let wedding = request.wedding
        let configuration = configuration
        state.withLock {
            $0.runs[wedding, default: 0] += 1
            $0.pauseRequested.remove(wedding)
            $0.stopRequested.remove(wedding)
            if !resume { $0.finished[wedding] = [] }
            $0.unfinished[wedding] = UnfinishedJob(request: request, results: $0.finished[wedding] ?? [])
        }
        if let reason = configuration.failJob {
            continuation.yield(.phase(wedding, .failed(reason: reason)))
            state.withLock { $0.unfinished[wedding] = nil }
            continuation.finish()
            return
        }
        continuation.yield(.phase(wedding, .running))

        let scope = request.photos.filter { request.onlyPhotos?.contains($0.id) ?? true }
        let alreadyDone = Set(state.withLock { $0.finished[wedding] ?? [] }.map(\.photo))
        let todo = scope.filter { !alreadyDone.contains($0.id) }
        var allResults = state.withLock { $0.finished[wedding] ?? [] }
        var pending: [PhotoResult] = []
        var doneCount = scope.count - todo.count
        var lastFlush = ContinuousClock.now
        var smoothed: Double?

        func flush(inFlight: Int) {
            if !pending.isEmpty { continuation.yield(.results(wedding, pending)); pending.removeAll() }
            let summaries = request.deliveries.map { preset in
                DeliverySummary.make(preset: preset, photos: scope, results: allResults.filter { $0.delivery == preset.id })
            }
            let eta: Double? = doneCount >= 10 ? smoothed.map { Double(scope.count - doneCount) * $0 } : nil
            continuation.yield(.progress(JobProgress(wedding: wedding, photosDone: doneCount, photosTotal: scope.count,
                                                     photosInFlight: inFlight, secondsPerPhoto: smoothed, etaSeconds: eta,
                                                     summaries: summaries)))
            lastFlush = .now
        }

        for (i, photo) in todo.enumerated() {
            let (pause, stop) = state.withLock { ($0.pauseRequested.contains(wedding), $0.stopRequested.contains(wedding)) }
            let pausePoint = configuration.pausePoint.flatMap { point in
                doneCount >= point.afterPhotos && !state.withLock({ $0.pausePointUsed.contains(wedding) }) ? point : nil
            }
            if stop || pause || pausePoint != nil || Task.isCancelled {
                flush(inFlight: 0)
                let phase: JobPhase
                if stop { phase = .stopped } else if pause || Task.isCancelled { phase = .paused(.user) } else { phase = .paused(pausePoint!.reason) }
                state.withLock {
                    if pausePoint != nil { $0.pausePointUsed.insert(wedding) }
                    $0.pauseRequested.remove(wedding)
                    $0.stopRequested.remove(wedding)
                }
                continuation.yield(.phase(wedding, phase))
                continuation.finish()
                return
            }
            if configuration.secondsPerPhoto > 0 { try? await Task.sleep(for: .seconds(configuration.secondsPerPhoto)) }
            let results = request.deliveries.map { preset in
                var result = FixtureFactory.result(for: photo, preset: preset, wedding: request.name, count: request.photos.count)
                if let failure = configuration.failures.first(where: { $0.photo == photo.id && ($0.delivery == nil || $0.delivery == preset.id) }) {
                    result = PhotoResult(photo: photo.id, delivery: preset.id, status: .failed(failure.failure), inBytes: photo.byteCount)
                }
                return result
            }
            allResults += results
            pending += results
            doneCount += 1
            let spp = configuration.reportedSecondsPerPhoto
            smoothed = smoothed.map { 0.9 * $0 + 0.1 * spp } ?? spp
            state.withLock { $0.finished[wedding] = allResults }
            let remaining = todo.count - i - 1
            if remaining > 0, ContinuousClock.now - lastFlush >= .milliseconds(100) { flush(inFlight: min(4, remaining)) }
        }
        flush(inFlight: 0)
        state.withLock {
            $0.unfinished[wedding] = nil
            $0.finished[wedding] = nil
        }
        continuation.yield(.phase(wedding, .finished))
        continuation.finish()
    }

    /// A visibly (at 100 %) posterised copy, so Differences has something to show.
    static func degraded(_ image: CGImage, step: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            let row = pixels + y * context.bytesPerRow
            for x in 0..<(image.width * 4) where x & 3 != 3 {
                row[x] = UInt8(min(255, (Int(row[x]) + step / 2) / step * step))
            }
        }
        return context.makeImage() ?? image
    }
}
