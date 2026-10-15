import CoreGraphics
import Foundation
import HMBModel
import ImageIO
import Synchronization

/// Deterministic "photo-like" thumbnails (seeded warm gradients with soft shapes) for previews, snapshots and tests.
/// If `HMB_FIXTURE_PHOTOS` points at a local folder, real thumbnails from the images in it are used instead,
/// cycling by photo index (outputs stay local; never commit them).
public final class FixtureThumbnails: ThumbnailProviding {
    public let photoFolder: URL?
    private let realPhotos: [URL]
    private let cache = Mutex<[CacheKey: SendableImage]>([:])

    private struct CacheKey: Hashable { var index: Int; var seed: UInt64; var maxPixelSize: Int }

    /// The folder named by `HMB_FIXTURE_PHOTOS`, if it exists.
    public static var environmentFolder: URL? {
        guard let path = ProcessInfo.processInfo.environment["HMB_FIXTURE_PHOTOS"], !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public init(photoFolder: URL? = FixtureThumbnails.environmentFolder) {
        self.photoFolder = photoFolder
        let extensions: Set<String> = ["jpg", "jpeg", "heic", "png", "tif", "tiff"]
        realPhotos = photoFolder.map { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } ?? []
    }

    public func thumbnail(for photo: SourcePhoto, maxPixelSize: Int) async -> SendableImage? {
        image(for: photo, maxPixelSize: maxPixelSize)
    }

    /// Synchronous variant (always succeeds for synthetic images).
    public func image(for photo: SourcePhoto, maxPixelSize: Int) -> SendableImage {
        let size = max(16, maxPixelSize)
        // Seeded by the full path: every wedding's first photo is DSC00001.jpg, so the relative path alone gave all
        // history covers the same image.
        let key = CacheKey(index: photo.id.index, seed: FixtureRandom.seed(photo.url.path), maxPixelSize: size)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let image: SendableImage
        if !realPhotos.isEmpty,
           let real = Self.realThumbnail(realPhotos[Int((key.seed % 9973) + UInt64(photo.id.index)) % realPhotos.count], maxPixelSize: size) {
            image = real
        } else {
            let edge = Double(max(photo.pixelWidth, photo.pixelHeight, 1))
            let scale = Double(size) / edge
            let width = max(1, Int((Double(max(photo.pixelWidth, 1)) * scale).rounded()))
            let height = max(1, Int((Double(max(photo.pixelHeight, 1)) * scale).rounded()))
            image = SendableImage(Self.synthetic(seed: key.seed ^ UInt64(photo.id.index), width: width, height: height))
        }
        cache.withLock { $0[key] = image }
        return image
    }

    static func realThumbnail(_ url: URL, maxPixelSize: Int) -> SendableImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(SendableImage.init)
    }

    /// A seeded, photo-like sRGB image: a warm (sometimes green or dusk-blue) vertical gradient, a horizon glow,
    /// a few soft blobs (people, foliage, bokeh) and a vignette.
    public static func synthetic(seed: UInt64, width: Int, height: Int) -> CGImage {
        var random = FixtureRandom(seed: seed)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)

        let mood = random.unit()
        let hue: Double = mood < 0.62 ? random.uniform(0.04...0.11) : mood < 0.85 ? random.uniform(0.22...0.36) : random.uniform(0.58...0.66)
        func color(_ hue: Double, _ saturation: Double, _ brightness: Double, _ alpha: Double = 1) -> CGColor {
            let (r, g, b) = hsb(hue, saturation, brightness)
            return CGColor(colorSpace: space, components: [r, g, b, alpha])!
        }

        let top = color(hue + random.uniform(-0.02...0.02), random.uniform(0.15...0.35), random.uniform(0.80...0.96))
        let middle = color(hue, random.uniform(0.30...0.55), random.uniform(0.58...0.80))
        let bottom = color(hue + random.uniform(-0.03...0.01), random.uniform(0.35...0.6), random.uniform(0.18...0.40))
        let gradient = CGGradient(colorsSpace: space, colors: [top, middle, bottom] as CFArray,
                                  locations: [0, CGFloat(random.uniform(0.35...0.6)), 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: w * 0.4, y: h), end: CGPoint(x: w * 0.6, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Glow (sun, window light).
        let glowCenter = CGPoint(x: w * random.uniform(0.15...0.85), y: h * random.uniform(0.45...0.85))
        let glow = CGGradient(colorsSpace: space, colors: [color(hue + 0.02, 0.25, 1, 0.75), color(hue, 0.3, 1, 0)] as CFArray,
                              locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter,
                                   endRadius: max(w, h) * random.uniform(0.25...0.5), options: [])

        // Soft shapes.
        for _ in 0..<random.int(3...6) {
            let center = CGPoint(x: w * random.uniform(0.1...0.9), y: h * random.uniform(0.1...0.65))
            let radius = min(w, h) * random.uniform(0.08...0.28)
            let shapeHue = random.unit() < 0.3 ? random.uniform(0.0...1.0) : hue + random.uniform(-0.05...0.05)
            let inner = color(shapeHue, random.uniform(0.2...0.6), random.uniform(0.2...0.95), random.uniform(0.45...0.8))
            let outer = color(shapeHue, 0.3, 0.5, 0)
            let blob = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0.15, 1])!
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: 1, y: CGFloat(random.uniform(1.2...2.4)))   // tall: figures, trees
            context.drawRadialGradient(blob, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
            context.restoreGState()
        }

        // Vignette.
        let vignette = CGGradient(colorsSpace: space, colors: [color(0, 0, 0, 0), color(0, 0, 0, 0.35)] as CFArray,
                                  locations: [0.55, 1])!
        let middlePoint = CGPoint(x: w / 2, y: h / 2)
        context.drawRadialGradient(vignette, startCenter: middlePoint, startRadius: 0, endCenter: middlePoint,
                                   endRadius: hypot(w, h) / 2, options: [.drawsAfterEndLocation])
        return context.makeImage()!
    }

    static func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> (CGFloat, CGFloat, CGFloat) {
        let h = (hue - floor(hue)) * 6
        let s = min(1, max(0, saturation)), v = min(1, max(0, brightness))
        let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return (CGFloat(r + m), CGFloat(g + m), CGFloat(b + m))
    }
}
