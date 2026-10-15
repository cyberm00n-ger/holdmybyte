// WP2 test support: temporary folders, synthetic photos, slow/faulty fakes and event collection.
// Everything is generated at test time under the temporary directory; no client photos are involved.
import CoreGraphics
import CryptoKit
import Foundation
@testable import HMBEngine
import HMBModel
import ImageIO
import UniformTypeIdentifiers

/// A temporary folder removed on deinit.
final class TempDir: @unchecked Sendable {
    let url: URL
    init(_ label: String = "wp2") {
        url = FileManager.default.temporaryDirectory
            .appending(path: "hmb-\(label)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func sub(_ path: String) -> URL {
        let u = url.appending(path: path, directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

enum Synth {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Deterministic photo-like content: warm gradient, soft discs and mild noise.
    static func cgImage(width: Int, height: Int, seed: UInt32) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        var state = seed &* 2_654_435_761 &+ 12345
        func next() -> UInt32 { state = state &* 1_664_525 &+ 1_013_904_223; return state >> 24 }
        let cx = Double(Int(seed % 7) + 2) / 10 * Double(width), cy = Double(Int(seed % 5) + 3) / 10 * Double(height)
        let r = Double(min(width, height)) * 0.3
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                let gx = Double(x) / Double(max(1, width - 1)), gy = Double(y) / Double(max(1, height - 1))
                let inside = hypot(Double(x) - cx, Double(y) - cy) < r ? 40.0 : 0
                let noise = Double(next() & 15) - 7.5
                pixels[i] = UInt8(max(0, min(255, 180 * gx + 50 + inside + noise)))
                pixels[i + 1] = UInt8(max(0, min(255, 120 * gy + 60 + inside / 2 + noise)))
                pixels[i + 2] = UInt8(max(0, min(255, 90 * (1 - gx) + 40 + noise)))
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
    }

    /// `count` PNG photos (non-JPEG sources: never kept as originals) named IMG_0001.png …
    @discardableResult
    static func pngWedding(in folder: URL, count: Int, width: Int = 96, height: Int = 64, seed: UInt32 = 1) -> [URL] {
        (0..<count).map { i in
            let url = folder.appending(path: String(format: "IMG_%04d.png", i + 1))
            write(cgImage(width: width, height: height, seed: seed &+ UInt32(i)), to: url, type: .png)
            return url
        }
    }

    /// A JPEG with capture date, camera and the given extra metadata.
    static func jpeg(at url: URL, width: Int = 120, height: Int = 80, seed: UInt32 = 1, date: String? = nil,
                     model: String? = nil, quality: Double = 0.92, extra: [CFString: Any] = [:]) {
        var props = extra
        props[kCGImageDestinationLossyCompressionQuality] = quality
        if let date {
            var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = date
            props[kCGImagePropertyExifDictionary] = exif
        }
        if let model {
            var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFModel] = model
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        write(cgImage(width: width, height: height, seed: seed), to: url, type: .jpeg, properties: props)
    }
}

/// SourcePhoto records for files, in the given order (bypasses the scanner).
func sourcePhotos(_ urls: [URL], root: URL) -> [SourcePhoto] {
    urls.enumerated().map { i, url in
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let kind: SourceKind = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        return SourcePhoto(id: PhotoID(i), url: url, relativePath: Scanner.relativePath(url, root: root), byteCount: size,
                           pixelWidth: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                           pixelHeight: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
                           captureDate: nil, camera: nil, kind: kind, modified: Date(timeIntervalSince1970: 0))
    }
}

func makeRequest(name: String = "Finn und Lissy", photos: [SourcePhoto], roots: [URL], output: URL,
                 deliveries: [DeliveryPreset] = DeliveryPreset.builtIns, wedding: WeddingID = WeddingID(),
                 naming: NamingScheme = .default, onlyPhotos: Set<PhotoID>? = nil, append: Bool = false) -> JobRequest {
    JobRequest(wedding: wedding, name: name, photos: photos, sourceRoots: roots, deliveries: deliveries,
               outputFolder: output, naming: naming, processorUse: .automatic, onlyPhotos: onlyPhotos,
               appendToExistingFolder: append)
}

/// Every regular file below `folder` (relative path → SHA-256), ignoring nothing: partial folders included.
func fileManifest(_ folder: URL) -> [String: String] {
    var out: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
    for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let data = try! Data(contentsOf: url)
        out[Scanner.relativePath(url, root: folder)] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return out
}

/// Timestamped events of one run.
struct EventLog: Sendable {
    var events: [(t: Double, event: EngineEvent)] = []
    var phases: [JobPhase] {
        events.compactMap { if case .phase(_, let p) = $0.event { p } else { nil } }
    }
    var terminal: JobPhase? { phases.last }
    var results: [PhotoResult] {
        events.flatMap { entry -> [PhotoResult] in
            if case .results(_, let r) = entry.event { return r }
            return []
        }
    }
    var progress: [JobProgress] {
        events.compactMap { if case .progress(let p) = $0.event { p } else { nil } }
    }
}

func collect(_ stream: AsyncStream<EngineEvent>, onEvent: (@Sendable (EngineEvent) async -> Void)? = nil) async -> EventLog {
    var log = EventLog()
    for await event in stream {
        log.events.append((monotonicSeconds(), event))
        await onEvent?(event)
    }
    return log
}

func fakeEngine(_ dir: TempDir, primitives: EnginePrimitives = .fakes(), workers: Int = 2,
                options: (inout EngineOptions) -> Void = { _ in }) -> LiveEngine {
    var o = EngineOptions(workerCount: workers, serializeMetric: false,
                          learnedEstimatesSuite: "hmb-tests-\(UUID().uuidString)")
    options(&o)
    return LiveEngine(primitives: primitives, supportDirectory: dir.sub("support"), options: o)
}

// MARK: - Slow and faulty fakes

struct SlowJPEG: JPEGEncoding {
    var base = FakeJPEGEncoder()
    var delay: Double
    func encode(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling, markers: [JPEGMarker]) throws -> Data {
        Thread.sleep(forTimeInterval: delay)
        return try base.encode(image, distance: distance, subsampling: subsampling, markers: markers)
    }
}

struct SlowWebP: WebPEncoding {
    var base = FakeWebPEncoder()
    var delay: Double
    func prepare(_ image: PixelImage) throws -> WebPPrepared { try base.prepare(image) }
    func encode(_ prepared: WebPPrepared, quality: Float, icc: Data?, exif: Data?, xmp: Data?) throws -> Data {
        Thread.sleep(forTimeInterval: delay)
        return try base.encode(prepared, quality: quality, icc: icc, exif: exif, xmp: xmp)
    }
}

/// A JXL transcoder whose reconstruction is not byte-exact.
struct LossyJXL: JXLTranscoding {
    func transcodeLossless(jpeg: Data, effort: Int) throws -> Data { FakeJXLTranscoder.magic + jpeg }
    func reconstructJPEG(jxl: Data) throws -> Data { Data(jxl.dropFirst(4).dropLast()) }
}

/// A decoder that runs `beforeInspect` for each URL (e.g. to simulate an unmounted drive).
struct HookedDecoder: ImageDecoding {
    var base = FakeDecoder()
    var beforeInspect: @Sendable (URL) -> Void
    func inspect(_ url: URL) throws -> SourceInfo { beforeInspect(url); return try base.inspect(url) }
    func decode(_ info: SourceInfo) throws -> PixelImage { try base.decode(info) }
    func decode(encoded: Data) throws -> PixelImage { try base.decode(encoded: encoded) }
}

extension EnginePrimitives {
    static func slowFakes(delay: Double) -> EnginePrimitives {
        var p = EnginePrimitives.fakes()
        p.jpeg = SlowJPEG(delay: delay)
        p.webp = SlowWebP(delay: delay)
        return p
    }
}

/// Website + Social style deliveries that always encode (PNG sources, fast with fakes).
let lossyPresets: [DeliveryPreset] = [
    DeliveryPreset(id: .website, name: "Website", symbol: "globe", format: .webp, size: .longEdge(64), quality: .web,
                   colour: .convertToSRGB, metadata: .removeLocation, folderName: "Website", isBuiltIn: false),
    DeliveryPreset(id: .couple, name: "Couple", symbol: "heart", format: .jpeg, size: .full, quality: .balanced,
                   colour: .keepProfile, metadata: .keepAll, folderName: "Couple", isBuiltIn: false),
    DeliveryPreset(id: .archive, name: "Archive", symbol: "archivebox", format: .jxlLossless, size: .full,
                   quality: .lossless, colour: .keepProfile, metadata: .keepAll, folderName: "Archive", isBuiltIn: false),
]
