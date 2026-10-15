// Tunables of the live engine. The defaults are the spec; tests and the bench override them.
import Foundation

public struct EngineOptions: Sendable {
    /// Worker threads; nil = from `ProcessorUse` (§3.9).
    public var workerCount: Int?
    /// Search constants (§3.4/§3.5), including the default-off E2 chroma gate.
    public var constants: SearchConstants
    /// Live full-resolution metric references at once (§3.9).
    public var maxLiveReferences: Int
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

    public init(workerCount: Int? = nil, constants: SearchConstants = .spec, maxLiveReferences: Int = 3,
                serializeMetric: Bool = true, learnedEstimatesSuite: String? = nil,
                estimateConcurrency: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)),
                writeFaultHook: (@Sendable (URL) -> Int32?)? = nil,
                afterRenameHook: (@Sendable (URL) throws -> Void)? = nil) {
        self.workerCount = workerCount; self.constants = constants; self.maxLiveReferences = maxLiveReferences
        self.serializeMetric = serializeMetric; self.learnedEstimatesSuite = learnedEstimatesSuite
        self.estimateConcurrency = estimateConcurrency
        self.writeFaultHook = writeFaultHook; self.afterRenameHook = afterRenameHook
    }
}
