// The engine stand-in when the live engine cannot start (e.g. the Metal device or the codecs are unavailable).
// Every scan fails with `EngineUnavailableError`, which the drop zone reports as an engine error ("holdmybyte can’t
// compress on this Mac right now") instead of "No photos found"; nothing is ever written.
import Foundation
import HMBModel

/// Thrown by `UnavailableEngine`; `AppModel` shows it as `DropError.engineUnavailable`.
public struct EngineUnavailableError: Error, CustomStringConvertible, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var description: String { reason }
}

public final class UnavailableEngine: EngineService {
    public let reason: String
    public init(reason: String) { self.reason = reason }

    public func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> {
        let error = EngineUnavailableError(reason: reason)
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    public func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] {
        throw EngineUnavailableError(reason: reason)
    }
    public func preflight(_ request: JobRequest) async -> Preflight {
        Preflight(outputFolder: request.outputFolder, estimatedBytes: nil,
                  notices: [.notWritable(volume: request.outputFolder.lastPathComponent)])
    }
    public func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> {
        let reason = reason
        return AsyncStream { continuation in
            continuation.yield(.phase(request.wedding, .failed(reason: reason)))
            continuation.finish()
        }
    }
    public func pause(_ wedding: WeddingID) async {}
    public func stop(_ wedding: WeddingID) async {}
    public func unfinishedJobs() async -> [UnfinishedJob] { [] }
    public func discardJournal(_ wedding: WeddingID) async {}
    public func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID, maxPixelSize: Int?) async throws -> ComparePair {
        throw EngineUnavailableError(reason: reason)
    }
}
