// PhotoPipeline (§3.3): one photo, end to end, for every delivery of the job — one inspect, at most one decode,
// variants cached per (colour, long edge), each lossy delivery searched and verified, then written.
import CoreGraphics
import Foundation
import HMBModel
import os

/// Where and how one delivery of the job is written.
struct DeliveryPlan: Sendable {
    var preset: DeliveryPreset
    var folderName: String
    var directory: URL
    /// File stems by photo index (deterministic, de-duplicated in capture order).
    var stems: [Int: String]

    /// Execution order (§3.3): resized lossy by ascending long edge, then full-size lossy, then archive.
    static func executionOrder(_ a: DeliveryPreset, _ b: DeliveryPreset) -> Bool {
        func rank(_ p: DeliveryPreset) -> (Int, Int) {
            if !p.isLossy { return (2, 0) }
            if let edge = p.size.longEdge { return (0, edge) }
            return (1, 0)
        }
        return rank(a) < rank(b)
    }
}

/// Conditions that pause the whole job (§3.8 error mapping).
enum JobInterruption: Error, Sendable {
    case sourceUnavailable(volume: String)
    case diskFull(path: String)
    case outputNotWritable(path: String)
}

struct PipelineContext: Sendable {
    var primitives: EnginePrimitives
    var lane: MetricLane
    var writer: OutputWriter
    var constants: SearchConstants
    var outputFolder: URL
    var sourceRoots: [URL]
    var cancel: CancelToken
    var adoptIdentical: Bool
}

struct PhotoPipeline {
    let context: PipelineContext
    private static let log = Logger(subsystem: "eu.sebastianhaas.holdmybyte", category: "pipeline")

    /// Processes `photo` for `plans` (already in execution order) and reports each result through `emit` right
    /// after its file is in place. Throws `JobCancelled` or `JobInterruption`; per-delivery failures are results.
    func process(_ photo: SourcePhoto, plans: [DeliveryPlan], emit: (PhotoResult) throws -> Void) throws {
        let c = context
        var clock = monotonicSeconds()
        func lap() -> Double { let now = monotonicSeconds(); defer { clock = now }; return now - clock }

        try c.cancel.check()
        let info: SourceInfo
        do {
            info = try c.primitives.decoder.inspect(photo.url)
        } catch {
            try throwIfSourceUnavailable(photo)
            let failure: PhotoFailure = FileManager.default.fileExists(atPath: photo.url.path) ? .unreadable : .sourceMissing
            Self.log.error("cannot read \(photo.relativePath, privacy: .public): \(String(describing: error), privacy: .public)")
            for plan in plans { try emit(failed(photo, plan, failure, seconds: lap())) }
            return
        }

        var source: PixelImage?
        var decodeFailure: PhotoFailure?
        var features: ImageFeatures?
        var variants: [String: PixelImage] = [:]

        func decoded() throws -> PixelImage? {
            if let source { return source }
            if decodeFailure != nil { return nil }
            do {
                MemoryTrace.mark("before decode")
                let image = try MemoryTrace.during(.decode) {
                    try c.lane.decoding(pixels: photo.pixelWidth * photo.pixelHeight, cancel: c.cancel) {
                        try c.primitives.decoder.decode(info)
                    }
                }
                MemoryTrace.mark("after decode")
                source = image
                return image
            } catch {
                try throwIfSourceUnavailable(photo)
                Self.log.error("cannot decode \(photo.relativePath, privacy: .public): \(String(describing: error), privacy: .public)")
                decodeFailure = .unreadable
                return nil
            }
        }

        func variant(_ s: PixelImage, colour: ColourHandling, longEdge: Int?) -> PixelImage {
            var base = s
            if colour == .convertToSRGB {
                if let cached = variants["srgb"] { base = cached } else {
                    base = c.primitives.processing.convertedToSRGB(s); variants["srgb"] = base
                }
            }
            guard let edge = longEdge, edge < max(base.width, base.height) else { return base }
            let key = "\(colour.rawValue)@\(edge)"
            if let cached = variants[key] { return cached }
            let resized = c.primitives.processing.resized(base, longEdge: edge)
            variants[key] = resized
            return resized
        }

        for (position, plan) in plans.enumerated() {
            try c.cancel.check()
            let preset = plan.preset
            // Variants no later delivery uses go now: after Website and Social, the full-resolution sRGB copy (180 MB
            // at 45 MP per worker) would otherwise live through the whole Couple's Package search (D-ENG-7).
            let later = plans[position...].map(\.preset).filter(\.isLossy)
            variants = variants.filter { key, _ in
                later.contains { p in
                    (key == "srgb" && p.colour == .convertToSRGB)
                        || p.size.longEdge.map { key == "\(p.colour.rawValue)@\($0)" } == true
                }
            }
            let result: PhotoResult
            if !preset.isLossy {
                // The archive needs only the file bytes: once no lossy delivery is left, the pixels go (§3.9 memory).
                if !plans[position...].contains(where: \.preset.isLossy) {
                    source = nil
                    variants.removeAll()
                }
                MemoryTrace.mark("before archive")
                MemoryTrace.enter(.archive)
                defer { MemoryTrace.leave(.archive); MemoryTrace.mark("after archive") }
                let product = try JXLArchive.make(info, sourceExtension: photo.url.pathExtension, jxl: c.primitives.jxl,
                                                  cancel: c.cancel, label: photo.relativePath,
                                                  pixels: photo.pixelWidth * photo.pixelHeight, memory: c.lane.memory)
                result = try write(product.data, ext: product.ext, photo: photo, plan: plan) { url, bytes in
                    PhotoResult(photo: photo.id, delivery: preset.id, status: product.transcoded ? .done : .keptOriginal,
                                inBytes: photo.byteCount, outBytes: bytes, outRelativePath: url,
                                outPixelWidth: photo.pixelWidth, outPixelHeight: photo.pixelHeight,
                                encoder: product.transcoded ? "libjxl" : "copy", byteExact: true, seconds: lap())
                }
            } else if info.isCMYK {
                result = failed(photo, plan, .cmykUnsupported, seconds: lap())
            } else if let s = try decoded() {
                if preset.quality == .balanced || c.constants.chromaGate, features == nil {
                    features = c.primitives.processing.features(s)
                }
                let v = variant(s, colour: preset.colour, longEdge: preset.size.longEdge)
                let phase: MemoryTrace.Phase = v.pixelCount > MetricLane.fullResolutionPixels ? .full : .small
                MemoryTrace.mark("before \(preset.id.rawValue)")
                MemoryTrace.enter(phase)
                defer { MemoryTrace.leave(phase); MemoryTrace.mark("after \(preset.id.rawValue)") }
                result = try lossy(photo, info: info, source: s, features: features, plan: plan, variant: v, lap: lap)
            } else {
                result = failed(photo, plan, decodeFailure ?? .unreadable, seconds: lap())
            }
            try emit(result)
        }
    }

    // MARK: Lossy

    private func lossy(_ photo: SourcePhoto, info: SourceInfo, source: PixelImage, features: ImageFeatures?,
                       plan: DeliveryPlan, variant v: PixelImage, lap: () -> Double) throws -> PhotoResult {
        let c = context
        let preset = plan.preset
        guard let target = Targets.target(preset.quality, features: features) else {
            return failed(photo, plan, .encodeFailed, seconds: lap())
        }
        let meta = MetadataEditor.output(for: info, policy: preset.metadata, colour: preset.colour,
                                         xmpLayout: c.constants.xmpLayout)
        let markers = MetadataEditor.jpegMarkers(meta)
        let keepAllowed = preset.isFullSize && info.kind == .jpeg && preset.colour == .keepProfile
        let sourceBytes = info.fileBytes.count
        let p = c.primitives

        let search: SearchResult
        var encoderName = preset.format == .webp ? "libwebp" : "jpegli"
        // Variant "postpass": the AC scan script per subsampling, chosen from the first mosaic encode of that
        // subsampling (MosaicSearch always scores mosaic seeds before its first full probe).
        let scanChoices = Locked([ChromaSubsampling: JPEGScanChoice]())
        do {
            search = try c.lane.withReference(v, cancel: c.cancel) { ref -> SearchResult in
                func verify(_ data: Data) throws -> Double {
                    try c.cancel.check()
                    let candidate = try c.lane.decoding(pixels: v.pixelCount, cancel: c.cancel) { try p.decoder.decode(encoded: data) }
                    return try c.lane.score(candidate, against: ref, cancel: c.cancel)
                }
                func jpegProbe(_ d: Double, _ chroma: ChromaSubsampling) throws -> ProbeRecord {
                    try c.cancel.check()
                    let data = try p.jpeg.encode(v, distance: d, subsampling: chroma, markers: markers,
                                                 scans: scanChoices.snapshot[chroma])
                    return ProbeRecord(parameter: d, subsampling: chroma, score: try verify(data), data: data)
                }
                func jpegSearch() throws -> SearchResult {
                    if preset.isFullSize, let mosaic = p.processing.mosaic(v) {
                        return try c.lane.withReference(mosaic, cancel: c.cancel) { mosaicRef in
                            let oracle = JPEGSearchOracle(
                                proxyScore: { d, chroma in
                                    try c.cancel.check()
                                    let data = try p.jpeg.encode(mosaic, distance: d, subsampling: chroma, markers: [])
                                    if c.constants.optimizeScans, scanChoices.snapshot[chroma] == nil,
                                       let choice = try p.jpeg.chooseScans(data) {
                                        scanChoices.withLock { $0[chroma] = choice }
                                    }
                                    return try c.lane.score(try p.decoder.decode(encoded: data), against: mosaicRef, cancel: c.cancel)
                                },
                                probe: jpegProbe)
                            return try MosaicSearch.search(target: target, oracle: oracle, keepOriginalAllowed: keepAllowed,
                                                           sourceBytes: sourceBytes, chromaEnergy: features?.chromaEnergy ?? 0,
                                                           constants: c.constants)
                        }
                    }
                    return try directPostPass(DirectSearch.jpeg(target: target, constants: c.constants,
                                                                keepOriginalAllowed: keepAllowed, sourceBytes: sourceBytes,
                                                                probe: jpegProbe))
                }
                // Variant "postpass" for JPEGs found by DirectSearch (no mosaic to choose a script from): the lossless
                // scan rewrite (kept only if ImageIO decodes it to the scored pixels), then up to `zeroingAttempts`
                // rewrites zeroing isolated ±1 coefficients, each scored; the smallest passing candidate is delivered.
                func directPostPass(_ result: SearchResult) throws -> SearchResult {
                    guard c.constants.optimizeScans, case .encoded(let best) = result.outcome, best.subsampling != nil else { return result }
                    var out = result
                    var chosen = best
                    if let smaller = try JPEGPostPass.optimizeScans(best.data) {
                        let same = try c.lane.decoding(pixels: v.pixelCount, cancel: c.cancel) {
                            try ImageCompare.identical(p.decoder.decode(encoded: best.data), p.decoder.decode(encoded: smaller))
                        }
                        if same { chosen.data = smaller } else { Self.log.error("scan post-pass changed decoded pixels; keeping the scored bytes") }
                    }
                    var lo = 4, hi = 64                     // zigzag start K: hi = nothing zeroed (passes), lo = strongest
                    var attempts = 0
                    while attempts < c.constants.zeroingAttempts, hi - lo > 1, best.score > target {
                        try c.cancel.check()
                        let k = (lo + hi) / 2
                        guard let data = try JPEGPostPass.rewrite(best.data, minK: k, minRun: 2, componentMask: 7,
                                                                  optimizeScans: true) else { break }   // not a jpegli JPEG
                        let record = ProbeRecord(parameter: best.parameter, subsampling: best.subsampling, score: try verify(data), data: data)
                        out.probes.append(record)
                        attempts += 1
                        if record.passes(target) {
                            hi = k
                            if record.bytes < chosen.bytes { chosen = record }
                        } else {
                            lo = k
                        }
                    }
                    out.outcome = .encoded(chosen)
                    return out
                }
                switch preset.format {
                case .webp:
                    let prepared = try p.webp.prepare(v)
                    let web = try DirectSearch.webp(target: target, constants: c.constants) { q in
                        try c.cancel.check()
                        let data = try p.webp.encode(prepared, quality: Float(q), icc: meta.icc, exif: meta.exif, xmp: meta.xmp)
                        return ProbeRecord(parameter: q, subsampling: nil, score: try verify(data), data: data)
                    }
                    if let best = web.best { return SearchResult(outcome: .encoded(best), probes: web.probes) }
                    var fallback = try jpegSearch()
                    fallback.probes = web.probes + fallback.probes
                    fallback.usedFallback = true
                    return fallback
                default:
                    return try jpegSearch()
                }
            }
        } catch let error as JobCancelled {
            throw error
        } catch {
            Self.log.error("encode failed for \(photo.relativePath, privacy: .public) → \(preset.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return failed(photo, plan, .encodeFailed, target: target, seconds: lap())
        }
        if search.usedFallback { encoderName = "jpegli (fallback)" }

        switch search.outcome {
        case .encoded(let best):
            let ext = best.subsampling == nil ? OutputFormat.webp.fileExtension : OutputFormat.jpeg.fileExtension
            return try write(best.data, ext: ext, photo: photo, plan: plan) { url, bytes in
                PhotoResult(photo: photo.id, delivery: preset.id, status: .done, score: best.score, target: target,
                            inBytes: photo.byteCount, outBytes: bytes, outRelativePath: url, outPixelWidth: v.width,
                            outPixelHeight: v.height, encoder: best.subsampling == nil ? "libwebp" : encoderName,
                            chroma: best.subsampling, probes: search.fullProbes, seconds: lap())
            }
        case .keepOriginal:
            let data: Data
            do { data = try MetadataEditor.keptOriginal(info, policy: preset.metadata, xmpLayout: c.constants.xmpLayout) } catch {
                Self.log.error("lossless metadata rewrite failed for \(photo.relativePath, privacy: .public): \(String(describing: error), privacy: .public)")
                return failed(photo, plan, .encodeFailed, target: target, seconds: lap())
            }
            return try write(data, ext: OutputFormat.jpeg.fileExtension, photo: photo, plan: plan) { url, bytes in
                PhotoResult(photo: photo.id, delivery: preset.id, status: .keptOriginal, target: target,
                            inBytes: photo.byteCount, outBytes: bytes, outRelativePath: url,
                            outPixelWidth: source.width, outPixelHeight: source.height, encoder: "copy",
                            probes: search.fullProbes, seconds: lap())
            }
        case .unreachable:
            Self.log.error("quality \(target) unreachable for \(photo.relativePath, privacy: .public) → \(preset.name, privacy: .public) after \(search.fullProbes) probes")
            return failed(photo, plan, .qualityUnreachable, target: target, probes: search.fullProbes, seconds: lap())
        }
    }

    // MARK: Helpers

    private func write(_ data: Data, ext: String, photo: SourcePhoto, plan: DeliveryPlan,
                       make: (_ relativePath: String, _ bytes: Int64) -> PhotoResult) throws -> PhotoResult {
        let stem = plan.stems[photo.id.index] ?? photo.url.deletingPathExtension().lastPathComponent
        do {
            let written = try context.writer.write(data, directory: plan.directory, stem: stem, ext: ext,
                                                   adoptIdentical: context.adoptIdentical, cancel: context.cancel)
            return make(plan.folderName + "/" + written.url.lastPathComponent, Int64(data.count))
        } catch let error as OutputError {
            switch error {
            case .diskFull(let path): throw JobInterruption.diskFull(path: path)
            case .notWritable(let path): throw JobInterruption.outputNotWritable(path: path)
            case .wouldTouchSource, .io:
                Self.log.error("write failed for \(photo.relativePath, privacy: .public): \(error.description, privacy: .public)")
                return failed(photo, plan, .writeFailed, seconds: 0)
            }
        }
    }

    private func failed(_ photo: SourcePhoto, _ plan: DeliveryPlan, _ failure: PhotoFailure, target: Double? = nil,
                        probes: Int = 0, seconds: Double) -> PhotoResult {
        PhotoResult(photo: photo.id, delivery: plan.preset.id, status: .failed(failure), target: target,
                    inBytes: photo.byteCount, probes: probes, seconds: seconds)
    }

    private func throwIfSourceUnavailable(_ photo: SourcePhoto) throws {
        if let volume = SourceAvailability.unavailableVolume(for: photo.url, roots: context.sourceRoots) {
            throw JobInterruption.sourceUnavailable(volume: volume)
        }
    }
}

/// Distinguishes "the drive is gone" from "this file is broken" (§3.8).
enum SourceAvailability {
    /// The display name of the source volume if the photo's source root is no longer reachable, else nil.
    static func unavailableVolume(for url: URL, roots: [URL]) -> String? {
        let path = url.standardizedFileURL.path
        let root = roots.map { $0.standardizedFileURL }
            .filter { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count } ?? url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: root.path) else { return nil }
        return volumeName(for: root)
    }

    /// "/Volumes/Wedding SSD/…" → "Wedding SSD"; otherwise the volume's localized name (or the folder's name).
    static func volumeName(for url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return parts[2] }
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        if let name = try? probe.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName { return name }
        return url.lastPathComponent
    }
}
