// WP4 acceptance 3: the thumbnail cache is invalidated by mtime; orientation applied; ≤ 320 px; shared generations.
import CoreGraphics
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBStore
import Testing

@Suite struct DiskThumbnailCacheTests {
    /// A copy of a synthetic fixture in `folder` (never the fixture itself), with a whole-second mtime.
    static func photo(copying fixture: URL, into folder: URL, modified: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) throws -> SourcePhoto {
        let url = folder.appending(path: fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return SourcePhoto(id: PhotoID(0), url: url, relativePath: url.lastPathComponent, byteCount: size,
                           pixelWidth: 640, pixelHeight: 427, captureDate: nil, camera: nil, kind: .jpeg, modified: modified)
    }

    @Test func generatesOrientedThumbnailWithinSizeAndCachesOnDisk() async throws {
        let temp = try TemporaryDirectory("thumbs")
        defer { temp.cleanUp() }
        let photo = try Self.photo(copying: TestFixtureFiles.orientation6, into: temp.url)
        let cacheDir = temp.url.appending(path: "Cache", directoryHint: .isDirectory)
        let cache = DiskThumbnailCache(directory: cacheDir)

        let image = try #require(await cache.thumbnail(for: photo, maxPixelSize: 1000))
        // Stored 640×427 with orientation 6 → displayed portrait; clamped to 320.
        #expect(image.cgImage.height == 320)
        #expect(image.cgImage.width < image.cgImage.height)
        let key = cache.cacheKey(for: photo, maxPixelSize: 320)
        #expect(key.count == 64)
        #expect(FileManager.default.fileExists(atPath: cache.cacheFile(forKey: key).path))
        #expect(cache.statistics.generated == 1)

        // Same instance: memory. New instance: disk.
        _ = await cache.thumbnail(for: photo, maxPixelSize: 320)
        #expect(cache.statistics.memoryHits == 1)
        let relaunched = DiskThumbnailCache(directory: cacheDir)
        let fromDisk = try #require(await relaunched.thumbnail(for: photo, maxPixelSize: 400))
        #expect(relaunched.statistics.diskHits == 1 && relaunched.statistics.generated == 0)
        #expect(fromDisk.cgImage.width == image.cgImage.width && fromDisk.cgImage.height == image.cgImage.height)
        // No temporary files are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func changingTheModificationTimeInvalidates() async throws {
        let temp = try TemporaryDirectory("thumbs")
        defer { temp.cleanUp() }
        let photo = try Self.photo(copying: TestFixtureFiles.gradientSRGB, into: temp.url)
        let cache = DiskThumbnailCache(directory: temp.url.appending(path: "Cache"))
        _ = await cache.thumbnail(for: photo, maxPixelSize: 200)
        let before = cache.cacheKey(for: photo, maxPixelSize: 200)

        // The photographer re-exports the photo: new content, new mtime.
        try FileManager.default.removeItem(at: photo.url)
        try FileManager.default.copyItem(at: TestFixtureFiles.rampsP3, to: photo.url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 800_000_100)], ofItemAtPath: photo.url.path)
        let after = cache.cacheKey(for: photo, maxPixelSize: 200)
        #expect(after != before)
        _ = await cache.thumbnail(for: photo, maxPixelSize: 200)
        #expect(cache.statistics.generated == 2)
        // Size is part of the key too.
        #expect(cache.cacheKey(for: photo, maxPixelSize: 100) != after)
    }

    @Test func unreachableSourceStillHitsTheCacheViaRecordedDate() async throws {
        let temp = try TemporaryDirectory("thumbs")
        defer { temp.cleanUp() }
        let photo = try Self.photo(copying: TestFixtureFiles.gradientSRGB, into: temp.url)
        let cacheDir = temp.url.appending(path: "Cache")
        _ = await DiskThumbnailCache(directory: cacheDir).thumbnail(for: photo, maxPixelSize: 160)
        try FileManager.default.removeItem(at: photo.url)          // the drive was ejected
        let cache = DiskThumbnailCache(directory: cacheDir)
        #expect(await cache.thumbnail(for: photo, maxPixelSize: 160) != nil)
        #expect(cache.statistics.diskHits == 1)
        // A photo that was never cached and is unreachable gives nil, not a crash.
        var missing = photo
        missing.url = temp.url.appending(path: "nope.jpg")
        #expect(await cache.thumbnail(for: missing, maxPixelSize: 160) == nil)
        #expect(cache.statistics.failed == 1)
    }

    @Test func concurrentRequestsShareOneGeneration() async throws {
        let temp = try TemporaryDirectory("thumbs")
        defer { temp.cleanUp() }
        let photo = try Self.photo(copying: TestFixtureFiles.mosaicSource, into: temp.url)
        let cache = DiskThumbnailCache(directory: temp.url.appending(path: "Cache"), maxConcurrentGenerations: 2)
        let images = await withTaskGroup(of: SendableImage?.self) { group in
            for _ in 0..<24 { group.addTask { await cache.thumbnail(for: photo, maxPixelSize: 256) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(images.allSatisfy { $0 != nil })
        let stats = cache.statistics
        #expect(stats.generated == 1)
    }
}
