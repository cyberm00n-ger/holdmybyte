import CoreGraphics
import CryptoKit
import Foundation
import HMBModel
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Grid, sidebar and proof thumbnails (Docs/SPEC.md §5.4).
///
/// - Source: `CGImageSourceCreateThumbnailAtIndex` with the embedded thumbnail first
///   (`kCGImageSourceCreateThumbnailFromImageIfAbsent`) and the EXIF orientation applied; at most 320 px.
/// - Disk cache: `<directory>/<sha256(path|size|mtime)>.jpg`, where `size` is the (clamped) requested pixel size and
///   `mtime` the file's current modification time, so editing a source invalidates its thumbnail. When the source
///   is unreachable (drive ejected), the photo's recorded `modified` date stands in, so history keeps its thumbnails.
/// - Memory cache in front (NSCache), concurrent requests for the same key share one generation, and at most
///   `maxConcurrentGenerations` thumbnails are decoded at once, on a utility queue (never the cooperative pool).
public final class DiskThumbnailCache: ThumbnailProviding, @unchecked Sendable {
    // @unchecked: every mutable member is either thread-safe (NSCache, OperationQueue) or behind a Mutex.
    public static let maxPixelSize = 320

    public let directory: URL
    private let memory = NSCache<NSString, ImageBox>()
    private let queue: OperationQueue
    private let waiters = Mutex<[String: [CheckedContinuation<SendableImage?, Never>]]>([:])
    private let counters = Mutex(Counters())

    /// How often each path produced an image (for tests and diagnostics).
    public struct Counters: Sendable, Equatable {
        public var memoryHits = 0
        public var diskHits = 0
        public var generated = 0
        public var failed = 0
    }

    public var statistics: Counters { counters.withLock { $0 } }

    public init(directory: URL = StoreLocations.thumbnails, maxConcurrentGenerations: Int = 4, memoryLimit: Int = 800) {
        self.directory = directory
        queue = OperationQueue()
        queue.name = "holdmybyte.thumbnails"
        queue.maxConcurrentOperationCount = max(1, maxConcurrentGenerations)
        queue.qualityOfService = .utility
        memory.countLimit = memoryLimit
    }

    public func thumbnail(for photo: SourcePhoto, maxPixelSize: Int) async -> SendableImage? {
        let size = Self.clamped(maxPixelSize)
        let key = cacheKey(for: photo, maxPixelSize: size)
        if let hit = memory.object(forKey: key as NSString) {
            counters.withLock { $0.memoryHits += 1 }
            return hit.image
        }
        if Task.isCancelled { return nil }
        return await withCheckedContinuation { continuation in
            let isFirst = waiters.withLock { waiting -> Bool in
                waiting[key, default: []].append(continuation)
                return waiting[key]!.count == 1
            }
            guard isFirst else { return }
            queue.addOperation { [self] in
                let image = produce(photo: photo, size: size, key: key)
                if let image { memory.setObject(ImageBox(image), forKey: key as NSString) }
                let continuations = waiters.withLock { $0.removeValue(forKey: key) ?? [] }
                for continuation in continuations { continuation.resume(returning: image) }
            }
        }
    }

    /// `sha256(path|size|mtime)` as lowercase hex.
    public func cacheKey(for photo: SourcePhoto, maxPixelSize: Int) -> String {
        // stat(2), not URL resource values: those are cached per URL instance and would miss a re-export.
        let path = photo.url.standardizedFileURL.path
        var info = stat()
        let mtime = stat(path, &info) == 0
            ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            : photo.modified
        let text = "\(path)|\(Self.clamped(maxPixelSize))|\(mtime.timeIntervalSinceReferenceDate)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func cacheFile(forKey key: String) -> URL {
        directory.appending(path: key + ".jpg", directoryHint: .notDirectory)
    }

    /// Drops the memory cache (the disk cache stays).
    public func purgeMemory() { memory.removeAllObjects() }

    /// Deletes every cached thumbnail file.
    public func removeAll() throws {
        purgeMemory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "jpg" {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func clamped(_ size: Int) -> Int { min(maxPixelSize, max(16, size)) }

    // MARK: Producing

    private func produce(photo: SourcePhoto, size: Int, key: String) -> SendableImage? {
        let file = cacheFile(forKey: key)
        if let cached = Self.load(file) {
            counters.withLock { $0.diskHits += 1 }
            return cached
        }
        guard let image = Self.generate(photo.url, maxPixelSize: size) else {
            counters.withLock { $0.failed += 1 }
            return nil
        }
        counters.withLock { $0.generated += 1 }
        write(image, to: file)
        return SendableImage(image)
    }

    private static func load(_ file: URL) -> SendableImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return SendableImage(image)
    }

    static func generate(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Atomic: written to a hidden temporary file in the cache directory, then renamed.
    private func write(_ image: CGImage, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appending(path: ".\(UUID().uuidString).tmp", directoryHint: .notDirectory)
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            if rename(temporary.path, file.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        } catch {
            storeLog.error("Thumbnail cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private final class ImageBox: NSObject {
    let image: SendableImage
    init(_ image: SendableImage) { self.image = image }
}
