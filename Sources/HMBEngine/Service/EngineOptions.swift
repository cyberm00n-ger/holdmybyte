// Tunables of the live engine. The defaults are the spec; tests and the bench override them.
import Foundation

public struct EngineOptions: Sendable {
    /// Worker threads; nil = from `ProcessorUse` (§3.9).
    public var workerCount: Int?
    /// Search constants (§3.4/§3.5), including the default-off E2 chroma gate.
    public var constants: SearchConstants
    /// Full-resolution searches at once (§3.9, MetricLane slots); nil = from the job's memory plan (every lossy
    /// worker while the model fits the budget, never fewer than 3).
    public var maxLiveReferences: Int?
    /// Full-resolution decodes at once (MetricLane); nil = as many as full-resolution searches (at least 2).
    public var largeDecodes: Int?
    /// Bytes shared by full-resolution metric references and archive transcodes at once (§3.9 memory budget,
    /// Docs/DECISIONS.md D-ENG-7). nil (default): no budget beyond the three reference slots. 6.4 GB = three 45 MP
    /// references plus one transcode, or four transcodes.
    public var memoryBudget: Int64?
    /// Archive transcodes at once while lossy work is queued (D-ENG-10); nil = from the memory plan.
    public var archiveConcurrency: Int?
    /// Serialise metric calls on one lane (§3.9). Tests with CPU fakes may turn it off.
    public var serializeMetric: Bool
    /// UserDefaults suite for learned κ and timing (nil = standard defaults). See `LearnedEstimates`.
    public var learnedEstimatesSuite: String?
    /// Estimation concurrency (sample photos processed in parallel).
    public var estimateConcurrency: Int

    /// Test hook: an errno to inject for a write to the given final path (e.g. ENOSPC).
    public var writeFaultHook: (@Sendable (URL) -> Int32?)?
    /// Test hook: called after each successful rename, before the result is journaled. Throwing simulates a crash
    /// between the rename and the journal append.
    public var afterRenameHook: (@Sendable (URL) throws -> Void)?

    public init(workerCount: Int? = nil, constants: SearchConstants = .spec, maxLiveReferences: Int? = nil,
                memoryBudget: Int64? = nil, archiveConcurrency: Int? = nil,
                serializeMetric: Bool = true, learnedEstimatesSuite: String? = nil,
                estimateConcurrency: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)),
                writeFaultHook: (@Sendable (URL) -> Int32?)? = nil,
                afterRenameHook: (@Sendable (URL) throws -> Void)? = nil) {
        self.workerCount = workerCount; self.constants = constants; self.maxLiveReferences = maxLiveReferences
        self.memoryBudget = memoryBudget
        self.largeDecodes = nil
        self.archiveConcurrency = archiveConcurrency
        self.serializeMetric = serializeMetric; self.learnedEstimatesSuite = learnedEstimatesSuite
        self.estimateConcurrency = estimateConcurrency
        self.writeFaultHook = writeFaultHook; self.afterRenameHook = afterRenameHook
    }
}
