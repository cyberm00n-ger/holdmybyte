// MetricLane (§3.9): serialises all metric (GPU) work, and caps live full-resolution references at three
// (one 45 MP reference is about 1.6 GB of GPU memory). Workers block on it from their own threads.
//
// Waiting for the lane is cancellable: with 8 workers queued behind one GPU, a pause must not wait for every
// queued score (7 × 0.4 s) before the workers notice it, so waiters poll the token and bail out, and a request
// that arrived while waiting is honoured before any GPU work starts (§3.8 pause latency < 1.5 s).
// LiveEngine owns one lane, shared by the running job and by estimates.
import Foundation

final class MetricLane: Sendable {
    let metric: any PerceptualMetric
    /// References above this many pixels take one of the `maxLiveReferences` slots.
    static let fullResolutionPixels = 8_000_000
    /// How often a waiting worker re-checks its cancellation token.
    static let pollInterval = 0.02
    let maxLiveReferences: Int
    private let gpu = NSLock()
    private let slots: DispatchSemaphore
    private let serialize: Bool

    init(metric: any PerceptualMetric, maxLiveReferences: Int = 3, serialize: Bool = true) {
        self.metric = metric
        self.maxLiveReferences = maxLiveReferences
        self.slots = DispatchSemaphore(value: maxLiveReferences)
        self.serialize = serialize
    }

    /// Runs `body` with the lane held. With a token, the wait polls it; without one (cleanup) it is unconditional.
    private func locked<T>(_ cancel: CancelToken?, _ body: () throws -> T) throws -> T {
        guard serialize else {
            try cancel?.check()
            return try body()
        }
        if let cancel {
            while !gpu.lock(before: Date(timeIntervalSinceNow: Self.pollInterval)) { try cancel.check() }
        } else {
            gpu.lock()
        }
        defer { gpu.unlock() }
        try cancel?.check()
        return try body()
    }

    /// Prepares a reference for `image`, runs `body`, and always releases it. Waiting for a slot is cancellable.
    func withReference<T>(_ image: PixelImage, cancel: CancelToken,
                          _ body: (any MetricReference) throws -> T) throws -> T {
        let needsSlot = image.pixelCount > Self.fullResolutionPixels
        if needsSlot {
            while slots.wait(timeout: .now() + Self.pollInterval) == .timedOut { try cancel.check() }
        }
        defer { if needsSlot { slots.signal() } }
        let reference = try locked(cancel) { try metric.prepareReference(image) }
        defer { try? locked(nil) { metric.release(reference) } }
        return try body(reference)
    }

    func score(_ candidate: PixelImage, against reference: any MetricReference, cancel: CancelToken) throws -> Double {
        try locked(cancel) { try metric.score(candidate, against: reference) }
    }
}
