// `ImageProcessing` with Accelerate/vImage: texture features (port of the old GrainEstimator), Lanczos resize,
// sRGB conversion and the search mosaic (§3.4).
import Accelerate
import CoreGraphics
import Foundation

public struct VImageProcessing: ImageProcessing {
    public init() {}

    // MARK: Features

    public func features(_ image: PixelImage) -> ImageFeatures {
        ImageFeatures(textureP50: GrainFeatures.textureP50(image), chromaEnergy: GrainFeatures.chromaEnergy(image))
    }

    // MARK: Resize

    /// The size `resized(_:longEdge:)` produces: the long edge becomes exactly `longEdge`, the short edge is scaled
    /// and rounded (at least 1). Nil when no downscale is needed.
    public static func resizedSize(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int)? {
        let longest = max(width, height)
        guard longEdge > 0, longest > longEdge else { return nil }
        let scale = Double(longEdge) / Double(longest)
        if width >= height { return (longEdge, max(1, Int((Double(height) * scale).rounded()))) }
        return (max(1, Int((Double(width) * scale).rounded())), longEdge)
    }

    /// Lanczos (vImage high-quality resampling) downscale; never upscales: an image already within `longEdge` is
    /// returned as is (the same instance).
    public func resized(_ image: PixelImage, longEdge: Int) -> PixelImage {
        guard let size = Self.resizedSize(width: image.width, height: image.height, longEdge: longEdge) else { return image }
        let output = PixelImage(width: size.width, height: size.height, colorSpace: image.colorSpace)
        var source = vImage_Buffer(data: image.pixels.baseAddress, height: vImagePixelCount(image.height),
                                   width: vImagePixelCount(image.width), rowBytes: image.bytesPerRow)
        var destination = vImage_Buffer(data: output.pixels.baseAddress, height: vImagePixelCount(output.height),
                                        width: vImagePixelCount(output.width), rowBytes: output.bytesPerRow)
        // The X byte is 255 or ignored everywhere, so scaling it like a colour channel is harmless.
        let error = vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        precondition(error == kvImageNoError, "vImageScale_ARGB8888 failed (\(error))")
        return output
    }

    // MARK: Colour

    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func isSRGB(_ space: CGColorSpace) -> Bool {
        if space.name == CGColorSpace.sRGB { return true }
        guard let icc = space.copyICCData(), let reference = sRGB.copyICCData() else { return false }
        return (icc as Data) == (reference as Data)
    }

    /// Perceptual-intent conversion to sRGB with a `vImageConverter`. An image that already is sRGB is returned as is.
    /// Should vImage refuse the source profile, CoreGraphics colour matching (also perceptual) converts instead: the
    /// caller embeds the sRGB profile into every converted delivery, so handing back unconverted pixels would
    /// silently mislabel them. Only if both fail is the input returned, still tagged with its own (non-sRGB) space,
    /// so `isSRGB(result.colorSpace)` tells the caller that nothing was converted.
    public func convertedToSRGB(_ image: PixelImage) -> PixelImage {
        if Self.isSRGB(image.colorSpace) { return image }
        if let converted = try? Self.convert(image, to: Self.sRGB) { return converted }
        if let converted = try? Self.convertWithCoreGraphics(image, to: Self.sRGB) { return converted }
        return image
    }

    /// Fallback conversion: draws the pixels (tagged with their own space) into a `target` bitmap context.
    static func convertWithCoreGraphics(_ image: PixelImage, to target: CGColorSpace) throws -> PixelImage {
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let output = PixelImage(width: image.width, height: image.height, colorSpace: target)
        try withExtendedLifetime(image) {
            // The provider borrows the pixels; `image` outlives the draw, and the CGImage does not escape.
            guard let provider = CGDataProvider(dataInfo: nil, data: image.pixels.baseAddress!,
                                                size: image.bytesPerRow * image.height, releaseData: { _, _, _ in }),
                  let source = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: image.bytesPerRow, space: image.colorSpace,
                                       bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider, decode: nil,
                                       shouldInterpolate: false, intent: .perceptual),
                  let context = CGContext(data: output.pixels.baseAddress, width: output.width, height: output.height,
                                          bitsPerComponent: 8, bytesPerRow: output.bytesPerRow, space: target,
                                          bitmapInfo: bitmapInfo) else {
                throw PrimitiveError("CoreGraphics cannot convert from \(image.colorSpace)")
            }
            context.interpolationQuality = .none
            context.setRenderingIntent(.perceptual)
            context.setBlendMode(.copy)
            context.draw(source, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
        }
        return output
    }

    /// Unconditional conversion (also used by tests to prove sRGB→sRGB is the identity).
    static func convert(_ image: PixelImage, to target: CGColorSpace) throws -> PixelImage {
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        var sourceFormat = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                                                colorSpace: Unmanaged.passUnretained(image.colorSpace),
                                                bitmapInfo: bitmapInfo, version: 0, decode: nil, renderingIntent: .perceptual)
        var targetFormat = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                                                colorSpace: Unmanaged.passUnretained(target),
                                                bitmapInfo: bitmapInfo, version: 0, decode: nil, renderingIntent: .perceptual)
        var error = vImage_Error(kvImageNoError)
        guard let converter = vImageConverter_CreateWithCGImageFormat(&sourceFormat, &targetFormat, nil,
                                                                       vImage_Flags(kvImageNoFlags), &error)?.takeRetainedValue(),
              error == kvImageNoError else {
            throw PrimitiveError("vImageConverter could not be created (\(error))")
        }
        let output = PixelImage(width: image.width, height: image.height, colorSpace: target)
        var source = vImage_Buffer(data: image.pixels.baseAddress, height: vImagePixelCount(image.height),
                                   width: vImagePixelCount(image.width), rowBytes: image.bytesPerRow)
        var destination = vImage_Buffer(data: output.pixels.baseAddress, height: vImagePixelCount(output.height),
                                        width: vImagePixelCount(output.width), rowBytes: output.bytesPerRow)
        let status = vImageConvert_AnyToAny(converter, &source, &destination, nil, vImage_Flags(kvImageNoFlags))
        guard status == kvImageNoError else { throw PrimitiveError("vImageConvert_AnyToAny failed (\(status))") }
        return output
    }

    // MARK: Mosaic

    public static let mosaicTile = 256
    public static let mosaicColumns = 8
    public static let mosaicRows = 4

    /// Origins of the mosaic tiles in row-major order (port of `scripts/mosaic.py` "grid": the centre of each of the
    /// 8×4 cells, floored to a multiple of 16).
    public static func mosaicOrigins(width: Int, height: Int) -> [(x: Int, y: Int)]? {
        guard width >= mosaicColumns * mosaicTile, height >= mosaicRows * mosaicTile else { return nil }
        var origins: [(x: Int, y: Int)] = []
        for row in 0..<mosaicRows {
            for column in 0..<mosaicColumns {
                let y = (row * height / mosaicRows + height / mosaicRows / 2 - mosaicTile / 2) / 16 * 16
                let x = (column * width / mosaicColumns + width / mosaicColumns / 2 - mosaicTile / 2) / 16 * 16
                origins.append((x, y))
            }
        }
        return origins
    }

    /// 8×4 grid of 256² tiles (2048×1024); nil when the image is smaller than 2048×1024.
    public func mosaic(_ image: PixelImage) -> PixelImage? {
        guard let origins = Self.mosaicOrigins(width: image.width, height: image.height) else { return nil }
        let tile = Self.mosaicTile
        let output = PixelImage(width: Self.mosaicColumns * tile, height: Self.mosaicRows * tile, colorSpace: image.colorSpace)
        let source = image.pixels.baseAddress!, destination = output.pixels.baseAddress!
        for (index, origin) in origins.enumerated() {
            let outX = (index % Self.mosaicColumns) * tile, outY = (index / Self.mosaicColumns) * tile
            for row in 0..<tile {
                (destination + (outY + row) * output.bytesPerRow + outX * 4)
                    .copyMemory(from: source + (origin.y + row) * image.bytesPerRow + origin.x * 4, byteCount: tile * 4)
            }
        }
        return output
    }
}
