// MetricLane (§3.9): serialises all metric (GPU) work, and caps live full-resolution references at three
// (one 45 MP reference is about 1.6 GB of GPU memory). Workers block on it from their own threads.
import Foundation

final class MetricLane: Sendable {
    let metric: any PerceptualMetric
    /// References above this many pixels take one of the `maxLiveReferences` slots.
    static let fullResolutionPixels = 8_000_000
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

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        guard serialize else { return try body() }
        gpu.lock()
        defer { gpu.unlock() }
        return try body()
    }

    /// Prepares a reference for `image`, runs `body`, and always releases it. Waiting for a slot is cancellable.
    func withReference<T>(_ image: PixelImage, cancel: CancelToken,
                          _ body: (any MetricReference) throws -> T) throws -> T {
        let needsSlot = image.pixelCount > Self.fullResolutionPixels
        if needsSlot {
            while slots.wait(timeout: .now() + 0.05) == .timedOut { try cancel.check() }
        }
        defer { if needsSlot { slots.signal() } }
        let reference = try locked { try metric.prepareReference(image) }
        defer { locked { metric.release(reference) } }
        return try body(reference)
    }

    func score(_ candidate: PixelImage, against reference: any MetricReference) throws -> Double {
        try locked { try metric.score(candidate, against: reference) }
    }
}
