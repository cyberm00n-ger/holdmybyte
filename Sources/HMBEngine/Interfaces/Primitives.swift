// Internal primitives contract (Docs/SPEC.md §3.2). Frozen after WP0: WP1 implements, WP2 consumes.
// Deviation (Docs/WP0-NOTES.md): `ChromaSubsampling` is not redeclared here; the one in HMBModel is used.
import Foundation
import CoreGraphics
import HMBModel

/// 8-bit RGBA (alpha ignored, always opaque), rows contiguous with `bytesPerRow`, in `colorSpace`.
public final class PixelImage: @unchecked Sendable {
    public let width: Int, height: Int, bytesPerRow: Int
    public let colorSpace: CGColorSpace
    public let pixels: UnsafeMutableRawBufferPointer        // owned; freed in deinit
    /// Pages mapped for `pixels` (0: heap allocation or wrapped storage).
    private let mappedBytes: Int
    /// The object that owns wrapped storage (nil: `pixels` belongs to this image and is freed in deinit).
    private let owner: AnyObject?
    /// Zero-filled, bytesPerRow = width * 4 rounded up to 64.
    ///
    /// Images of 1 MB and more get their own anonymous mapping (page-aligned, zero-filled by the kernel) and give
    /// it back with `munmap` in deinit (D-ENG-10): through malloc, macOS keeps freed blocks of this size resident in
    /// its large-allocation cache, so every candidate decode and source image a job had ever freed stayed in the
    /// process's footprint.
    public init(width: Int, height: Int, colorSpace: CGColorSpace) {
        precondition(width > 0 && height > 0, "PixelImage needs a positive size")
        self.width = width
        self.height = height
        self.bytesPerRow = (width * 4 + 63) & ~63
        self.colorSpace = colorSpace
        let count = bytesPerRow * height
        if count >= Self.mapThreshold {
            let page = Int(getpagesize())
            let length = (count + page - 1) / page * page
            let base = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            precondition(base != MAP_FAILED && base != nil, "PixelImage: cannot map \(length) bytes (errno \(errno))")
            self.pixels = UnsafeMutableRawBufferPointer(start: base, count: count)
            self.mappedBytes = length
        } else {
            self.pixels = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 64)
            self.pixels.initializeMemory(as: UInt8.self, repeating: 0)
            self.mappedBytes = 0
        }
        self.owner = nil
    }

    /// Wraps pixels someone else owns (a decoder's output buffer) without copying; `owner` is retained for the
    /// image's lifetime. Such an image is read-only by contract: nothing in the engine writes into a decoded image.
    init(width: Int, height: Int, bytesPerRow: Int, colorSpace: CGColorSpace, wrapping base: UnsafeRawPointer,
         owner: AnyObject) {
        precondition(width > 0 && height > 0 && bytesPerRow >= width * 4, "PixelImage: invalid wrapped geometry")
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.colorSpace = colorSpace
        self.pixels = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(mutating: base), count: bytesPerRow * height)
        self.mappedBytes = 0
        self.owner = owner
    }
    deinit {
        if owner != nil { return }
        if mappedBytes > 0 { munmap(pixels.baseAddress, mappedBytes) } else { pixels.deallocate() }
    }
    static let mapThreshold = 1 << 20
    public var pixelCount: Int { width * height }
}

public struct JPEGMarker: Sendable, Hashable { public var code: UInt8; public var payload: Data }   // 0xE0…0xEF, 0xFE

public struct SourceInfo: Sendable {
    public var kind: SourceKind
    public var fileBytes: Data                  // memory-mapped
    public var markers: [JPEGMarker]            // JPEG only: APPn + COM in file order
    public var iccProfile: Data?
    public var exif: Data?                       // TIFF-structured EXIF payload without the "Exif\0\0" prefix
    public var xmp: Data?
    public var orientation: Int                  // 1…8
    public var estimatedJPEGQuality: Int?        // from DQT (IJG scale)
    public var isCMYK: Bool
    public var isHoldMyByteOutput: Bool          // COM marker "holdmybyte" present
    public var isArithmeticCoded: Bool
}

public struct ImageFeatures: Sendable { public var textureP50: Double; public var chromaEnergy: Double }

public protocol ImageDecoding: Sendable {
    func inspect(_ url: URL) throws -> SourceInfo                         // no pixel decode
    func decode(_ info: SourceInfo) throws -> PixelImage                  // full resolution, stored orientation
    func decode(encoded: Data) throws -> PixelImage                       // candidate decode (JPEG/WebP)
}
public protocol ImageProcessing: Sendable {
    func features(_ image: PixelImage) -> ImageFeatures                   // port of GrainEstimator.statistics(p50) + chromaEnergy
    func resized(_ image: PixelImage, longEdge: Int) -> PixelImage        // vImage high-quality (Lanczos); never upscales
    func convertedToSRGB(_ image: PixelImage) -> PixelImage               // perceptual intent via vImageConverter
    func mosaic(_ image: PixelImage) -> PixelImage?                       // 8×4 grid of 256² tiles; nil if < 2048×1024
}
public protocol JPEGEncoding: Sendable {
    func encode(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling,
                markers: [JPEGMarker]) throws -> Data                     // jpegli, progressive level 2, adaptive quant on
    /// A candidate that is only scored, never delivered (the search mosaic): the same coefficients as `encode`, so
    /// it decodes to the same pixels, but its bytes may differ (fewer scans). Default: `encode`.
    func encodeForScoring(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling) throws -> Data
}
public extension JPEGEncoding {
    func encodeForScoring(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling) throws -> Data {
        try encode(image, distance: distance, subsampling: subsampling, markers: [])
    }
}
/// Opaque, prepared (sharp-YUV converted) WebP input. WP1 subclasses or wraps `hmb_webp_prepared*`; freed in deinit.
open class WebPPrepared: @unchecked Sendable { public init() {} }
public protocol WebPEncoding: Sendable {
    func prepare(_ image: PixelImage) throws -> WebPPrepared              // sharp-YUV conversion once
    func encode(_ prepared: WebPPrepared, quality: Float, icc: Data?, exif: Data?, xmp: Data?) throws -> Data   // method 4
}
public protocol JXLTranscoding: Sendable {
    func transcodeLossless(jpeg: Data, effort: Int) throws -> Data
    func reconstructJPEG(jxl: Data) throws -> Data
}
public protocol MetricReference: AnyObject, Sendable { var width: Int { get }; var height: Int { get } }
public protocol PerceptualMetric: Sendable {
    func prepareReference(_ image: PixelImage) throws -> any MetricReference   // GPU pyramid of the reference, reused per candidate
    func score(_ candidate: PixelImage, against reference: any MetricReference) throws -> Double
    func release(_ reference: any MetricReference)
}

public struct EnginePrimitives: Sendable {
    public var decoder: any ImageDecoding
    public var processing: any ImageProcessing
    public var jpeg: any JPEGEncoding
    public var webp: any WebPEncoding
    public var jxl: any JXLTranscoding
    public var metric: any PerceptualMetric
    // `public static func live() throws -> EnginePrimitives` is in Primitives+Live.swift (WP1);
    // `public static func fakes() -> EnginePrimitives` is in Primitives+Fakes.swift (WP0).

    /// Memberwise (addition to §3.2, so tests and the bench can mix live and fake components).
    public init(decoder: any ImageDecoding, processing: any ImageProcessing, jpeg: any JPEGEncoding,
                webp: any WebPEncoding, jxl: any JXLTranscoding, metric: any PerceptualMetric) {
        self.decoder = decoder; self.processing = processing; self.jpeg = jpeg
        self.webp = webp; self.jxl = jxl; self.metric = metric
    }
}

/// Error thrown by primitives. Messages are for logs, not for the UI.
public struct PrimitiveError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
