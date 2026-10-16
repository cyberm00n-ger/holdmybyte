// Estimator (§3.10): size and time estimates from a sample of at most 12 real photos.
//
// | Delivery kind   | Estimate                                                                         |
// | Full-size lossy | proxy curve only: d* = exp(inv(T + M0 − BIAS)); mosaic encoded at d*;            |
// |                 | mosaicBytes × (W·H / mosaicPixels) × κ_full                                      |
// | Resized lossy   | real resize + one encode at the prior parameter; bytes × κ_resized               |
// | Archive         | 0.78 × JPEG source bytes + 1.0 × other source bytes (all photos, no sample)       |
// Totals are scaled by n/S. κ and seconds per photo are learned per delivery kind (LearnedEstimates).
import Foundation
import HMBModel

/// The delivery kinds estimates and learning are kept for.
public enum DeliveryKind: String, Codable, Sendable, CaseIterable {
    case fullJPEG, fullWebP, resizedJPEG, resizedWebP, archive

    public init(_ preset: DeliveryPreset) {
        switch (preset.format, preset.isFullSize) {
        case (.jxlLossless, _): self = .archive
        case (.jpeg, true): self = .fullJPEG
        case (.webp, true): self = .fullWebP
        case (.jpeg, false): self = .resizedJPEG
        case (.webp, false): self = .resizedWebP
        }
    }

    var isFullSize: Bool { self == .fullJPEG || self == .fullWebP || self == .archive }

    /// κ before anything is learned (fitted on the holdout; see Docs/ENGINE.md).
    var defaultKappa: Double {
        switch self {
        case .fullJPEG, .fullWebP: 1.0
        case .resizedJPEG, .resizedWebP: 1.0
        case .archive: 1.0
        }
    }

    /// Wall seconds per photo before anything is learned: the §3.11 budgets.
    var defaultSecondsPerPhoto: Double {
        switch self {
        case .fullJPEG: 1.12            // Couple’s Package ≤ 10 min / 535
        case .fullWebP: 1.12
        case .resizedWebP: 0.28         // Website ≤ 2.5 min / 535
        case .resizedJPEG: 0.28
        case .archive: 0.67             // Archive ≤ 6 min / 535
        }
    }
}

/// Learned κ (actual / estimated bytes) and seconds per photo, per delivery kind, as EMAs (α = 0.3) in UserDefaults.
/// Keys: "holdmybyte.estimate.kappa.<kind>" and "holdmybyte.estimate.seconds.<kind>". "Reset Learned Estimates"
/// removes every key with the prefix "holdmybyte.estimate." (`LearnedEstimates.reset`).
public struct LearnedEstimates: Sendable {
    public static let keyPrefix = "holdmybyte.estimate."
    public static let alpha = 0.3
    public let suite: String?
    public init(suite: String? = nil) { self.suite = suite }

    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    private func kappaKey(_ k: DeliveryKind) -> String { Self.keyPrefix + "kappa." + k.rawValue }
    private func secondsKey(_ k: DeliveryKind) -> String { Self.keyPrefix + "seconds." + k.rawValue }

    public func kappa(_ kind: DeliveryKind) -> Double {
        let v = defaults.double(forKey: kappaKey(kind))
        return v > 0 ? v : kind.defaultKappa
    }

    public func secondsPerPhoto(_ kind: DeliveryKind) -> Double {
        let v = defaults.double(forKey: secondsKey(kind))
        return v > 0 ? v : kind.defaultSecondsPerPhoto
    }

    /// Folds one finished job: `actual` bytes against the `estimated` bytes that were computed with `kappaUsed`.
    public func foldBytes(_ kind: DeliveryKind, actual: Int64, estimated: Int64, kappaUsed: Double) {
        guard actual > 0, estimated > 0, kappaUsed > 0 else { return }
        let observed = kappaUsed * Double(actual) / Double(estimated)
        guard observed.isFinite, observed > 0.05, observed < 20 else { return }
        let current = kappa(kind)
        defaults.set(Self.alpha * observed + (1 - Self.alpha) * current, forKey: kappaKey(kind))
    }

    public func foldSeconds(_ kind: DeliveryKind, secondsPerPhoto: Double) {
        guard secondsPerPhoto.isFinite, secondsPerPhoto > 0 else { return }
        let current = self.secondsPerPhoto(kind)
        defaults.set(Self.alpha * secondsPerPhoto + (1 - Self.alpha) * current, forKey: secondsKey(kind))
    }

    /// "Reset Learned Estimates".
    public static func reset(suite: String? = nil) {
        let d = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) { d.removeObject(forKey: key) }
    }
}

struct Estimator: Sendable {
    let primitives: EnginePrimitives
    let constants: SearchConstants
    let learned: LearnedEstimates
    let concurrency: Int
    /// The engine's one metric lane (§3.9), shared with a running job.
    let lane: MetricLane

    /// What one estimate was, kept so a finished job can fold actual/estimated into κ.
    struct Record: Sendable {
        var kind: DeliveryKind
        var bytes: Int64
        var kappa: Double
    }

    /// Sample indices ⌊(i + 0.5)·n/S⌋, S = min(12, n).
    static func sampleIndices(count n: Int, maxSamples: Int = 12) -> [Int] {
        let s = min(maxSamples, n)
        guard s > 0 else { return [] }
        return (0..<s).map { Int((Double($0) + 0.5) * Double(n) / Double(s)) }
    }

    func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset], cancel: CancelToken) throws
        -> (estimates: [DeliveryID: DeliveryEstimate], records: [DeliveryID: Record]) {
        let totalSource = photos.reduce(Int64(0)) { $0 + $1.byteCount }
        let lossy = deliveries.filter(\.isLossy)
        let indices = Self.sampleIndices(count: photos.count)
        let perSample = Locked([[DeliveryID: Double]](repeating: [:], count: indices.count))
        if !lossy.isEmpty, !indices.isEmpty {
            let failure = Locked<(any Error)?>(nil)
            let pool = WorkerPool(items: Array(indices.indices), count: min(concurrency, indices.count), qos: .userInitiated,
                                  name: "holdmybyte estimate", shouldContinue: { !cancel.isCancelled }) { slot, _ in
                do {
                    let values = try sample(photos[indices[slot]], deliveries: lossy, lane: lane, cancel: cancel)
                    perSample.withLock { $0[slot] = values }
                } catch is JobCancelled {
                } catch {
                    failure.withLock { if $0 == nil { $0 = error } }
                }
            }
            pool.start()
            while !pool.wait(timeout: 0.05) {}
            try cancel.check()
            if let error = failure.snapshot, perSample.snapshot.allSatisfy(\.isEmpty) { throw error }
        }
        let samples = perSample.snapshot
        let scale = indices.isEmpty ? 0 : Double(photos.count) / Double(indices.count)

        var estimates: [DeliveryID: DeliveryEstimate] = [:]
        var records: [DeliveryID: Record] = [:]
        for preset in deliveries {
            let kind = DeliveryKind(preset)
            let bytes: Int64
            if preset.isLossy {
                bytes = Int64((samples.reduce(0) { $0 + ($1[preset.id] ?? 0) } * scale).rounded())
            } else {
                bytes = Self.archiveBytes(photos)
            }
            estimates[preset.id] = DeliveryEstimate(bytes: bytes,
                                                    fractionOfSource: totalSource > 0 ? Double(bytes) / Double(totalSource) : 0,
                                                    secondsPerPhoto: learned.secondsPerPhoto(kind))
            records[preset.id] = Record(kind: kind, bytes: bytes, kappa: learned.kappa(kind))
        }
        return (estimates, records)
    }

    /// The mosaic score the full-size estimate aims at: what the search expects to deliver (T plus its margin), shifted
    /// by the expected full − mosaic bias.
    static func mosaicGoal(target: Double, constants c: SearchConstants) -> Double {
        switch c.aim {
        case .proxyCurve: target + c.m0 - c.bias
        case .mosaicExact: target + c.exactMargin - c.exactBiasPrior
        }
    }

    static func archiveBytes(_ photos: [SourcePhoto]) -> Int64 {
        photos.reduce(Int64(0)) { $0 + ($1.kind == .jpeg ? Int64((0.78 * Double($1.byteCount)).rounded()) : $1.byteCount) }
    }

    /// Estimated bytes for each lossy delivery of one sample photo (κ applied).
    private func sample(_ photo: SourcePhoto, deliveries: [DeliveryPreset], lane: MetricLane,
                        cancel: CancelToken) throws -> [DeliveryID: Double] {
        let p = primitives
        try cancel.check()
        guard let info = try? p.decoder.inspect(photo.url), !info.isCMYK,
              let source = try? lane.decoding(pixels: photo.pixelWidth * photo.pixelHeight, cancel: cancel, {
                  try p.decoder.decode(info)
              }) else {
            try cancel.check()
            return [:]
        }      // unreadable / CMYK: nothing delivered
        let needsFeatures = deliveries.contains { $0.quality == .balanced }
        let features = needsFeatures ? p.processing.features(source) : nil
        // Variants first (one sRGB conversion, one resize per size), then the deliveries' estimates in parallel: a
        // sample's WebP search no longer holds up its other deliveries, and the last round of samples does not leave
        // cores idle (Docs/ENGINE.md §7).
        var srgb: PixelImage?
        var resized: [String: PixelImage] = [:]
        var jobs: [(preset: DeliveryPreset, target: Double, variant: PixelImage)] = []
        for preset in deliveries.sorted(by: DeliveryPlan.executionOrder) {
            try cancel.check()
            guard let target = Targets.target(preset.quality, features: features) else { continue }
            var v = source
            if preset.colour == .convertToSRGB {
                if srgb == nil { srgb = p.processing.convertedToSRGB(source) }
                v = srgb!
            }
            if let edge = preset.size.longEdge, edge < max(v.width, v.height) {
                let key = "\(preset.colour.rawValue)@\(edge)"
                if let cached = resized[key] { v = cached } else {
                    let r = p.processing.resized(v, longEdge: edge)
                    resized[key] = r
                    v = r
                }
            }
            jobs.append((preset, target, v))
        }
        let out = Locked([DeliveryID: Double]())
        let failure = Locked<(any Error)?>(nil)
        let work = jobs
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            do {
                let bytes = try estimateBytes(work[i].preset, target: work[i].target, variant: work[i].variant, info: info,
                                              lane: lane, cancel: cancel)
                out.withLock { $0[work[i].preset.id] = bytes }
            } catch {
                failure.withLock { if $0 == nil { $0 = error } }
            }
        }
        if let error = failure.snapshot { throw error }
        return out.snapshot
    }

    /// Estimated bytes of one lossy delivery of one sample photo (κ applied).
    private func estimateBytes(_ preset: DeliveryPreset, target: Double, variant v: PixelImage, info: SourceInfo,
                               lane: MetricLane, cancel: CancelToken) throws -> Double {
            let p = primitives
            try cancel.check()
            let kind = DeliveryKind(preset)
            let kappa = learned.kappa(kind)
            let meta = MetadataEditor.output(for: info, policy: preset.metadata, colour: preset.colour)
            let markerBytes = Double(MetadataEditor.jpegMarkers(meta).reduce(0) { $0 + $1.payload.count + 4 })
            var bytes: Double
            if preset.isFullSize, let mosaic = p.processing.mosaic(v) {
                let scale = Double(v.pixelCount) / Double(mosaic.pixelCount)
                if preset.format == .webp {
                    let prepared = try p.webp.prepare(mosaic)
                    bytes = Double(try p.webp.encode(prepared, quality: Float(Targets.webpPrior(target)), icc: nil, exif: nil, xmp: nil).count)
                        * scale * kappa + markerBytes
                } else {
                    let d = try lane.withReference(mosaic, cancel: cancel) { ref -> Double in
                        var points: [(x: Double, s: Double)] = []
                        for factor in [0.8, 1.0, 1.25] {
                            try cancel.check()
                            let d = Targets.jpegPrior(target) * factor
                            let data = try p.jpeg.encodeForScoring(mosaic, distance: d, subsampling: .s420)
                            points.append((log(d), try lane.score(try p.decoder.decode(encoded: data), against: ref, cancel: cancel)))
                        }
                        return exp(ProxyCurve(points: points).inverse(Self.mosaicGoal(target: target, constants: constants),
                                                                      range: constants.lnDistanceRange))
                    }
                    bytes = Double(try p.jpeg.encode(mosaic, distance: d, subsampling: .s420, markers: []).count)
                        * scale * kappa + markerBytes
                }
            } else {
                // Resized (and small full-size) deliveries: the real DirectSearch on the sample's variant — a few probes
                // on a ≤ 5 MP image. One probe at the prior missed by 30–45 % on the holdout: the parameter that reaches
                // the floor at 1440/2560 px differs from the full-size prior, and some photos only reach a high floor
                // with 4:4:4 (Docs/ENGINE.md §7).
                bytes = try lane.withReference(v, cancel: cancel) { ref -> Double in
                    func verify(_ data: Data) throws -> Double {
                        try cancel.check()
                        return try lane.score(try p.decoder.decode(encoded: data), against: ref, cancel: cancel)
                    }
                    let markers = MetadataEditor.jpegMarkers(meta)
                    func jpegSearch() throws -> Double? {
                        let result = try DirectSearch.jpeg(target: target, constants: constants) { d, chroma in
                            let data = try p.jpeg.encode(v, distance: d, subsampling: chroma, markers: markers)
                            return ProbeRecord(parameter: d, subsampling: chroma, score: try verify(data), data: data)
                        }
                        if case .encoded(let best) = result.outcome { return Double(best.bytes) }
                        return nil
                    }
                    if preset.format == .webp {
                        let prepared = try p.webp.prepare(v)
                        let web = try DirectSearch.webp(target: target, constants: constants) { q in
                            let data = try p.webp.encode(prepared, quality: Float(q), icc: meta.icc, exif: meta.exif, xmp: meta.xmp)
                            return ProbeRecord(parameter: q, subsampling: nil, score: try verify(data), data: data)
                        }
                        if let best = web.best { return Double(best.bytes) }
                    }
                    return try jpegSearch() ?? 0
                } * kappa
            }
            // Keep-original caps a full-size JPEG delivery at the source size (§3.4).
            if preset.isFullSize, info.kind == .jpeg, preset.colour == .keepProfile,
               bytes >= 0.95 * Double(info.fileBytes.count) {
                bytes = Double(info.fileBytes.count)
            }
            return bytes
    }

    /// A no-decode estimate (preflight before estimates arrive, disk-full banner): full lossy 0.15 × source,
    /// resized by output pixels, archive per §3.10.
    static func roughBytes(photos: [SourcePhoto], deliveries: [DeliveryPreset]) -> Int64 {
        var total: Int64 = 0
        for preset in deliveries {
            switch DeliveryKind(preset) {
            case .archive: total += archiveBytes(photos)
            case .fullJPEG, .fullWebP: total += photos.reduce(0) { $0 + $1.byteCount * 15 / 100 }
            case .resizedJPEG, .resizedWebP:
                let edge = Double(preset.size.longEdge ?? 2560)
                let perPixel = preset.format == .webp ? 0.12 : 0.22
                for photo in photos {
                    let w = Double(max(1, photo.pixelWidth)), h = Double(max(1, photo.pixelHeight))
                    let s = min(1, edge / max(w, h))
                    total += Int64(w * s * h * s * perPixel)
                }
            }
        }
        return total
    }
}
