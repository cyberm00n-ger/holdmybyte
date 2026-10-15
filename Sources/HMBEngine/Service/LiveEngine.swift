// The live engine (§3.1): scanning, estimates, preflight, jobs with journal/resume, and compare pairs.
// All heavy work runs on dedicated threads; the Swift cooperative pool only sees streams and continuations.
import Foundation
import HMBModel
import os

public final class LiveEngine: EngineService {
    public let primitives: EnginePrimitives
    public let supportDirectory: URL
    public let options: EngineOptions

    /// The one metric lane (§3.9): every GPU call of jobs and estimates goes through it.
    let lane: MetricLane
    private let active = Locked<JobRunner?>(nil)
    /// Last estimate per photo set (fingerprint), for preflight and for folding actual/estimated into κ.
    private let estimateRecords = Locked<[String: [DeliveryID: Estimator.Record]]>([:])
    private static let log = Logger(subsystem: "eu.sebastianhaas.holdmybyte", category: "engine")

    /// `<Application Support>/holdmybyte`
    public static var defaultSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "holdmybyte", directoryHint: .isDirectory)
    }

    public init(primitives: EnginePrimitives, supportDirectory: URL = LiveEngine.defaultSupportDirectory,
                options: EngineOptions = EngineOptions()) {
        self.primitives = primitives
        self.supportDirectory = supportDirectory
        self.options = options
        self.lane = MetricLane(metric: primitives.metric, maxLiveReferences: options.maxLiveReferences,
                               serialize: options.serializeMetric)
    }

    /// The production engine: live primitives (WP1).
    public convenience init(supportDirectory: URL = LiveEngine.defaultSupportDirectory) throws {
        self.init(primitives: try .live(), supportDirectory: supportDirectory)
    }

    var learned: LearnedEstimates { LearnedEstimates(suite: options.learnedEstimatesSuite) }

    // MARK: Scan

    public func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let cancelled = Locked(false)
            continuation.onTermination = { _ in cancelled.withLock { $0 = true } }
            let thread = Thread {
                let result = Scanner().scan(items, isCancelled: { cancelled.snapshot }) { found in
                    continuation.yield(.progress(found: found))
                }
                continuation.yield(.finished(result))
                continuation.finish()
            }
            thread.qualityOfService = .userInitiated
            thread.name = "holdmybyte scan"
            thread.start()
        }
    }

    // MARK: Estimate

    public func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] {
        let token = CancelToken()
        let estimator = Estimator(primitives: primitives, constants: options.constants, learned: learned,
                                  concurrency: options.estimateConcurrency, lane: lane)
        let (estimates, records) = try await withTaskCancellationHandler {
            try await onDedicatedThread(name: "holdmybyte estimate") {
                try estimator.estimate(photos: photos, deliveries: deliveries, cancel: token)
            }
        } onCancel: {
            token.request(.stop)
        }
        try Task.checkCancellation()
        let key = Self.fingerprint(photos)
        estimateRecords.withLock { all in all[key, default: [:]].merge(records) { _, new in new } }
        return estimates
    }

    static func fingerprint(_ photos: [SourcePhoto]) -> String {
        var hasher = Hasher()
        for p in photos { hasher.combine(p.url.path); hasher.combine(p.byteCount) }
        // Hasher is seeded per process; fingerprints only live in memory.
        return "\(photos.count)-\(hasher.finalize())"
    }

    // MARK: Preflight

    public func preflight(_ request: JobRequest) async -> Preflight {
        let records = estimateRecords.withLock { $0[Self.fingerprint(request.photos)] } ?? [:]
        var estimated: Int64? = nil
        if request.deliveries.allSatisfy({ records[$0.id] != nil }) {
            let total = request.deliveries.reduce(Int64(0)) { $0 + (records[$1.id]?.bytes ?? 0) }
            let scoped = PreflightCheck.scope(request).count
            estimated = request.photos.isEmpty ? total : total * Int64(scoped) / Int64(request.photos.count)
        }
        let estimate = estimated
        return (try? await onDedicatedThread(name: "holdmybyte preflight") {
            PreflightCheck.run(request, estimatedBytes: estimate)
        }) ?? Preflight(outputFolder: request.outputFolder, estimatedBytes: estimate, notices: [])
    }

    // MARK: Jobs

    public func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let runner = JobRunner(request: request, resume: resume, primitives: primitives, support: supportDirectory,
                                   options: options, lane: lane, continuation: continuation) { [weak self] runner, outcome in
                self?.finished(runner, outcome: outcome)
            }
            let accepted = active.withLock { current -> Bool in
                guard current == nil else { return false }
                current = runner
                return true
            }
            guard accepted else {
                continuation.yield(.phase(request.wedding, .failed(reason: "Another job is running. Jobs run one at a time.")))
                continuation.finish()
                return
            }
            runner.start()
        }
    }

    private func finished(_ runner: JobRunner, outcome: JobRunner.JobOutcome) {
        active.withLock { if $0 === runner { $0 = nil } }
        guard outcome.phase == .finished, outcome.completedFullScope else { return }
        learn(from: runner.request, results: outcome.results, activeSeconds: outcome.activeSeconds)
    }

    /// Folds actual/estimated bytes into κ and the measured wall time per photo into the time EMA (§3.10).
    func learn(from request: JobRequest, results: [PhotoResult], activeSeconds: Double) {
        let records = estimateRecords.withLock { $0[Self.fingerprint(request.photos)] } ?? [:]
        let learned = self.learned
        let totalWorker = results.reduce(0) { $0 + $1.seconds }
        let n = Double(max(1, request.photos.count))
        for preset in request.deliveries {
            let mine = results.filter { $0.delivery == preset.id }
            let kind = DeliveryKind(preset)
            if let record = records[preset.id] {
                let actual = mine.filter { $0.status == .done || $0.status == .keptOriginal }.reduce(Int64(0)) { $0 + ($1.outBytes ?? 0) }
                learned.foldBytes(kind, actual: actual, estimated: record.bytes, kappaUsed: record.kappa)
            }
            if totalWorker > 0, request.photos.count >= 12 {
                let share = mine.reduce(0) { $0 + $1.seconds } / totalWorker
                learned.foldSeconds(kind, secondsPerPhoto: activeSeconds / n * share)
            }
        }
    }

    private func runner(for wedding: WeddingID) -> JobRunner? {
        active.withLock { $0?.request.wedding == wedding ? $0 : nil }
    }

    public func pause(_ wedding: WeddingID) async {
        guard let runner = runner(for: wedding) else { return }
        runner.cancel.request(.pause(.user))
        await runner.waitUntilFinished()
    }

    public func stop(_ wedding: WeddingID) async {
        guard let runner = runner(for: wedding) else { return }
        runner.cancel.request(.stop)
        await runner.waitUntilFinished()
    }

    public func unfinishedJobs() async -> [UnfinishedJob] {
        let running = active.withLock { $0?.request.wedding }
        return Journal.unfinished(support: supportDirectory)
            .filter { $0.request.wedding != running }
            .map { contents in
                var latest: [ResultKey: PhotoResult] = [:]
                var order: [ResultKey] = []
                for r in contents.results {
                    let key = ResultKey(r)
                    if latest[key] == nil { order.append(key) }
                    latest[key] = r
                }
                return UnfinishedJob(request: contents.request, results: order.compactMap { latest[$0] })
            }
    }

    public func discardJournal(_ wedding: WeddingID) async {
        guard runner(for: wedding) == nil else {
            Self.log.error("refusing to discard the journal of the running job \(wedding.description, privacy: .public)")
            return
        }
        Journal.discard(support: supportDirectory, wedding: wedding)
    }

    // MARK: Compare

    public func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID,
                            maxPixelSize: Int?) async throws -> ComparePair {
        let loader = CompareLoader(primitives: primitives)
        return try await onDedicatedThread(name: "holdmybyte compare") {
            try loader.pair(record: record, photo: photo, delivery: delivery, maxPixelSize: maxPixelSize)
        }
    }
}
