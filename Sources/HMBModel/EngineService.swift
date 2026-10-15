// Sources/HMBModel/EngineService.swift  (frozen after WP0)
import Foundation

public protocol EngineService: Sendable {
    /// Recursively scans dropped items. Yields `.progress` at most every 100 ms and exactly one `.finished`.
    func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error>

    /// Size estimates for each delivery, from a sample of at most 12 photos. Must finish within 5 s for
    /// the default deliveries on 45 MP photos. Cancellable (Task cancellation).
    func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate]

    /// Checks space and writability and resolves the output folder (adds " 2" if needed). Writes nothing.
    func preflight(_ request: JobRequest) async -> Preflight

    /// Runs (or, with `resume: true`, continues) a job. Exactly one job runs at a time; the caller queues.
    /// The stream ends after `.phase(.finished)`, `.phase(.stopped)`, `.phase(.paused)` or `.phase(.failed)`.
    func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent>

    func pause(_ wedding: WeddingID) async
    func stop(_ wedding: WeddingID) async

    /// Jobs that have a journal but no finished marker (shown as Interrupted at launch).
    func unfinishedJobs() async -> [UnfinishedJob]
    /// Forgets the journal of a finished or abandoned job.
    func discardJournal(_ wedding: WeddingID) async

    /// Decoded original (resized and colour-converted exactly as scored) plus the decoded delivered file.
    func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID,
                     maxPixelSize: Int?) async throws -> ComparePair
}
