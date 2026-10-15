// Compare (§3.1 comparePair): the original exactly as it was scored (colour-converted and resized like the
// delivery's variant) next to the decoded delivered file. Both are oriented for display (EXIF orientation),
// and optionally downscaled to `maxPixelSize`.
import CoreGraphics
import Foundation
import HMBModel

struct CompareLoader: Sendable {
    let primitives: EnginePrimitives

    struct CompareError: Error, CustomStringConvertible { var description: String }

    func pair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID, maxPixelSize: Int?) throws -> ComparePair {
        guard let preset = record.deliveries.first(where: { $0.id == delivery }) else {
            throw CompareError(description: "unknown delivery \(delivery.rawValue)")
        }
        guard preset.isLossy else { throw CompareError(description: "the archive delivery is not compared") }
        guard let result = record.results.last(where: { $0.photo == photo && $0.delivery == delivery }),
              let relative = result.outRelativePath else {
            throw CompareError(description: "no delivered file for photo \(photo.index)")
        }
        guard let source = record.photos.first(where: { $0.id == photo }) else {
            throw CompareError(description: "unknown photo \(photo.index)")
        }
        let p = primitives
        let deliveredURL = record.outputFolder.appending(path: relative)
        let deliveredBytes = try Data(contentsOf: deliveredURL, options: .mappedIfSafe)
        var delivered = try p.decoder.decode(encoded: deliveredBytes)

        var original: PixelImage?
        var orientation = 1
        var unavailableVolume: String?
        if FileManager.default.fileExists(atPath: source.url.path), let info = try? p.decoder.inspect(source.url),
           var image = try? p.decoder.decode(info) {
            orientation = info.orientation
            if preset.colour == .convertToSRGB { image = p.processing.convertedToSRGB(image) }
            if let edge = preset.size.longEdge, edge < max(image.width, image.height) {
                image = p.processing.resized(image, longEdge: edge)
            }
            original = image
        } else {
            unavailableVolume = SourceAvailability.unavailableVolume(for: source.url, roots: record.sourceRoots)
            orientation = (try? p.decoder.inspect(deliveredURL))?.orientation ?? 1
        }
        if let maxPixelSize, maxPixelSize > 0 {
            delivered = p.processing.resized(delivered, longEdge: maxPixelSize)
            original = original.map { p.processing.resized($0, longEdge: maxPixelSize) }
        }
        return ComparePair(original: try original.map { SendableImage(try Self.cgImage(Self.oriented($0, orientation))) },
                           delivered: SendableImage(try Self.cgImage(Self.oriented(delivered, orientation))),
                           originalBytes: source.byteCount, deliveredBytes: Int64(deliveredBytes.count),
                           comparedAtLongEdge: preset.size.longEdge, unavailableVolume: unavailableVolume)
    }

    /// Applies EXIF orientation 1…8 to the stored pixels (display(x, y) = stored(f(x, y))).
    static func oriented(_ image: PixelImage, _ orientation: Int) -> PixelImage {
        guard (2...8).contains(orientation) else { return image }
        let w = image.width, h = image.height
        let swaps = orientation >= 5
        let out = PixelImage(width: swaps ? h : w, height: swaps ? w : h, colorSpace: image.colorSpace)
        let src = image.pixels.baseAddress!, dst = out.pixels.baseAddress!
        let srcRow = image.bytesPerRow / 4, dstRow = out.bytesPerRow / 4
        let s = src.assumingMemoryBound(to: UInt32.self), d = dst.assumingMemoryBound(to: UInt32.self)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let (sx, sy): (Int, Int)
                switch orientation {
                case 2: (sx, sy) = (w - 1 - x, y)
                case 3: (sx, sy) = (w - 1 - x, h - 1 - y)
                case 4: (sx, sy) = (x, h - 1 - y)
                case 5: (sx, sy) = (y, x)
                case 6: (sx, sy) = (y, h - 1 - x)
                case 7: (sx, sy) = (w - 1 - y, h - 1 - x)
                default: (sx, sy) = (w - 1 - y, x)     // 8
                }
                d[y * dstRow + x] = s[sy * srcRow + sx]
            }
        }
        return out
    }

    static func cgImage(_ image: PixelImage) throws -> CGImage {
        let data = Data(bytes: image.pixels.baseAddress!, count: image.bytesPerRow * image.height)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: image.bytesPerRow, space: image.colorSpace,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                                        | CGBitmapInfo.byteOrder32Big.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw CompareError(description: "could not create an image")
        }
        return cg
    }
}
