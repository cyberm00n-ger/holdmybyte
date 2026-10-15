// WP4 acceptance 2 (Docs/SPEC.md §5.4): Compare on 45 MP pairs — first frame ≤ 150 ms, Show Original ≤ 16 ms (one
// layer flip), full pair ≤ 600 ms. Gated by HMB_TEST_PHOTOS (local photos, never committed).
//
// The live `comparePair` belongs to WP2; until it lands, `ImageIOCompareEngine` stands in for it with what §2.4 S14
// prescribes: ImageIO thumbnails (subsampled decode) at 2× the view size first, then full decodes, both images in
// parallel and fully decoded off the main thread. The "delivered" file is an ImageIO JPEG re-encode of the source,
// written to a temporary folder (never next to the photos). Timings print with the load average.
import AppKit
import HMBFixtures
import HMBModel
@testable import HMBUI
import ImageIO
import QuartzCore
import Testing
import UniformTypeIdentifiers

struct ImageIOCompareEngine: EngineService {
    var delivered: [PhotoID: URL]

    func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error> { AsyncThrowingStream { $0.finish() } }
    func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate] { [:] }
    func preflight(_ request: JobRequest) async -> Preflight { Preflight(outputFolder: request.outputFolder, estimatedBytes: nil, notices: []) }
    func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
    func pause(_ wedding: WeddingID) async {}
    func stop(_ wedding: WeddingID) async {}
    func unfinishedJobs() async -> [UnfinishedJob] { [] }
    func discardJournal(_ wedding: WeddingID) async {}

    struct Missing: Error {}

    func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID, maxPixelSize: Int?) async throws -> ComparePair {
        guard let source = record.photos.first(where: { $0.id == photo }), let out = delivered[photo] else { throw Missing() }
        async let original = Self.decode(source.url, maxPixelSize: maxPixelSize)
        async let deliveredImage = Self.decode(out, maxPixelSize: maxPixelSize)
        guard let o = await original, let d = await deliveredImage else { throw Missing() }
        let outBytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        return ComparePair(original: SendableImage(o), delivered: SendableImage(d), originalBytes: source.byteCount,
                           deliveredBytes: outBytes, comparedAtLongEdge: nil, unavailableVolume: nil)
    }

    @concurrent static func decode(_ url: URL, maxPixelSize: Int?) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if let maxPixelSize {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize, kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

@MainActor @Suite(.serialized) struct ComparePerformanceTests {
    nonisolated static var photosFolder: URL? {
        guard let path = ProcessInfo.processInfo.environment["HMB_TEST_PHOTOS"], !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "load n/a" }
        return String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }

    static func ms(_ d: Duration?) -> Double {
        guard let d else { return .infinity }
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Re-encodes `url` as a JPEG (quality 0.6) into `folder` — a stand-in delivery of the same pixel size.
    static func makeDelivery(_ url: URL, in folder: URL) throws -> URL {
        let out = folder.appending(path: url.deletingPathExtension().lastPathComponent + "-delivered.jpg")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let destination = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return out
    }

    @Test(.enabled(if: photosFolder != nil, "set HMB_TEST_PHOTOS"))
    func fortyFiveMegapixelPairs() async throws {
        let folder = try #require(Self.photosFolder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(3)
        try #require(!files.isEmpty)
        let temp = FileManager.default.temporaryDirectory.appending(path: "hmb-wp4-perf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var photos: [SourcePhoto] = []
        var delivered: [PhotoID: URL] = [:]
        for (i, url) in files.enumerated() {
            let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any]
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            photos.append(SourcePhoto(id: PhotoID(i), url: url, relativePath: url.lastPathComponent, byteCount: size,
                                      pixelWidth: properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                      pixelHeight: properties?[kCGImagePropertyPixelHeight] as? Int ?? 0,
                                      captureDate: nil, camera: nil, kind: .jpeg, modified: Date()))
            delivered[PhotoID(i)] = try Self.makeDelivery(url, in: temp)
        }
        var record = Fixtures.finnUndLissy
        record.photos = photos
        record.deliveries = [DeliveryPreset.builtIns[0]]
        record.results = []
        let engine = ImageIOCompareEngine(delivered: delivered)
        let thumbnails = FixtureThumbnails(photoFolder: nil)

        // An offscreen 1120 × 780 canvas on a 2× backing, as in the default window.
        let view = CompareCanvasView(drawsWithLayers: true)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Tokens.Layout.windowDefault), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let screenPixels = Int(Tokens.Layout.windowDefault.width * 2)

        var firstFrames: [Double] = [], fulls: [Double] = [], flips: [Double] = []
        for photo in photos {
            let loader = ComparePairLoader()
            let key = ComparePairLoader.Key(wedding: record.id, photo: photo.id, delivery: .couple)
            var compare = CompareState(route: CompareRoute(wedding: record.id, delivery: .couple, start: photo.id, spotCheck: false),
                                       order: .captureTime, sequence: photos.map(\.id), position: photo.id.index)
            let start = ContinuousClock.now
            loader.show(key, record: record, engine: engine, thumbnails: thumbnails, screenPixels: screenPixels, upcoming: [])
            var firstFrame: Duration?
            while loader.stage != .full && loader.failure == nil && ContinuousClock.now - start < .seconds(20) {
                if firstFrame == nil, loader.stage == .screen, let pair = loader.pair {
                    // The first real frame: hand the screen-resolution pair to the canvas and commit the layers.
                    view.update(images: CompareCanvasImages(original: pair.original, delivered: pair.delivered, differences: nil,
                                                            imageSize: CGSize(width: photo.pixelWidth, height: photo.pixelHeight)),
                                compare: compare)
                    CATransaction.flush()
                    firstFrame = ContinuousClock.now - start
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(loader.failure == nil)
            let pair = try #require(loader.pair)
            view.update(images: CompareCanvasImages(original: pair.original, delivered: pair.delivered, differences: nil,
                                                    imageSize: CGSize(width: pair.delivered.cgImage.width, height: pair.delivered.cgImage.height)),
                        compare: compare)
            CATransaction.flush()
            let full = loader.timings?.full
            // Show Original: one visibility flip, committed.
            compare.showsOriginal = true
            let flipStart = ContinuousClock.now
            view.update(images: CompareCanvasImages(original: pair.original, delivered: pair.delivered, differences: nil,
                                                    imageSize: CGSize(width: pair.delivered.cgImage.width, height: pair.delivered.cgImage.height)),
                        compare: compare)
            CATransaction.flush()
            let flip = ContinuousClock.now - flipStart
            firstFrames.append(Self.ms(firstFrame ?? loader.timings?.screen))
            fulls.append(Self.ms(full))
            flips.append(Self.ms(flip))
            print(String(format: "[WP4] compare %@ (%d×%d): first frame %.0f ms, full pair %.0f ms, original flip %.2f ms (%@)",
                         photo.relativePath, photo.pixelWidth, photo.pixelHeight, firstFrames.last!, fulls.last!, flips.last!,
                         Self.loadAverage()))
        }
        let median = { (values: [Double]) in values.sorted()[values.count / 2] }
        print(String(format: "[WP4] compare medians over %d photos: first frame %.0f ms, full pair %.0f ms, flip %.2f ms (%@)",
                     photos.count, median(firstFrames), median(fulls), median(flips), Self.loadAverage()))
        // Budgets apply on a quiet machine (§3.11: 1-minute load < 3); on a loaded machine they are reported only.
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        #expect(median(flips) <= 16)
        if loads[0] < 3 {
            #expect(median(firstFrames) <= 150)
            #expect(median(fulls) <= 600)
        }
    }

    @Test func differencesOfAPairAreComputedOnTheGPU() throws {
        let original = FixtureThumbnails.synthetic(seed: 7, width: 1200, height: 800)
        let delivered = try #require(CompareDifferences.image(original: original, delivered: original, tint: (0, 0.5, 0.5)))
        #expect(delivered.width == 1200 && delivered.height == 800)
        // Identical images: no tint anywhere, only the darkened luma (≤ 30 % brightness).
        let context = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(delivered, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var brightest = 0
        for i in stride(from: 0, to: 1200 * 800 * 4, by: 4 * 97) { brightest = max(brightest, Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) }
        #expect(brightest <= Int(0.3 * 255) + 2)

        // A darkened block (Δ of tens of levels) shows in the tint; the rest stays dark.
        let changed = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        changed.draw(original, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        changed.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5))
        changed.fill(CGRect(x: 100, y: 100, width: 200, height: 200))      // bottom-left in CG coordinates
        let changedImage = try #require(changed.makeImage())
        let differences = try #require(CompareDifferences.image(original: original, delivered: changedImage, tint: (0, 1, 0)))
        context.clear(CGRect(x: 0, y: 0, width: 1200, height: 800))
        context.draw(differences, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        // Row 600 from the top of the buffer = y 200 in CG coordinates (inside the block); row 100 is outside.
        let inside = pixels + 600 * context.bytesPerRow + 200 * 4
        let outside = pixels + 100 * context.bytesPerRow + 900 * 4
        #expect(Int(inside[1]) > 200 && Int(inside[0]) < 40, "inside \(inside[0]) \(inside[1]) \(inside[2])")
        #expect(Int(outside[1]) <= Int(0.3 * 255) + 2)
    }
}
