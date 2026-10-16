// MetricLane (§3.9): serialises all metric (GPU) work and caps full-resolution searches at three at once (slots;
// since D-ENG-10 they bound the CPU memory of full-size probes, not GPU memory), and full-resolution decodes at two.
// Workers block on it from their own threads.
//
// Waiting for the lane is cancellable: with 8 workers queued behind one GPU, a pause must not wait for every
// queued score (7 × 0.4 s) before the workers notice it, so waiters poll the token and bail out, and a request
// that arrived while waiting is honoured before any GPU work starts (§3.8 pause latency < 1.5 s).
// LiveEngine owns one lane, shared by the running job and by estimates.
//
// Full-resolution references are deferred (D-ENG-10): `withReference` hands out a handle that only keeps the CPU
// pixels the caller holds anyway, and every score rebuilds the GPU pyramid inside the lane, into the metric's pooled
// storage, right before scoring. One 45 MP pyramid (0.73 GB) then exists at a time instead of one per searching
// worker (up to 3 + a pooled spare); the price is one pyramid build (~35 ms GPU) per full-resolution score. The
// pyramid is a deterministic function of the pixels, so the scores are bit-identical to a long-lived reference.
import Foundation

final class MetricLane: Sendable {
    let metric: any PerceptualMetric
    /// References above this many pixels take one of the `maxLiveReferences` slots.
    static let fullResolutionPixels = 8_000_000
    /// References above this many pixels are deferred (built per score): every resized delivery at 2560 px and
    /// the full-size ones; the 2048×1024 search mosaic (scored ~12 times per photo) keeps a live reference.
    static let deferredPixels = 3_000_000
    /// How often a waiting worker re-checks its cancellation token.
    static let pollInterval = 0.02
    /// Full-resolution searches at once (the memory plan sets it per job, `configure`).
    var maxLiveReferences: Int { slots.limit }
    private let gpu = NSLock()
    private let slots: Gate
    /// Full-resolution decodes at once (D-ENG-10): ImageIO decodes a 45 MP JPEG into a second full-size buffer of
    /// its own (177 MB) before it is copied into ours, and malloc keeps those buffers once freed, so the number that
    /// ever ran at once stays in the footprint. Two keep the decodes off the critical path (~0.8 run at once on
    /// average in a four-delivery job).
    static let largeDecodes = 2
    private let decodes: Gate
    private let serialize: Bool
    /// The optional budget shared with archive transcodes (D-ENG-7); full-resolution references reserve from it too.
    let memory: MemoryBudget?
    /// Build full-resolution pyramids per score instead of once per search (see the header).
    let deferFullResolution: Bool

    init(metric: any PerceptualMetric, maxLiveReferences: Int = 3, serialize: Bool = true, memory: MemoryBudget? = nil,
         deferFullResolution: Bool = true, largeDecodes: Int = MetricLane.largeDecodes) {
        self.decodes = Gate(limit: largeDecodes)
        self.metric = metric
        self.deferFullResolution = deferFullResolution
        self.slots = Gate(limit: maxLiveReferences)
        self.serialize = serialize
        self.memory = memory
    }

    /// Sets the full-resolution search slots and decode slots for the next job (`MemoryPlan.fullSlots`). Searches
    /// already holding a slot keep it; a lower limit applies as they finish.
    func configure(fullSlots: Int, decodes: Int) {
        slots.setLimit(fullSlots)
        self.decodes.setLimit(decodes)
    }

    /// Runs `body` with the lane held. With a token, the wait polls it; without one (cleanup) it is unconditional.
    private func locked<T>(_ cancel: CancelToken?, _ body: () throws -> T) throws -> T {
        guard serialize else {
            try cancel?.check()
            return try body()
        }
        try Spans.measure("lane.lockwait") {
            if let cancel {
                while !gpu.lock(before: Date(timeIntervalSinceNow: Self.pollInterval)) { try cancel.check() }
            } else {
                gpu.lock()
            }
        }
        defer { gpu.unlock() }
        try cancel?.check()
        return try Spans.measure("lane.held") { try body() }
    }

    /// Prepares a reference for `image`, runs `body`, and always releases it. Waiting for a slot is cancellable.
    func withReference<T>(_ image: PixelImage, cancel: CancelToken,
                          _ body: (any MetricReference) throws -> T) throws -> T {
        let needsSlot = image.pixelCount > Self.fullResolutionPixels
        if needsSlot {
            MemoryTrace.enter(.fullWait)
            defer { MemoryTrace.leave(.fullWait) }
            try Spans.measure("lane.slotwait") { try slots.enter(cancel: cancel) }
        }
        defer { if needsSlot { slots.leave() } }
        if deferFullResolution, image.pixelCount > Self.deferredPixels {
            return try body(DeferredReference(image))
        }
        func run() throws -> T {
            let reference = try locked(cancel) { try metric.prepareReference(image) }
            defer { try? locked(nil) { metric.release(reference) } }
            return try body(reference)
        }
        guard needsSlot, let memory else { return try run() }
        return try memory.withReservation(Int64(image.pixelCount) * MemoryBudget.referenceBytesPerPixel, cancel: cancel, run)
    }

    /// Runs a decode of an image with `pixels` pixels; above `fullResolutionPixels` it waits (cancellably) for one
    /// of the `largeDecodes` slots.
    func decoding<T>(pixels: Int, cancel: CancelToken, _ body: () throws -> T) throws -> T {
        guard pixels > Self.fullResolutionPixels else { return try body() }
        try Spans.measure("lane.decodewait") { try decodes.enter(cancel: cancel) }
        defer { decodes.leave() }
        return try body()
    }

    func score(_ candidate: PixelImage, against reference: any MetricReference, cancel: CancelToken) throws -> Double {
        try locked(cancel) {
            guard let deferred = reference as? DeferredReference else { return try metric.score(candidate, against: reference) }
            let prepared = try Spans.measure("lane.deferredprepare") { try metric.prepareReference(deferred.image) }
            defer { metric.release(prepared) }
            return try metric.score(candidate, against: prepared)
        }
    }


    /// Drops the metric's pooled buffers (live references are unaffected). Taken under the lane, so no score is
    /// using a pooled working set meanwhile.
    func drainPools() {
        guard let metal = metric as? MetalSSIMULACRA2 else { return }
        _ = try? locked(nil) { metal.drainPools() }
    }

    /// A full-resolution reference whose GPU pyramid is built per score (it keeps the caller's pixels alive).
    private final class DeferredReference: MetricReference, @unchecked Sendable {
        let image: PixelImage
        var width: Int { image.width }
        var height: Int { image.height }
        init(_ image: PixelImage) { self.image = image }
    }
}

/// A counting gate whose limit can change between jobs (a semaphore's cannot). Waiting is cancellable: the waiter
/// re-checks its token every `MetricLane.pollInterval`.
final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var current: Int
    private var inUse = 0

    init(limit: Int) { current = max(1, limit) }

    var limit: Int { condition.withLock { current } }

    func setLimit(_ limit: Int) {
        condition.withLock {
            current = max(1, limit)
            condition.broadcast()
        }
    }

    func enter(cancel: CancelToken) throws {
        condition.lock()
        defer { condition.unlock() }
        while inUse >= current {
            try cancel.check()
            _ = condition.wait(until: Date(timeIntervalSinceNow: MetricLane.pollInterval))
        }
        try cancel.check()
        inUse += 1
    }

    func leave() {
        condition.withLock {
            inUse -= 1
            condition.signal()
        }
    }
}
