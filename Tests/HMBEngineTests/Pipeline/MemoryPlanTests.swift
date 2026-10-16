// §3.9 memory budget (Docs/DECISIONS.md D-ENG-10): the memory plan, the two-kind worker pool and deferred metric
// references. Fakes only; the live numbers are in Docs/ENGINE.md §8.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBModel
import Synchronization
import Testing

@Suite struct MemoryPlanTests {
    static let wedding = 8256 * 5504                 // 45.4 MP
    static let gb: UInt64 = 1_000_000_000

    func plan(workers: Int = 8, pixels: Int = wedding, archive: Bool = true, lossy: Bool = true,
              memory: UInt64 = 64 * gb, options: EngineOptions = EngineOptions()) -> MemoryPlan {
        MemoryPlan(options: options, workers: workers, largestPixels: pixels, archive: archive, lossy: lossy,
                   physicalMemory: memory)
    }

    @Test func fourDeliveriesOnTheWeddingFitEightGigabytes() {
        let p = plan()
        #expect(p.budget == 8_000_000_000)
        #expect(p.workers == 7 && p.archiveLanes == 3, "\(p)")
        #expect(p.plannedPeak <= p.budget)
        // Eight workers with three lanes would not fit the model.
        #expect(MemoryPlan.peak(archives: 3, lossy: 5, pools: true, fullSlots: 3, pixels: Int64(Self.wedding)) > p.budget)
    }

    @Test func smallerPhotosKeepEveryWorker() {
        let p = plan(pixels: 24_000_000)
        #expect(p.workers == 8 && p.archiveLanes == 3, "\(p)")
    }

    @Test func archiveOnlyJobsUseEveryWorkerForArchivesWithinTheBudget() {
        let p = plan(lossy: false)
        #expect(p.archiveLanes == p.workers)
        #expect(p.workers == 5, "\(p)")                  // 0.3 GB + 5 × 1.36 GB
        #expect(p.plannedPeak <= p.budget)
    }

    @Test func lossyOnlyJobsHaveNoArchiveLanes() {
        let p = plan(archive: false)
        #expect(p.archiveLanes == 0 && p.workers == 8, "\(p)")
    }

    @Test func theBudgetIsAtMostHalfTheMac() {
        #expect(plan(memory: 16 * Self.gb).budget == 8_000_000_000)
        let small = plan(memory: 8 * Self.gb)
        #expect(small.budget == 4_000_000_000)
        #expect(small.workers < 7 && small.workers >= 1 && small.plannedPeak <= small.budget, "\(small)")
        let tiny = plan(memory: 2 * Self.gb)
        #expect(tiny.workers == 1 && tiny.archiveLanes == 1, "\(tiny)")   // never below one worker
    }

    @Test func anExplicitLaneCountIsTakenAsGiven() {
        var options = EngineOptions()
        options.archiveConcurrency = 4
        let p = plan(options: options)
        #expect(p.workers == 8 && p.archiveLanes == 4)
    }

    @Test func archivesWaitForTheirLaneWhileLossyWorkIsQueued() {
        let p = plan()
        let archive = MemoryPlan.archiveKind, lossy = MemoryPlan.lossyKind
        func load(archives: Int, lossyRunning: Int, lossyQueued: Int) -> WorkerPool.Load {
            var running = [0, 0], queued = [0, 0]
            running[archive] = archives; running[lossy] = lossyRunning
            queued[archive] = 100; queued[lossy] = lossyQueued
            return WorkerPool.Load(running: running, queued: queued)
        }
        #expect(p.admit(archive, load(archives: 2, lossyRunning: 4, lossyQueued: 50)))
        #expect(!p.admit(archive, load(archives: 3, lossyRunning: 4, lossyQueued: 50)))
        #expect(p.admit(lossy, load(archives: 3, lossyRunning: 4, lossyQueued: 50)))
        // All lossy work started: finishing lossy workers make room for a fourth archive…
        #expect(p.admit(archive, load(archives: 3, lossyRunning: 1, lossyQueued: 0)))
        #expect(!p.admit(archive, load(archives: 4, lossyRunning: 1, lossyQueued: 0)))
        // …and once no lossy item runs, the drained metric pools as well.
        #expect(p.admit(archive, load(archives: 4, lossyRunning: 0, lossyQueued: 0)))
        #expect(!p.admit(archive, load(archives: 5, lossyRunning: 0, lossyQueued: 0)))
    }

    // MARK: Worker pool

    @Test func twoKindPoolRespectsAdmissionAndRunsEveryItem() {
        let archives = Array(0..<12), lossy = Array(100..<140)
        let running = Mutex([0, 0])
        let peak = Mutex([0, 0])
        let done = Mutex<[Int]>([])
        let pool = WorkerPool(kinds: [archives, lossy], count: 6, qos: .userInitiated, name: "test",
                              admit: { kind, load in kind == 1 || load.running[0] < 2 },
                              shouldContinue: { true }) { item, kind, _ in
            running.withLock { r in
                r[kind] += 1
                peak.withLock { p in p[kind] = max(p[kind], r[kind]) }
            }
            Thread.sleep(forTimeInterval: kind == 0 ? 0.02 : 0.005)
            running.withLock { $0[kind] -= 1 }
            done.withLock { $0.append(item) }
        }
        pool.start()
        #expect(pool.wait(timeout: 30))
        #expect(done.withLock { $0.sorted() } == archives + lossy)
        #expect(peak.withLock { $0[0] } == 2)              // archives never above their limit…
        #expect(peak.withLock { $0[1] } >= 3)              // …while the other workers took lossy items
        #expect(pool.remaining == 0)
    }

    @Test func blockedKindsWaitInsteadOfEndingTheWorkers() {
        // Only one item of kind 0 at a time and only kind-0 items: every item still runs, one after the other.
        let done = Mutex(0)
        let concurrent = Mutex((now: 0, peak: 0))
        let pool = WorkerPool(kinds: [Array(0..<6)], count: 4, qos: .userInitiated, name: "test",
                              admit: { _, load in load.running[0] < 1 }, shouldContinue: { true }) { _, _, _ in
            concurrent.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            Thread.sleep(forTimeInterval: 0.01)
            concurrent.withLock { $0.now -= 1 }
            done.withLock { $0 += 1 }
        }
        pool.start()
        #expect(pool.wait(timeout: 30))
        #expect(done.withLock { $0 } == 6)
        #expect(concurrent.withLock { $0.peak } == 1)
    }

    @Test func aCancelledPoolStopsWaitingWorkers() {
        let stop = Mutex(false)
        let started = Mutex(0)
        let pool = WorkerPool(kinds: [Array(0..<20)], count: 3, qos: .userInitiated, name: "test",
                              admit: { _, load in load.running[0] < 1 },
                              shouldContinue: { !stop.withLock { $0 } }) { _, _, _ in
            started.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.05)
            stop.withLock { $0 = true }
        }
        pool.start()
        #expect(pool.wait(timeout: 5))
        #expect(started.withLock { $0 } == 1)
        #expect(pool.remaining == 19)
    }

    // MARK: Deferred references

    /// A metric that counts reference preparations.
    final class CountingMetric: PerceptualMetric, @unchecked Sendable {
        let base = FakeMetric()
        let prepared = Mutex(0), released = Mutex(0)
        func prepareReference(_ image: PixelImage) throws -> any MetricReference {
            prepared.withLock { $0 += 1 }
            return try base.prepareReference(image)
        }
        func score(_ candidate: PixelImage, against reference: any MetricReference) throws -> Double {
            try base.score(candidate, against: reference)
        }
        func release(_ reference: any MetricReference) { released.withLock { $0 += 1 } }
    }

    @Test func largeReferencesAreBuiltPerScoreAndScoreTheSame() throws {
        let metric = CountingMetric()
        let lane = MetricLane(metric: metric)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let large = PixelImage(width: 2600, height: 1200, colorSpace: space)      // 3.1 MP: deferred
        let candidate = PixelImage(width: 2600, height: 1200, colorSpace: space)
        candidate.pixels[0] = 200
        let scores = try lane.withReference(large, cancel: CancelToken()) { ref in
            try (0..<3).map { _ in try lane.score(candidate, against: ref, cancel: CancelToken()) }
        }
        #expect(metric.prepared.withLock { $0 } == 3 && metric.released.withLock { $0 } == 3)
        let direct = try metric.base.score(candidate, against: metric.base.prepareReference(large))
        #expect(scores == [direct, direct, direct])

        let small = PixelImage(width: 2048, height: 1024, colorSpace: space)      // the search mosaic: live
        let smallCandidate = PixelImage(width: 2048, height: 1024, colorSpace: space)
        _ = try lane.withReference(small, cancel: CancelToken()) { ref in
            try (0..<3).map { _ in try lane.score(smallCandidate, against: ref, cancel: CancelToken()) }
        }
        #expect(metric.prepared.withLock { $0 } == 4 && metric.released.withLock { $0 } == 4)

        // Without deferral every reference is prepared once.
        let eager = MetricLane(metric: metric, deferFullResolution: false)
        _ = try eager.withReference(large, cancel: CancelToken()) { ref in
            try (0..<3).map { _ in try eager.score(candidate, against: ref, cancel: CancelToken()) }
        }
        #expect(metric.prepared.withLock { $0 } == 5)
    }

    // MARK: Pixel storage

    @Test func largeImagesAreMappedZeroFilledAndPageAligned() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let large = PixelImage(width: 1024, height: 512, colorSpace: space)        // 2 MB: own mapping
        #expect(Int(bitPattern: large.pixels.baseAddress!) % Int(getpagesize()) == 0)
        #expect(large.pixels.allSatisfy { $0 == 0 })
        large.pixels[large.pixels.count - 1] = 7                                    // writable to the last byte
        let small = PixelImage(width: 10, height: 10, colorSpace: space)
        #expect(small.pixels.count == small.bytesPerRow * 10 && small.pixels.allSatisfy { $0 == 0 })
    }
}
