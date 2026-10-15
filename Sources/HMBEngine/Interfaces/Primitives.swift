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
    /// Zero-filled, bytesPerRow = width * 4 rounded up to 64.
    public init(width: Int, height: Int, colorSpace: CGColorSpace) {
        precondition(width > 0 && height > 0, "PixelImage needs a positive size")
        self.width = width
        self.height = height
        self.bytesPerRow = (width * 4 + 63) & ~63
        self.colorSpace = colorSpace
        self.pixels = UnsafeMutableRawBufferPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
        self.pixels.initializeMemory(as: UInt8.self, repeating: 0)
    }
    deinit { pixels.deallocate() }
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
