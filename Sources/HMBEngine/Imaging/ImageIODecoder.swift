// `ImageDecoding` with ImageIO (§3.0 E6): sources and candidates decode into the image's own RGB colour space,
// unrotated (stored orientation), without ImageIO caching a second copy. Header facts come from our own JPEG walk.
import CoreGraphics
import Foundation
import HMBModel
import ImageIO

public struct ImageIODecoder: ImageDecoding {
    /// Largest accepted edge, a guard against decode bombs.
    public static let maximumDimension = 65_500

    public init() {}

    public func inspect(_ url: URL) throws -> SourceInfo {
        let data: Data
        do { data = try Data(contentsOf: url, options: Self.readingOptions(for: url)) } catch {
            throw PrimitiveError("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return try Self.inspect(data: data)
    }

    /// Memory-map only files on an internal, local volume. A mapped file on an external or network volume turns an
    /// unplugged drive into SIGBUS at the next page touch (in the decoder, the JXL transcode or a keep-original
    /// copy) instead of the read error that §3.8 maps to `.sourceUnavailable`; such files are read into memory
    /// (about 20 MB per 45 MP JPEG). Unknown volumes count as external.
    static func readingOptions(for url: URL) -> Data.ReadingOptions {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        return values?.volumeIsInternal == true && values?.volumeIsLocal == true ? .alwaysMapped : []
    }

    /// Header-only inspection of encoded bytes (no pixel decode).
    public static func inspect(data: Data) throws -> SourceInfo {
        guard let kind = sniff(data) else { throw PrimitiveError("unsupported or unrecognised image format") }
        var info = SourceInfo(kind: kind, fileBytes: data, markers: [], iccProfile: nil, exif: nil, xmp: nil,
                              orientation: 1, estimatedJPEGQuality: nil, isCMYK: false, isHoldMyByteOutput: false,
                              isArithmeticCoded: false)
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        if kind == .jpeg {
            let header = try JPEGInspector.scan(data)
            info.markers = header.markers
            info.iccProfile = header.iccProfile
            info.exif = header.exif
            info.xmp = header.xmp
            info.estimatedJPEGQuality = header.estimatedQuality
            info.isCMYK = header.isCMYK
            info.isArithmeticCoded = header.isArithmeticCoded
            info.isHoldMyByteOutput = header.isHoldMyByteOutput
        } else if let source {
            // Non-JPEG containers: the ICC of the image's colour space, and all metadata as one XMP packet
            // (ImageIO maps EXIF/TIFF/GPS into the exif:/tiff: namespaces), which the metadata policy then filters.
            if let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
               let icc = image.colorSpace?.copyICCData() {
                info.iccProfile = icc as Data
            }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
               let xmp = CGImageMetadataCreateXMPData(metadata, nil) {
                info.xmp = xmp as Data
            }
            if let model = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyColorModel] as? String {
                info.isCMYK = model == (kCGImagePropertyColorModelCMYK as String)
            }
        }
        if let source,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (1...8).contains(orientation) {
            info.orientation = orientation
        }
        return info
    }

    static func sniff(_ data: Data) -> SourceKind? {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return nil }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] {        // ISO-BMFF "ftyp"
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(brand) { return .heic }
        }
        return nil
    }

    public func decode(_ info: SourceInfo) throws -> PixelImage { try decode(encoded: info.fileBytes) }

    public func decode(encoded: Data) throws -> PixelImage {
        guard let source = CGImageSourceCreateWithData(encoded as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw PrimitiveError("ImageIO could not decode the image")
        }
        if let wrapped = Self.wrapDecoded(image) { return wrapped }
        return try Self.rasterize(image)
    }

    /// The decoded pixels as ImageIO produced them, without the copy `rasterize` makes, when they already have the
    /// engine's layout: 8-bit RGBX (byte order R, G, B, X) in an RGB colour space. Drawing such an image 1:1 into its
    /// own colour space with the copy blend mode is a plain copy, so the bytes are the ones `rasterize` would write
    /// (X is ignored everywhere). Saves one full-size buffer and its copy per decode (a 45 MP candidate: 180 MB,
    /// ~0.04 s). nil for any other layout (alpha, 16-bit, BGRX, grey, CMYK): those are rasterized as before.
    static func wrapDecoded(_ image: CGImage) -> PixelImage? {
        guard image.width > 0, image.height > 0, image.width <= maximumDimension, image.height <= maximumDimension,
              image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.alphaInfo == .noneSkipLast,
              image.byteOrderInfo == .orderDefault || image.byteOrderInfo == .order32Big,
              image.pixelFormatInfo == .packed,
              let space = image.colorSpace, space.model == .rgb,
              image.bytesPerRow >= image.width * 4, image.bytesPerRow % 4 == 0,
              let provider = image.dataProvider, let data = provider.data,
              CFDataGetLength(data) >= image.bytesPerRow * (image.height - 1) + image.width * 4,
              let base = CFDataGetBytePtr(data) else { return nil }
        return PixelImage(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow, colorSpace: space,
                          wrapping: UnsafeRawPointer(base), owner: data)
    }

    /// Draws `image` 1:1 into an RGBX8 buffer in its own RGB colour space (other colour models: sRGB). Drawing into
    /// the image's own space is a plain copy; no orientation is applied.
    static func rasterize(_ image: CGImage) throws -> PixelImage {
        guard image.width > 0, image.height > 0, image.width <= maximumDimension, image.height <= maximumDimension else {
            throw PrimitiveError("image size \(image.width)×\(image.height) outside the supported range")
        }
        let space: CGColorSpace = {
            if let own = image.colorSpace, own.model == .rgb { return own }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let pixels = PixelImage(width: image.width, height: image.height, colorSpace: space)
        guard let context = CGContext(data: pixels.pixels.baseAddress, width: pixels.width, height: pixels.height,
                                      bitsPerComponent: 8, bytesPerRow: pixels.bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PrimitiveError("could not create a bitmap context")
        }
        let rect = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        context.interpolationQuality = .none
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            context.setBlendMode(.copy)
        default:
            // Transparent sources are flattened onto white (the always-opaque contract).
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
        }
        context.draw(image, in: rect)
        return pixels
    }
}
