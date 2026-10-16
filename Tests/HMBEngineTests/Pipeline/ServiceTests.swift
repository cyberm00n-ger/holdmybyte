// Estimator (fakes), learned estimates, preflight and compare pairs.
import CoreGraphics
import Darwin
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite struct EstimatorTests {
    @Test func sampleIndices() {
        #expect(Estimator.sampleIndices(count: 535).count == 12)
        #expect(Estimator.sampleIndices(count: 535) == (0..<12).map { Int((Double($0) + 0.5) * 535 / 12) })
        #expect(Estimator.sampleIndices(count: 5) == [0, 1, 2, 3, 4])
        #expect(Estimator.sampleIndices(count: 0).isEmpty)
    }

    @Test func estimatesEveryDeliveryWithArchiveRule() async throws {
        let dir = TempDir("estimate")
        let root = dir.sub("src")
        let pngs = Synth.pngWedding(in: root, count: 20)
        let jpeg = root.appending(path: "x.jpg")
        Synth.jpeg(at: jpeg)
        let photos = sourcePhotos(pngs + [jpeg], root: root)
        let engine = fakeEngine(dir)
        let estimates = try await engine.estimate(photos: photos, deliveries: lossyPresets)
        #expect(Set(estimates.keys) == [.website, .couple, .archive])
        let pngBytes = photos.dropLast().reduce(Int64(0)) { $0 + $1.byteCount }
        let jpegBytes = photos.last!.byteCount
        #expect(estimates[.archive]?.bytes == pngBytes + Int64((0.78 * Double(jpegBytes)).rounded()))
        let total = photos.reduce(Int64(0)) { $0 + $1.byteCount }
        for (_, e) in estimates {
            #expect(e.bytes > 0)
            #expect(abs(e.fractionOfSource - Double(e.bytes) / Double(total)) < 1e-9)
        }
        #expect(estimates[.archive]?.secondsPerPhoto == DeliveryKind.archive.defaultSecondsPerPhoto)
        // Preflight now uses the estimate.
        let request = makeRequest(photos: photos, roots: [root], output: dir.sub("o").appending(path: "D"), deliveries: lossyPresets)
        let preflight = await engine.preflight(request)
        #expect(preflight.estimatedBytes == estimates.values.reduce(0) { $0 + $1.bytes })
        #expect(preflight.canStart)
    }

    @Test func estimateIsCancellable() async throws {
        let dir = TempDir("estcancel")
        let root = dir.sub("src")
        let photos = sourcePhotos(Synth.pngWedding(in: root, count: 24), root: root)
        let engine = fakeEngine(dir, primitives: .slowFakes(delay: 0.5)) { $0.estimateConcurrency = 2 }
        let task = Task { try await engine.estimate(photos: photos, deliveries: lossyPresets) }
        try await Task.sleep(for: .milliseconds(150))
        let start = monotonicSeconds()
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        // 1.5 s is the product budget on a quiet machine. Under load the scheduler alone adds
        // seconds; an uncancelled estimate of 24 photos at 0.5 s per fake call would take far longer.
        #expect(monotonicSeconds() - start < (loadAverage() < 3 ? 1.5 : 8.0))
    }

    @Test func learnedKappaFoldsAndResets() {
        let suite = "hmb-tests-\(UUID().uuidString)"
        let learned = LearnedEstimates(suite: suite)
        #expect(learned.kappa(.fullJPEG) == 1.0)
        learned.foldBytes(.fullJPEG, actual: 120, estimated: 100, kappaUsed: 1.0)    // observed κ 1.2
        #expect(abs(learned.kappa(.fullJPEG) - (0.3 * 1.2 + 0.7 * 1.0)) < 1e-9)
        learned.foldSeconds(.archive, secondsPerPhoto: 1.0)
        #expect(abs(learned.secondsPerPhoto(.archive) - (0.3 * 1.0 + 0.7 * 0.67)) < 1e-9)
        LearnedEstimates.reset(suite: suite)
        #expect(learned.kappa(.fullJPEG) == 1.0)
        #expect(learned.secondsPerPhoto(.archive) == 0.67)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

@Suite struct PreflightTests {
    func setup() -> (TempDir, URL, [SourcePhoto]) {
        let dir = TempDir("preflight")
        let root = dir.sub("Finn und Lissy/fertig")
        return (dir, root, sourcePhotos(Synth.pngWedding(in: root, count: 2), root: root))
    }

    @Test func existingFolderGetsSuffixAndNothingIsWritten() async throws {
        let (dir, root, photos) = setup()
        let output = dir.sub("Finn und Lissy/Finn und Lissy \u{2013} Deliveries")
        _ = dir.sub("Finn und Lissy/Finn und Lissy \u{2013} Deliveries 2")
        let before = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path).sorted()
        let p = await fakeEngine(dir).preflight(makeRequest(photos: photos, roots: [root], output: output, deliveries: lossyPresets))
        #expect(p.outputFolder.lastPathComponent == "Finn und Lissy \u{2013} Deliveries 3")
        #expect(p.notices.contains(.outputFolderExists(existing: "Finn und Lissy \u{2013} Deliveries",
                                                       used: "Finn und Lissy \u{2013} Deliveries 3")))
        #expect(p.canStart)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path).sorted() == before)
        // Create More: the existing folder is expected and used as is.
        let more = await fakeEngine(dir).preflight(makeRequest(photos: photos, roots: [root], output: output,
                                                               deliveries: lossyPresets, append: true))
        #expect(more.outputFolder == output.standardizedFileURL)
        #expect(!more.notices.contains { if case .outputFolderExists = $0 { true } else { false } })
    }

    @Test func blocksInsideSourceNotWritableAndNoSpace() async throws {
        let (dir, root, photos) = setup()
        let engine = fakeEngine(dir)
        let inside = await engine.preflight(makeRequest(photos: photos, roots: [root], output: root.appending(path: "Out"),
                                                        deliveries: lossyPresets))
        #expect(inside.notices == [.outputInsideSource] && !inside.canStart)
        let caseVariant = URL(fileURLWithPath: root.path.uppercased()).appending(path: "Out")
        let variant = await engine.preflight(makeRequest(photos: photos, roots: [root], output: caseVariant, deliveries: lossyPresets))
        #expect(!variant.canStart)

        let locked = dir.sub("locked")
        chmod(locked.path, 0o555)
        defer { chmod(locked.path, 0o755) }
        let readOnly = await engine.preflight(makeRequest(photos: photos, roots: [root], output: locked.appending(path: "D"),
                                                          deliveries: lossyPresets))
        #expect(readOnly.notices.contains { if case .notWritable = $0 { true } else { false } })
        #expect(!readOnly.canStart)

        let huge = PreflightCheck.run(makeRequest(photos: photos, roots: [root], output: dir.sub("o").appending(path: "D"),
                                                  deliveries: lossyPresets), estimatedBytes: Int64.max / 4)
        #expect(huge.notices.contains { if case .notEnoughSpace = $0 { true } else { false } })
    }
}

@Suite struct CompareTests {
    @Test func pairMatchesTheScoredVariantAndHandlesAMissingOriginal() async throws {
        let dir = TempDir("compare")
        let root = dir.sub("src")
        let photos = sourcePhotos(Synth.pngWedding(in: root, count: 2), root: root)
        let engine = fakeEngine(dir)
        let output = dir.sub("o").appending(path: "D")
        let request = makeRequest(photos: photos, roots: [root], output: output, deliveries: lossyPresets)
        let log = await collect(engine.run(request, resume: false))
        let record = WeddingRecord(id: request.wedding, name: request.name, createdAt: Date(), weddingDate: nil, camera: nil,
                                   sourceRoots: [root], sourceBookmarks: [], photos: photos, deliveries: lossyPresets,
                                   deliveryCompletedAt: [:], outputFolder: output, outputBookmark: nil, naming: .default,
                                   phase: .finished, results: log.results, startedAt: nil, finishedAt: nil,
                                   activeSeconds: 0, viewed: false)
        let web = try await engine.comparePair(record: record, photo: PhotoID(0), delivery: .website, maxPixelSize: nil)
        #expect(web.original?.cgImage.width == 64 && web.original?.cgImage.height == 43)
        #expect(web.delivered.cgImage.width == 64)
        #expect(web.comparedAtLongEdge == 64)
        let small = try await engine.comparePair(record: record, photo: PhotoID(1), delivery: .couple, maxPixelSize: 48)
        #expect(small.delivered.cgImage.width == 48 && small.original?.cgImage.width == 48)
        #expect(small.comparedAtLongEdge == nil)
        await #expect(throws: (any Error).self) {
            _ = try await engine.comparePair(record: record, photo: PhotoID(0), delivery: .archive, maxPixelSize: nil)
        }
        try FileManager.default.moveItem(at: root, to: dir.url.appending(path: "gone"))
        let missing = try await engine.comparePair(record: record, photo: PhotoID(0), delivery: .website, maxPixelSize: nil)
        #expect(missing.original == nil)
        #expect(missing.unavailableVolume != nil)
    }

    @Test func orientationMapping() {
        // 3×2 stored image with distinct pixels; check where stored (0,0) and (2,0) land for each orientation.
        let image = PixelImage(width: 3, height: 2, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let p = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<2 { for x in 0..<3 { p[y * image.bytesPerRow + x * 4] = UInt8(10 * y + x) } }
        func at(_ img: PixelImage, _ x: Int, _ y: Int) -> UInt8 {
            img.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)[y * img.bytesPerRow + x * 4]
        }
        let r6 = CompareLoader.oriented(image, 6)          // rotate 90° clockwise for display
        #expect(r6.width == 2 && r6.height == 3)
        #expect(at(r6, 1, 0) == 0 && at(r6, 0, 0) == 10 && at(r6, 1, 2) == 2)
        let r8 = CompareLoader.oriented(image, 8)          // rotate 90° counter-clockwise
        #expect(at(r8, 0, 2) == 0 && at(r8, 0, 0) == 2)
        let r3 = CompareLoader.oriented(image, 3)
        #expect(at(r3, 2, 1) == 0 && at(r3, 0, 0) == 12)
        let r2 = CompareLoader.oriented(image, 2)
        #expect(at(r2, 2, 0) == 0)
        #expect(CompareLoader.oriented(image, 1) === image)
    }
}
