// WP0 stub; WP2 owns this file. Every call fails clearly until WP2 implements the engine (§3, §5.2).
import Foundation
import HMBModel

public final class LiveEngine: EngineService {
    public let primitives: EnginePrimitives
    public let supportDirectory: URL

    /// `<Application Support>/holdmybyte`
    public static var defaultSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "holdmybyte", directoryHint: .isDirectory)
    }

    public init(primitives: EnginePrimitives, supportDirectory: URL = LiveEngine.defaultSupportDirectory) {
        self.primitives = primitives
        self.supportDirectory = supportDirectory
    }

    /// The production engine: live primitives (WP1).
    public convenience init(supportDirectory: URL = LiveEngine.defaultSupportDirectory) throws {
        self.init(primitives: try .live(), supportDirectory: supportDirectory)
    }

    struct NotImplemented: Error, CustomStringConvertible {
        var description: String { "LiveEngine is not implemented yet (WP2)" }
    }

    public func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> {
        AsyncThrowingStream { $0.finish(throwing: NotImplemented()) }
    }

    public func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] {
        throw NotImplemented()
    }

    public func preflight(_ request: JobRequest) async -> Preflight {
        Preflight(outputFolder: request.outputFolder, estimatedBytes: nil, notices: [.notWritable(volume: "not implemented")])
    }

    public func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            continuation.yield(.phase(request.wedding, .failed(reason: NotImplemented().description)))
            continuation.finish()
        }
    }

    public func pause(_ wedding: WeddingID) async {}
    public func stop(_ wedding: WeddingID) async {}
    public func unfinishedJobs() async -> [UnfinishedJob] { [] }
    public func discardJournal(_ wedding: WeddingID) async {}

    public func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID,
                            maxPixelSize: Int?) async throws -> ComparePair {
        throw NotImplemented()
    }
}
