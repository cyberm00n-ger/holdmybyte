import CryptoKit
import Foundation
import HMBModel

/// Drives one job through any `EngineService` and collects its results (used by `hmb compress` and `hmb bench`).
public struct EngineJobRunner: Sendable {
    public struct Outcome: Sendable {
        public var results: [PhotoResult]
        public var phase: JobPhase
        public var wallSeconds: Double
        public var cpuSeconds: Double
        public var peakRSSBytes: Int64
        public var lastProgress: JobProgress?
    }

    public struct ScanFailed: Error, CustomStringConvertible {
        public var description: String
    }

    public let engine: any EngineService

    public init(engine: any EngineService) { self.engine = engine }

    public func scan(_ items: [URL]) async throws -> ScanResult {
        for try await update in engine.scan(items) {
            if case .finished(let result) = update { return result }
        }
        throw ScanFailed(description: "the scan ended without a result")
    }

    /// Runs `request` to its end. With `stopAfterPhotos`, asks the engine to stop once that many photos are done.
    public func run(_ request: JobRequest, resume: Bool = false, stopAfterPhotos: Int? = nil,
                    onProgress: @Sendable (JobProgress) -> Void = { _ in }) async -> Outcome {
        let startUsage = ResourceUsage.current()
        let start = ContinuousClock.now
        var byKey: [String: PhotoResult] = [:]
        var order: [String] = []
        var phase: JobPhase = .running
        var lastProgress: JobProgress?
        var stopRequested = false
        for await event in engine.run(request, resume: resume) {
            switch event {
            case .results(_, let results):
                for result in results {
                    let key = "\(result.photo.index)|\(result.delivery.rawValue)"
                    if byKey[key] == nil { order.append(key) }
                    byKey[key] = result
                }
            case .progress(let progress):
                lastProgress = progress
                onProgress(progress)
                if let limit = stopAfterPhotos, !stopRequested, progress.photosDone >= limit {
                    stopRequested = true
                    await engine.stop(request.wedding)
                }
            case .phase(_, let newPhase):
                phase = newPhase
            }
        }
        let elapsed = ContinuousClock.now - start
        let endUsage = ResourceUsage.current()
        return Outcome(results: order.compactMap { byKey[$0] }, phase: phase,
                       wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                       cpuSeconds: endUsage.cpuSeconds - startUsage.cpuSeconds, peakRSSBytes: endUsage.maxRSSBytes,
                       lastProgress: lastProgress)
    }

    public static func phaseText(_ phase: JobPhase) -> String {
        switch phase {
        case .queued: "queued"
        case .running: "running"
        case .paused(let reason): "paused:\(reason)"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        case .finished: "finished"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

/// SHA-256 of every regular file below a folder, keyed by relative path (determinism and resume comparisons).
public enum OutputDigest {
    public static func files(in folder: URL) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: String] = [:]
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            result[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    /// Relative paths that differ (missing on one side or different content).
    public static func differences(_ a: [String: String], _ b: [String: String]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }

    /// Leftover staging files (`*.tmp`, `.holdmybyte-partial`) below `folder`.
    public static func temporaryFiles(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "tmp" || url.lastPathComponent == ".holdmybyte-partial" {
            result.append(url.path)
        }
        return result.sorted()
    }

    public static func totalBytes(in folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
