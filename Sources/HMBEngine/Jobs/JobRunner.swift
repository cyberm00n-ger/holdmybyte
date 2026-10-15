// One run (or resume) of a job (§3.8, §3.9): sets up folders and the journal, skips finished work, runs the
// photo pipeline on the worker pool, journals every result after its rename, coalesces events and ends with
// exactly one terminal phase.
import Foundation
import HMBModel
import os

struct ResultKey: Hashable, Sendable {
    var photo: Int
    var delivery: String
    init(_ r: PhotoResult) { photo = r.photo.index; delivery = r.delivery.rawValue }
    init(photo: Int, delivery: DeliveryID) { self.photo = photo; self.delivery = delivery.rawValue }
}

final class JobRunner: @unchecked Sendable {
    let request: JobRequest
    let resume: Bool
    let primitives: EnginePrimitives
    let support: URL
    let options: EngineOptions
    let lane: MetricLane
    let cancel = CancelToken()
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let onFinish: @Sendable (JobRunner, JobOutcome) -> Void
    private let completion = Locked<(done: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    private static let log = Logger(subsystem: "eu.sebastianhaas.holdmybyte", category: "job")

    /// What the engine learns from after the run.
    struct JobOutcome: Sendable {
        var phase: JobPhase
        var results: [PhotoResult]          // latest per (photo, delivery), carried + new
        var activeSeconds: Double
        var completedFullScope: Bool
    }

    init(request: JobRequest, resume: Bool, primitives: EnginePrimitives, support: URL, options: EngineOptions,
         lane: MetricLane, continuation: AsyncStream<EngineEvent>.Continuation,
         onFinish: @escaping @Sendable (JobRunner, JobOutcome) -> Void) {
        self.request = request; self.resume = resume; self.primitives = primitives; self.support = support
        self.options = options; self.lane = lane; self.continuation = continuation; self.onFinish = onFinish
    }

    func start() {
        let thread = Thread { [self] in main() }
        thread.stackSize = 8 << 20
        thread.qualityOfService = WorkerPool.qos(request.processorUse)
        thread.name = "holdmybyte job"
        thread.start()
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = completion.withLock { state -> Bool in
                if state.done { return true }
                state.waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    // MARK: Run

    private struct RunState {
        var results: [ResultKey: PhotoResult] = [:]
        var pending: [PhotoResult] = []
        var remaining: [Int: Int] = [:]          // photo index → deliveries still to do in this run
        var photosDone = 0
        var inFlight = 0
        var rate: PhotoRate
        var newResults = 0
    }

    private func main() {
        let started = monotonicSeconds()
        var outcome = JobOutcome(phase: .failed(reason: "The job could not start."), results: [], activeSeconds: 0,
                                 completedFullScope: false)
        do {
            outcome = try execute(started: started)
        } catch {
            Self.log.error("job failed: \(String(describing: error), privacy: .public)")
            outcome.phase = .failed(reason: Self.reason(for: error))
        }
        outcome.activeSeconds = monotonicSeconds() - started
        onFinish(self, outcome)                         // unregister first, so the next job can start at once
        continuation.yield(.phase(request.wedding, outcome.phase))
        continuation.finish()
        let waiters = completion.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.done = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for w in waiters { w.resume() }
    }

    static func reason(for error: any Error) -> String {
        switch error {
        case OutputError.wouldTouchSource: "The delivery folder would be inside a source folder."
        case OutputError.notWritable(let p): "holdmybyte can’t write to “\((p as NSString).lastPathComponent)”."
        case OutputError.diskFull: "The output disk is full."
        case let e as SetupError: e.description
        default: "Unexpected error: \(error)"
        }
    }

    struct SetupError: Error, CustomStringConvertible { var description: String }

    private func execute(started: Double) throws -> JobOutcome {
        let wedding = request.wedding
        let fm = FileManager.default
        let scopeIDs = request.onlyPhotos
        let scope = request.photos.filter { scopeIDs?.contains($0.id) ?? true }
        let guardian = SourceGuard(sourceRoots: request.sourceRoots, sourceFiles: request.photos.map(\.url))
        let writer = OutputWriter(guardian: guardian, faultHook: options.writeFaultHook, afterRename: options.afterRenameHook)
        let output = request.outputFolder.standardizedFileURL
        if guardian.touches(output) { throw OutputError.wouldTouchSource(output.path) }

        continuation.yield(.phase(wedding, .running))

        // Output folder and delivery folders (resolved once, remembered in layout.json for resumes).
        let previous = resume ? Journal.load(support: support, wedding: wedding) : nil
        let appendMode = resume || request.appendToExistingFolder || request.onlyPhotos != nil
        // Retries and Create More reuse the folder names an earlier run of this wedding resolved ("Couple 2").
        let earlierLayout = previous?.layout ?? (appendMode ? Journal.load(support: support, wedding: wedding)?.layout : nil)
        // Only a resume or a retry writes into a delivery folder that is already there without a record of it;
        // Create More adds new delivery folders, with " 2" on a clash (§2.0 principle 5, S5).
        let reuseUnknownFolders = resume || request.onlyPhotos != nil
        let outputExisted = fm.fileExists(atPath: output.path)
        if outputExisted, !appendMode {
            let contents = (try? fm.contentsOfDirectory(atPath: output.path))?.filter { !$0.hasPrefix(".") } ?? []
            guard contents.isEmpty else {
                throw SetupError(description: "The folder “\(output.lastPathComponent)” already exists. Choose the location again.")
            }
        }
        do {
            try writer.createDirectoryChain(output)
        } catch let error as OutputError {
            if let pause = pauseReason(for: error, remainingBytes: nil) { return paused(pause, results: [:]) }
            throw error
        }
        var folders: [String: String] = [:]
        for preset in request.deliveries {
            if let known = earlierLayout?.deliveryFolders[preset.id.rawValue],
               fm.fileExists(atPath: output.appending(path: known, directoryHint: .isDirectory).path) {
                folders[preset.id.rawValue] = known
                continue
            }
            do {
                folders[preset.id.rawValue] = try writer.makeDirectory(in: output, named: preset.folderName,
                                                                      reuseExisting: reuseUnknownFolders)
            } catch let error as OutputError {
                if let pause = pauseReason(for: error, remainingBytes: nil) { return paused(pause, results: [:]) }
                throw error
            }
        }
        let layout = JobLayout(deliveryFolders: (earlierLayout?.deliveryFolders ?? [:]).merging(folders) { _, new in new },
                               createdOutputFolder: earlierLayout?.createdOutputFolder ?? !outputExisted)
        let journal: Journal
        if resume, previous != nil, let reopened = try Journal.reopen(support: support, wedding: wedding, layout: layout,
                                                                       request: request) {
            journal = reopened
        } else {
            journal = try Journal.create(support: support, request: request, layout: layout)
        }
        defer { journal.close() }

        // Plans and the work list.
        let stems = Self.stems(request: request)
        let plans = request.deliveries.sorted(by: DeliveryPlan.executionOrder).map { preset in
            let folder = folders[preset.id.rawValue] ?? preset.folderName
            return DeliveryPlan(preset: preset, folderName: folder,
                                directory: output.appending(path: folder, directoryHint: .isDirectory), stems: stems)
        }
        for plan in plans { writer.cleanPartial(in: plan.directory, removeDirectory: false) }   // crash leftovers

        var carried: [ResultKey: PhotoResult] = [:]
        if let previous {
            var latest: [ResultKey: PhotoResult] = [:]
            for r in previous.results { latest[ResultKey(r)] = r }
            for (key, r) in latest where Self.isStillDelivered(r, output: output) { carried[key] = r }
        }
        var openPlans: [Int: [DeliveryPlan]] = [:]
        for photo in scope {
            let open = plans.filter { carried[ResultKey(photo: photo.id.index, delivery: $0.preset.id)] == nil }
            if !open.isEmpty { openPlans[photo.id.index] = open }
        }
        let todo = openPlans
        let workers = min(max(1, todo.count), options.workerCount ?? WorkerPool.workerCount(request.processorUse))
        let state = Locked(RunState(rate: PhotoRate(start: started, parallelism: workers)))
        state.withLock { s in
            s.results = carried
            for (index, open) in todo { s.remaining[index] = open.count }
            s.photosDone = scope.count - todo.count
        }
        let carriedInScope = carried.values.filter { r in scope.contains { $0.id == r.photo } }
        // Carried results go out with the first (forced) emission, through the coalescer.
        state.withLock { $0.pending = carriedInScope.sorted { ($0.photo, $0.delivery.rawValue) < ($1.photo, $1.delivery.rawValue) } }

        let context = PipelineContext(primitives: primitives, lane: lane, writer: writer, constants: options.constants,
                                      outputFolder: output, sourceRoots: request.sourceRoots, cancel: cancel, adoptIdentical: appendMode)
        let pipeline = PhotoPipeline(context: context)
        let photosByIndex = Dictionary(uniqueKeysWithValues: scope.map { ($0.id.index, $0) })
        let order = scope.map(\.id.index).filter { todo[$0] != nil }
        let cancel = self.cancel
        let remainingBytes: @Sendable () -> Int64 = { [state] in
            Self.remainingBytes(state: state.snapshot, scope: scope, plans: plans)
        }

        let pool = WorkerPool(items: order, count: workers, qos: WorkerPool.qos(request.processorUse), name: "holdmybyte worker",
                              shouldContinue: { !cancel.isCancelled }) { [self] index, _ in
            guard let photo = photosByIndex[index], let open = todo[index] else { return }
            state.withLock { $0.inFlight += 1 }
            defer { state.withLock { $0.inFlight -= 1 } }
            var recorded = Set<DeliveryID>()
            func record(_ result: PhotoResult) throws {
                try journal.append(result)
                recorded.insert(result.delivery)
                state.withLock { s in
                    s.results[ResultKey(result)] = result
                    s.pending.append(result)
                    s.newResults += 1
                    let left = (s.remaining[index] ?? 1) - 1
                    s.remaining[index] = left
                    if left == 0 { s.photosDone += 1; s.rate.photoFinished(at: monotonicSeconds()) }
                }
            }
            do {
                try pipeline.process(photo, plans: open, emit: record)
            } catch is JobCancelled {
                // pause/stop: the photo's unfinished deliveries are redone on resume
            } catch let interruption as JobInterruption {
                cancel.request(.pause(self.pauseReason(for: interruption, remainingBytes: remainingBytes())))
            } catch let error as OutputError {
                if let reason = self.pauseReason(for: error, remainingBytes: remainingBytes()) {
                    cancel.request(.pause(reason))
                } else {
                    Self.log.error("journal write failed: \(error.description, privacy: .public)")
                    cancel.request(.pause(.outputNotWritable(path: journal.directory.path)))
                }
            } catch {
                // Not expected (the pipeline turns every per-delivery problem into a result); never leave a pair
                // silently missing: the rest of this photo is listed as an encode failure.
                Self.log.error("unexpected error on \(photo.relativePath, privacy: .public): \(String(describing: error), privacy: .public)")
                for plan in open where !recorded.contains(plan.preset.id) {
                    try? record(PhotoResult(photo: photo.id, delivery: plan.preset.id, status: .failed(.encodeFailed),
                                            inBytes: photo.byteCount))
                }
            }
        }

        var coalescer = ProgressCoalescer()
        emit(&coalescer, state: state, scope: scope, force: true)
        pool.start()
        while !pool.wait(timeout: 0.05) { emit(&coalescer, state: state, scope: scope, force: false) }
        if state.withLock({ !$0.pending.isEmpty }) {
            Thread.sleep(forTimeInterval: coalescer.delayBeforeFlush(now: monotonicSeconds()))
        }
        emit(&coalescer, state: state, scope: scope, force: true)
        journal.sync()

        let final = state.snapshot
        if let stopRequest = cancel.current {
            for plan in plans { writer.cleanPartial(in: plan.directory, removeDirectory: true) }
            switch stopRequest {
            case .pause(let reason): return paused(reason, results: final.results)
            case .stop: return JobOutcome(phase: .stopped, results: Array(final.results.values), activeSeconds: 0,
                                          completedFullScope: false)
            }
        }
        for plan in plans { writer.cleanPartial(in: plan.directory, removeDirectory: true) }
        try journal.markFinished()
        let inScope = final.results.values.filter { r in photosByIndex[r.photo.index] != nil }
        let delivered = inScope.contains { $0.status == .done || $0.status == .keptOriginal }
        if !delivered, !inScope.isEmpty {
            return JobOutcome(phase: .failed(reason: Self.nothingDeliveredReason(inScope)), results: Array(final.results.values),
                              activeSeconds: 0, completedFullScope: false)
        }
        return JobOutcome(phase: .finished, results: Array(final.results.values), activeSeconds: 0,
                          completedFullScope: request.onlyPhotos == nil && carried.isEmpty)
    }

    private func paused(_ reason: PauseReason, results: [ResultKey: PhotoResult]) -> JobOutcome {
        JobOutcome(phase: .paused(reason), results: Array(results.values), activeSeconds: 0, completedFullScope: false)
    }

    private func emit(_ coalescer: inout ProgressCoalescer, state: Locked<RunState>, scope: [SourcePhoto], force: Bool) {
        let now = monotonicSeconds()
        let (decision, pending, progress) = state.withLock { s -> (ProgressCoalescer.Emission, [PhotoResult], JobProgress?) in
            let decision = coalescer.tick(now: now, hasPending: !s.pending.isEmpty, force: force)
            guard decision != .none else { return (.none, [], nil) }
            let pending = decision == .resultsAndProgress ? s.pending : []
            if decision == .resultsAndProgress { s.pending = [] }
            let remaining = scope.count - s.photosDone
            let progress = JobProgress(
                wedding: request.wedding, photosDone: s.photosDone, photosTotal: scope.count, photosInFlight: s.inFlight,
                secondsPerPhoto: s.rate.secondsPerPhoto, etaSeconds: s.rate.eta(remaining: remaining),
                summaries: request.deliveries.map { preset in
                    DeliverySummary.make(preset: preset, photos: scope,
                                         results: s.results.values.filter { $0.delivery == preset.id })
                })
            return (decision, pending, progress)
        }
        if decision == .resultsAndProgress, !pending.isEmpty { continuation.yield(.results(request.wedding, pending)) }
        if let progress { continuation.yield(.progress(progress)) }
    }

    // MARK: Helpers

    /// Deterministic file stems for every photo of the request (capture order), de-duplicated case-insensitively.
    static func stems(request: JobRequest) -> [Int: String] {
        var used = Set<String>()
        var stems: [Int: String] = [:]
        for photo in request.photos.sorted(by: { $0.id < $1.id }) {
            let base: String
            if request.naming.renameByCaptureTime {
                base = HMBFormat.fileName(pattern: request.naming.pattern, wedding: request.name, number: photo.id.index + 1,
                                          count: request.photos.count, ext: "")
            } else {
                base = photo.url.deletingPathExtension().lastPathComponent
            }
            var safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            while safe.hasPrefix(".") { safe.removeFirst() }
            if safe.isEmpty { safe = String(format: "%04d", photo.id.index + 1) }
            var candidate = safe, n = 2
            while used.contains(candidate.lowercased()) { candidate = "\(safe) \(n)"; n += 1 }
            used.insert(candidate.lowercased())
            stems[photo.id.index] = candidate
        }
        return stems
    }

    /// A journaled pair counts as finished only if its file is still there with the journaled size (§3.8 Resume).
    static func isStillDelivered(_ r: PhotoResult, output: URL) -> Bool {
        guard r.status == .done || r.status == .keptOriginal, let rel = r.outRelativePath, let bytes = r.outBytes else {
            return false
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: output.appending(path: rel).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == bytes
    }

    func pauseReason(for interruption: JobInterruption, remainingBytes: Int64) -> PauseReason {
        switch interruption {
        case .sourceUnavailable(let volume): .sourceUnavailable(volume: volume)
        case .diskFull: .diskFull(volume: SourceAvailability.volumeName(for: request.outputFolder), neededBytes: remainingBytes)
        case .outputNotWritable(let path): .outputNotWritable(path: path)
        }
    }

    func pauseReason(for error: OutputError, remainingBytes: Int64?) -> PauseReason? {
        switch error {
        case .diskFull: .diskFull(volume: SourceAvailability.volumeName(for: request.outputFolder),
                                  neededBytes: remainingBytes ?? Estimator.roughBytes(photos: request.photos, deliveries: request.deliveries))
        case .notWritable(let path): .outputNotWritable(path: path)
        default: nil
        }
    }

    /// Remaining output estimate for the disk-full banner: the average output per finished pair of each delivery
    /// times its open pairs (rough estimate before the first result).
    private static func remainingBytes(state: RunState, scope: [SourcePhoto], plans: [DeliveryPlan]) -> Int64 {
        var total: Int64 = 0
        for plan in plans {
            let done = state.results.values.filter { $0.delivery == plan.preset.id && $0.outBytes != nil }
            let open = scope.filter { state.results[ResultKey(photo: $0.id.index, delivery: plan.preset.id)] == nil }
            guard !open.isEmpty else { continue }
            if done.isEmpty {
                total += Estimator.roughBytes(photos: open, deliveries: [plan.preset])
            } else {
                let average = done.reduce(Int64(0)) { $0 + ($1.outBytes ?? 0) } / Int64(done.count)
                total += average * Int64(open.count)
            }
        }
        return total
    }

    static func nothingDeliveredReason(_ results: [PhotoResult]) -> String {
        var counts: [PhotoFailure: Int] = [:]
        for r in results { if case .failed(let f) = r.status { counts[f, default: 0] += 1 } }
        let top = counts.max { $0.value < $1.value }?.key
        switch top {
        case .unreadable: return "None of the photos could be read."
        case .sourceMissing: return "The photos are no longer in the wedding folder."
        case .cmykUnsupported: return "All photos are CMYK, which isn’t supported yet."
        case .writeFailed: return "No photo could be saved to the delivery folder."
        case .qualityUnreachable: return "No photo reached its quality target."
        case .encodeFailed, nil: return "No photo could be compressed."
        }
    }
}
