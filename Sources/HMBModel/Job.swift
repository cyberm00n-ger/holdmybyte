import Foundation

public enum ProcessorUse: String, Codable, Sendable { case automatic, gentle }

public struct NamingScheme: Codable, Sendable, Hashable {
    public var renameByCaptureTime: Bool
    public var pattern: String               // tokens {wedding}, {number}
    public init(renameByCaptureTime: Bool, pattern: String) { self.renameByCaptureTime = renameByCaptureTime; self.pattern = pattern }
    public static let `default` = NamingScheme(renameByCaptureTime: true, pattern: "{wedding}-{number}")
}

public struct JobRequest: Codable, Sendable, Hashable {
    public var wedding: WeddingID
    public var name: String
    public var photos: [SourcePhoto]
    public var sourceRoots: [URL]
    public var deliveries: [DeliveryPreset]  // snapshot, UI order
    public var outputFolder: URL             // as resolved by preflight
    public var naming: NamingScheme
    public var processorUse: ProcessorUse
    public var onlyPhotos: Set<PhotoID>?     // retry subset; nil = all
    public var appendToExistingFolder: Bool  // Create More Deliveries
    public init(wedding: WeddingID, name: String, photos: [SourcePhoto], sourceRoots: [URL],
                deliveries: [DeliveryPreset], outputFolder: URL, naming: NamingScheme,
                processorUse: ProcessorUse, onlyPhotos: Set<PhotoID>? = nil, appendToExistingFolder: Bool = false) {
        self.wedding = wedding; self.name = name; self.photos = photos; self.sourceRoots = sourceRoots
        self.deliveries = deliveries; self.outputFolder = outputFolder; self.naming = naming
        self.processorUse = processorUse; self.onlyPhotos = onlyPhotos; self.appendToExistingFolder = appendToExistingFolder
    }
}

public struct Preflight: Codable, Sendable, Hashable {
    public var outputFolder: URL
    public var estimatedBytes: Int64?
    public var notices: [ScanNotice]
    public var canStart: Bool { !notices.contains { $0.severity == .block } }
    public init(outputFolder: URL, estimatedBytes: Int64?, notices: [ScanNotice]) {
        self.outputFolder = outputFolder; self.estimatedBytes = estimatedBytes; self.notices = notices
    }
}

public struct DeliveryEstimate: Codable, Sendable, Hashable {
    public var bytes: Int64
    public var fractionOfSource: Double      // 0.12 means output is 12 % of the source bytes
    public var secondsPerPhoto: Double
    public init(bytes: Int64, fractionOfSource: Double, secondsPerPhoto: Double) {
        self.bytes = bytes; self.fractionOfSource = fractionOfSource; self.secondsPerPhoto = secondsPerPhoto
    }
}

public enum PhotoFailure: String, Codable, Sendable {
    case unreadable, cmykUnsupported, encodeFailed, writeFailed, sourceMissing, qualityUnreachable
    public var isRetryable: Bool { self == .encodeFailed || self == .writeFailed || self == .sourceMissing }
}

public enum PhotoStatus: Codable, Sendable, Hashable {
    case queued, working, done, keptOriginal, failed(PhotoFailure)
}

public struct PhotoResult: Codable, Sendable, Hashable {
    public var photo: PhotoID
    public var delivery: DeliveryID
    public var status: PhotoStatus
    public var score: Double?                // nil for archive and plain copies
    public var target: Double?
    public var inBytes: Int64
    public var outBytes: Int64?
    public var outRelativePath: String?      // relative to JobRequest.outputFolder, e.g. "Couple/Finn-und-Lissy-0001.jpg"
    public var outPixelWidth: Int?
    public var outPixelHeight: Int?
    public var encoder: String?              // "jpegli" | "jpegli (high)" | "jpegli (fallback)" | "libwebp" | "libjxl" | "copy"
    public var chroma: ChromaSubsampling?
    public var byteExact: Bool?              // archive only
    public var probes: Int
    public var seconds: Double
    public init(photo: PhotoID, delivery: DeliveryID, status: PhotoStatus, score: Double? = nil, target: Double? = nil,
                inBytes: Int64, outBytes: Int64? = nil, outRelativePath: String? = nil, outPixelWidth: Int? = nil,
                outPixelHeight: Int? = nil, encoder: String? = nil, chroma: ChromaSubsampling? = nil,
                byteExact: Bool? = nil, probes: Int = 0, seconds: Double = 0) {
        self.photo = photo; self.delivery = delivery; self.status = status; self.score = score; self.target = target
        self.inBytes = inBytes; self.outBytes = outBytes; self.outRelativePath = outRelativePath
        self.outPixelWidth = outPixelWidth; self.outPixelHeight = outPixelHeight; self.encoder = encoder
        self.chroma = chroma; self.byteExact = byteExact; self.probes = probes; self.seconds = seconds
    }
}

public struct DeliverySummary: Codable, Sendable, Hashable {
    public var delivery: DeliveryID
    public var total: Int                    // photos in scope
    public var processed: Int                // done + keptOriginal + failed
    public var delivered: Int                // done + keptOriginal
    public var keptOriginal: Int
    public var failed: Int
    public var sourceBytes: Int64            // Σ inBytes over delivered
    public var outputBytes: Int64            // Σ outBytes over delivered
    public var minScore: Double?
    public var medianScore: Double?
    public var maxScore: Double?
    public var floor: Double?                // fixed floor, if any
    public var targetRange: ClosedRange<Double>?   // balanced: min...max of per-photo targets
    public var byteExactCount: Int
    public var savedFraction: Double { sourceBytes > 0 ? 1 - Double(outputBytes) / Double(sourceBytes) : 0 }
    public var isComplete: Bool { processed == total && failed == 0 }

    /// Summarises `results` for `preset` over `photos` (the photos in scope).
    /// - Only results whose `delivery == preset.id` and whose photo is in `photos` count; when a photo has several
    ///   results (e.g. after a retry), the last one in `results` wins.
    /// - Scores (min / median / max) are taken over `status == .done` only; the median of an even count is the mean
    ///   of the two middle values.
    /// - `targetRange` is set for Balanced presets only (min...max of the `target`s of done photos).
    /// - A delivered result without `outBytes` counts as 0 output bytes.
    public static func make(preset: DeliveryPreset, photos: [SourcePhoto], results: [PhotoResult]) -> DeliverySummary {
        let inScope = Set(photos.map(\.id))
        var latest: [PhotoID: PhotoResult] = [:]
        for result in results where result.delivery == preset.id && inScope.contains(result.photo) {
            latest[result.photo] = result
        }
        var done = 0, kept = 0, failed = 0, byteExact = 0
        var sourceBytes: Int64 = 0, outputBytes: Int64 = 0
        var scores: [Double] = []
        var targets: [Double] = []
        for result in latest.values {
            switch result.status {
            case .queued, .working:
                continue
            case .failed:
                failed += 1
                continue
            case .done:
                done += 1
                if let score = result.score { scores.append(score) }
                if let target = result.target { targets.append(target) }
            case .keptOriginal:
                kept += 1
            }
            sourceBytes += result.inBytes
            outputBytes += result.outBytes ?? 0
            if result.byteExact == true { byteExact += 1 }
        }
        scores.sort()
        let median: Double? = scores.isEmpty ? nil
            : scores.count.isMultiple(of: 2) ? (scores[scores.count / 2 - 1] + scores[scores.count / 2]) / 2
            : scores[scores.count / 2]
        let targetRange: ClosedRange<Double>? = preset.quality == .balanced
            ? targets.min().flatMap { lo in targets.max().map { hi in lo...hi } } : nil
        return DeliverySummary(delivery: preset.id, total: photos.count, processed: done + kept + failed,
                               delivered: done + kept, keptOriginal: kept, failed: failed,
                               sourceBytes: sourceBytes, outputBytes: outputBytes,
                               minScore: scores.first, medianScore: median, maxScore: scores.last,
                               floor: preset.quality.floor, targetRange: targetRange, byteExactCount: byteExact)
    }
}

public enum PauseReason: Codable, Sendable, Hashable {
    case user
    case sourceUnavailable(volume: String)
    case diskFull(volume: String, neededBytes: Int64)
    case outputNotWritable(path: String)
}

public enum JobPhase: Codable, Sendable, Hashable {
    case queued(position: Int)
    case running
    case paused(PauseReason)
    case stopped
    case interrupted
    case finished
    case failed(reason: String)
}

public struct JobProgress: Sendable, Hashable {
    public var wedding: WeddingID
    public var photosDone: Int
    public var photosTotal: Int
    public var photosInFlight: Int
    public var secondsPerPhoto: Double?      // smoothed (α = 0.1); nil until the first photo finishes
    public var etaSeconds: Double?           // nil until 10 photos have finished
    public var summaries: [DeliverySummary]
    public var fraction: Double { photosTotal == 0 ? 0 : Double(photosDone) / Double(photosTotal) }
    public init(wedding: WeddingID, photosDone: Int, photosTotal: Int, photosInFlight: Int,
                secondsPerPhoto: Double?, etaSeconds: Double?, summaries: [DeliverySummary]) {
        self.wedding = wedding; self.photosDone = photosDone; self.photosTotal = photosTotal
        self.photosInFlight = photosInFlight; self.secondsPerPhoto = secondsPerPhoto
        self.etaSeconds = etaSeconds; self.summaries = summaries
    }
}

public enum EngineEvent: Sendable {
    case phase(WeddingID, JobPhase)
    case results(WeddingID, [PhotoResult])  // coalesced, ≤ 10 Hz
    case progress(JobProgress)               // ≥ 1 Hz while running
}

public struct UnfinishedJob: Codable, Sendable, Hashable {
    public var request: JobRequest
    public var results: [PhotoResult]
    public init(request: JobRequest, results: [PhotoResult]) { self.request = request; self.results = results }
}
