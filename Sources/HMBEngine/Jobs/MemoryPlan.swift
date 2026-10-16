// MemoryPlan (§3.9 memory budget, Docs/DECISIONS.md D-ENG-10): how many workers a job runs and how many of them may
// transcode archives at once, from the Mac's memory and the size of the job's largest photo.
//
// A job's work comes in two kinds (JobRunner): a photo's lossy deliveries and its archive. The plan's model of peak
// memory, fitted to the 45 MP wedding (Docs/ENGINE.md §8):
//
//   peak ≈ base + pools + archives · archive + lossy · lossyWorker + min(lossy, full slots) · fullSearch
//
//   base         0.3 GB      process, codecs, the resized and mosaic metric pools, mapped source files
//   pools        32 B/px     the metric's pooled full-size working set and reference pyramid (one each, D-ENG-10)
//   archive      30 B/px     one libjxl transcode + verification (1.35 GB at 45 MP)
//   lossyWorker   6 B/px     decoded source plus resized variants and their probes
//   fullSearch    5 B/px     candidate decode + jpegli coefficients of a full-size probe (MetricLane slots); 6 B/px
//                            until the candidate was decoded straight into ImageIO's own buffer (speed variant)
//
// Full-size search slots (speed variant): every lossy worker may search at once while the model fits; otherwise the
// slots go down to `minimumFullSlots` (the earlier fixed 3) before a worker is dropped. With the fixed 3, a
// Couple's Package job ran 3 searches on 8 workers and left most cores idle (holdout: 2.4 of 10 busy).
// The budget is the §3.9 8 GB, but at most half the Mac's memory. In a job with both kinds, archives get ~3/8 of the
// workers (they are ~40 % of a four-delivery job's CPU time); an archive-only job has no metric pools and gives every
// worker to archives; workers are dropped until the model fits the budget. Admission (WorkerPool): archives up to
// `archiveLanes` while lossy work is queued, the pool hands the other workers lossy items. Once every lossy item has
// finished, the job drains the metric pools (JobRunner) and archives may take what the lossy workers and the pools
// gave back, so the tail of the job is not left to a few lanes.
import Foundation

struct MemoryPlan: Sendable, CustomStringConvertible {
    static let archiveKind = 0
    static let lossyKind = 1

    static let gigabyte: Int64 = 1_000_000_000
    /// §3.9: peak memory at 8 workers on 45 MP input.
    static let specBudget: Int64 = 8 * gigabyte
    static let baseBytes: Int64 = 300_000_000
    static let poolBytesPerPixel: Int64 = 32
    static let archiveBytesPerPixel: Int64 = 30
    static let lossyBytesPerPixel: Int64 = 6
    static let fullSearchBytesPerPixel: Int64 = 5
    /// Fewest full-size search slots the plan gives a job with lossy work (the pre-speed fixed value).
    static let minimumFullSlots = 3

    var budget: Int64
    var hasArchive: Bool
    var hasLossy: Bool
    var workers: Int
    /// Archives at once while lossy work is still queued.
    var archiveLanes: Int
    /// Full-size searches at once (MetricLane slots).
    var fullSlots: Int
    var pixels: Int64

    /// - Parameters:
    ///   - workers: the processor-use worker count (or the caller's explicit count), an upper bound.
    ///   - largestPixels: pixel count of the largest photo of the job.
    init(options: EngineOptions, workers: Int, largestPixels: Int, archive: Bool, lossy: Bool,
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let px = Int64(max(largestPixels, 1))
        pixels = px
        hasArchive = archive
        hasLossy = lossy
        let budget = min(Self.specBudget, Int64(min(physicalMemory / 2, UInt64(Int64.max))))
        self.budget = budget
        var w = max(1, workers)
        func lanes(_ w: Int) -> Int {
            guard archive else { return 0 }
            guard lossy else { return w }
            if let fixed = options.archiveConcurrency { return min(w, max(1, fixed)) }
            return max(1, Int((Double(w) * 3 / 8).rounded()))
        }
        // Slots: every lossy worker, or as given. Then fewer slots (down to the minimum), then fewer workers, until
        // the model fits (never below one worker); an explicit lane count is a tuning run: workers as given.
        var slots = options.maxLiveReferences.map { max(1, $0) } ?? max(Self.minimumFullSlots, w - lanes(w))
        func fits() -> Bool {
            Self.peak(archives: lanes(w), lossy: w - lanes(w), pools: lossy, fullSlots: slots, pixels: px) <= budget
        }
        while !fits() {
            if options.maxLiveReferences == nil, slots > Self.minimumFullSlots {
                slots -= 1
                continue
            }
            guard options.archiveConcurrency == nil, w > 1 else { break }
            w -= 1
        }
        self.workers = w
        archiveLanes = lanes(w)
        fullSlots = slots
    }

    /// The model's peak for the given running items.
    static func peak(archives: Int, lossy: Int, pools: Bool, fullSlots: Int, pixels: Int64) -> Int64 {
        baseBytes + pixels * ((pools ? poolBytesPerPixel : 0) + Int64(archives) * archiveBytesPerPixel
                              + Int64(lossy) * lossyBytesPerPixel + Int64(min(lossy, fullSlots)) * fullSearchBytesPerPixel)
    }

    var plannedPeak: Int64 {
        Self.peak(archives: archiveLanes, lossy: workers - archiveLanes, pools: hasLossy, fullSlots: fullSlots, pixels: pixels)
    }

    /// `WorkerPool` admission: lossy items always (the worker count bounds them); archives within their lanes, and
    /// after the last lossy item has started, as long as the model with the running items stays within the plan.
    func admit(_ kind: Int, _ load: WorkerPool.Load) -> Bool {
        guard kind == Self.archiveKind else { return true }
        let archives = load.running[Self.archiveKind]
        if archives < archiveLanes { return true }
        guard load.queued[Self.lossyKind] == 0 else { return false }
        let lossy = load.running[Self.lossyKind]
        // The pools are drained once no lossy item runs any more (JobRunner).
        return Self.peak(archives: archives + 1, lossy: lossy, pools: lossy > 0, fullSlots: fullSlots, pixels: pixels)
            <= plannedPeak
    }

    var description: String {
        String(format: "%d workers, %d archive lanes, %d full-size slots, planned peak %.2f GB of %.2f GB (%.1f MP)", workers, archiveLanes, fullSlots,
               Double(plannedPeak) / 1e9, Double(budget) / 1e9, Double(pixels) / 1e6)
    }
}
