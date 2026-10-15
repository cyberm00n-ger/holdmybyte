// MemoryBudget (§3.9 memory budget, Docs/DECISIONS.md D-ENG-7): an optional weighted budget shared by the two
// allocations that are each larger than a gigabyte at 45 MP, a full-resolution metric reference (~36 B/px, 1.6 GB) and
// a libjxl lossless JPEG transcode (~33 B/px, 1.5 GB measured; the effort does not change it). Off by default: it caps
// an Archive-only job (holdout, 8 workers: 12.5 → 8.5 GB peak RSS at 6.4 GB) but costs ×1.5 wall time there (G6), and
// it does not bring the all-four job under G7's 8 GB (the lossy workers alone need about that; Docs/BENCHMARKS.md).
// `EngineOptions.memoryBudget` / `HMB_MEMORY_BUDGET` turn it on for tuning runs.
//
// A worker holds at most one reservation at a time (a reference is released before the archive starts, and the
// mosaic reference stays below the reservation threshold), so the budget cannot deadlock. A reservation larger than
// the whole budget runs alone. Waiting polls the cancellation token like the metric lane (§3.8 pause latency).
import Foundation

final class MemoryBudget: @unchecked Sendable {
    /// Bytes per pixel reserved for a full-resolution metric reference (§3.9: one 45 MP reference ≈ 1.6 GB).
    static let referenceBytesPerPixel: Int64 = 36
    /// Bytes per pixel reserved for a lossless JPEG → JPEG XL transcode plus its verification (45 MP: 1.5 GB).
    static let transcodeBytesPerPixel: Int64 = 33

    let capacity: Int64
    private let condition = NSCondition()
    private var used: Int64 = 0
    private var peak: Int64 = 0

    init(capacity: Int64) { self.capacity = max(1, capacity) }

    /// The largest amount reserved at once so far (tests and diagnostics).
    var peakReserved: Int64 { condition.lock(); defer { condition.unlock() }; return peak }

    /// Runs `body` with `bytes` reserved. Waits while the reservation would exceed the capacity and anything else is
    /// reserved; with a token the wait polls it and throws `JobCancelled`.
    func withReservation<T>(_ bytes: Int64, cancel: CancelToken?, _ body: () throws -> T) throws -> T {
        let amount = max(0, bytes)
        guard amount > 0 else { return try body() }
        condition.lock()
        while used > 0, used + amount > capacity {
            if let cancel {
                condition.unlock()
                try cancel.check()                    // throws with the lock released
                condition.lock()
                guard used > 0, used + amount > capacity else { break }
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: MetricLane.pollInterval))
        }
        used += amount
        peak = max(peak, used)
        condition.unlock()
        defer {
            condition.lock()
            used -= amount
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }
}
