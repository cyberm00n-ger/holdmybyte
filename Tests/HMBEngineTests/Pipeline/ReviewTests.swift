// Regression tests added in the WP2 review: guarantee 2 on the delivered bytes, Create More never writing into
// an existing folder, cancellable metric-lane waits, de-duplicated scans, oversized EXIF and post-EOI previews.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBFixtures
import HMBModel
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite(.serialized) struct ReviewTests {
    // MARK: Guarantee 2: the stored score is the score of the delivered bytes

    @Test func deliveredBytesRescoreToTheJournaledScore() async throws {
        let s = JobTests.pngSetup(4, label: "rescore")
        let engine = fakeEngine(s.dir)
        let output = s.output()
        let log = await JobTests.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output,
                                                         deliveries: lossyPresets))
        #expect(log.terminal == .finished)
        let p = EnginePrimitives.fakes()
        var checked = 0
        for r in log.results where r.status == .done && r.delivery != .archive {
            let preset = try #require(lossyPresets.first { $0.id == r.delivery })
            let photo = try #require(s.photos.first { $0.id == r.photo })
            let delivered = try Data(contentsOf: output.appending(path: try #require(r.outRelativePath)))
            var variant = try p.decoder.decode(try p.decoder.inspect(photo.url))
            if preset.colour == .convertToSRGB { variant = p.processing.convertedToSRGB(variant) }
            if let edge = preset.size.longEdge, edge < max(variant.width, variant.height) {
                variant = p.processing.resized(variant, longEdge: edge)
            }
            let reference = try p.metric.prepareReference(variant)
            let score = try p.metric.score(try p.decoder.decode(encoded: delivered), against: reference)
            #expect(score == r.score, "\(r.outRelativePath ?? "?")")
            #expect(score >= (r.target ?? 101))
            checked += 1
        }
        #expect(checked == 8)
    }

    // MARK: Folders

    @Test func createMoreNeverWritesIntoAnExistingFolderAndRetryUsesTheRecordedOne() async throws {
        let s = JobTests.pngSetup(3, label: "more")
        let output = s.output()
        let engine = fakeEngine(s.dir)
        let wedding = WeddingID()
        let couple = lossyPresets[1], archive = lossyPresets[2]
        _ = await JobTests.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output,
                                                   deliveries: [couple], wedding: wedding))
        // The photographer keeps an unrelated "Archive" folder in the deliveries folder.
        let theirs = output.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: theirs.appending(path: "notes.txt"))

        let more = await JobTests.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output,
                                                          deliveries: [archive], wedding: wedding, append: true))
        #expect(more.terminal == .finished)
        #expect(Set(more.results.compactMap(\.outRelativePath).map { $0.split(separator: "/")[0] }) == ["Archive 2"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: theirs.path) == ["notes.txt"])

        // A retry of one archive file lands in the folder this wedding actually used.
        try FileManager.default.removeItem(at: output.appending(path: "Archive 2/Finn-und-Lissy-0002.png"))
        let retry = await JobTests.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output,
                                                           deliveries: [archive], wedding: wedding, onlyPhotos: [PhotoID(1)]))
        #expect(retry.terminal == .finished)
        #expect(retry.results.map(\.outRelativePath) == ["Archive 2/Finn-und-Lissy-0002.png"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: theirs.path) == ["notes.txt"])
        // …and so does a retry of the delivery made by the first run, recorded before Create More.
        try FileManager.default.removeItem(at: output.appending(path: "Couple/Finn-und-Lissy-0003.jpg"))
        let retryCouple = await JobTests.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output,
                                                                 deliveries: [couple], wedding: wedding, onlyPhotos: [PhotoID(2)]))
        #expect(retryCouple.results.map(\.outRelativePath) == ["Couple/Finn-und-Lissy-0003.jpg"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == ["Couple", "Archive", "Archive 2"])
    }

    // MARK: Metric lane

    /// A metric whose `score` holds the lane for `delay` seconds.
    struct SlowMetric: PerceptualMetric {
        var base = FakeMetric()
        var delay: Double
        func prepareReference(_ image: PixelImage) throws -> any MetricReference { try base.prepareReference(image) }
        func score(_ candidate: PixelImage, against reference: any MetricReference) throws -> Double {
            Thread.sleep(forTimeInterval: delay)
            return try base.score(candidate, against: reference)
        }
        func release(_ reference: any MetricReference) {}
    }

    @Test func waitingForTheMetricLaneIsCancellable() throws {
        let lane = MetricLane(metric: SlowMetric(delay: 1.0))
        let image = PixelImage(width: 8, height: 8, colorSpace: Synth.srgb)
        let reference = try lane.metric.prepareReference(image)
        let holder = CancelToken(), waiter = CancelToken()
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        Thread {
            started.signal()
            _ = try? lane.score(image, against: reference, cancel: holder)       // holds the lane for 1 s
            finished.signal()
        }.start()
        started.wait()
        Thread.sleep(forTimeInterval: 0.1)
        waiter.request(.pause(.user))
        let t0 = monotonicSeconds()
        #expect(throws: JobCancelled.self) { _ = try lane.score(image, against: reference, cancel: waiter) }
        #expect(monotonicSeconds() - t0 < 0.5)
        finished.wait()
        // An uncancelled call still scores once the lane is free.
        #expect(try lane.score(image, against: reference, cancel: CancelToken()) == 100)
    }

    @Test func stopLatencyWithWorkersQueuedOnASlowSerialisedMetric() async throws {
        let s = JobTests.pngSetup(12, label: "stop")
        var primitives = EnginePrimitives.fakes()
        primitives.metric = SlowMetric(delay: 0.3)
        let engine = fakeEngine(s.dir, primitives: primitives, workers: 6) { $0.serializeMetric = true }
        let output = s.output()
        let request = makeRequest(photos: s.photos, roots: [s.root], output: output, deliveries: lossyPresets)
        let requested = Locked<Double?>(nil)
        let log = await JobTests.run(engine, request) { event in
            guard case .results = event else { return }
            let first = requested.withLock { t -> Bool in
                if t == nil { t = monotonicSeconds(); return true }
                return false
            }
            if first { Task.detached { await engine.stop(request.wedding) } }
        }
        #expect(log.terminal == .stopped)
        let stoppedAt = try #require(log.events.last?.t)
        let latency = stoppedAt - (requested.snapshot ?? stoppedAt)
        print(String(format: "stop latency, 6 workers on a 0.3 s serialised metric: %.3f s (load %.1f)", latency, loadAverage()))
        #expect(latency < 1.5, "stop latency \(latency) s")
        #expect(!fileManifest(output).keys.contains { $0.hasSuffix(".tmp") })
    }

    // MARK: Scanner

    @Test func aFileReachedTwiceIsScannedOnce() async throws {
        let dir = TempDir("dupes")
        let root = dir.sub("Anna und Ben")
        let sub = dir.sub("Anna und Ben/Ceremony")
        Synth.jpeg(at: root.appending(path: "a.jpg"), seed: 1, date: "2026:07:12 11:00:00")
        Synth.jpeg(at: sub.appending(path: "b.jpg"), seed: 2, date: "2026:07:12 12:00:00")
        let result = Scanner().scan([root, sub, sub.appending(path: "b.jpg")]) { _ in }
        #expect(result.photos.map(\.relativePath) == ["a.jpg", "Ceremony/b.jpg"])
        let cancelled = Scanner().scan([root], isCancelled: { true }) { _ in }
        #expect(cancelled.photos.isEmpty)
    }

    // MARK: Metadata

    @Test func oversizedEXIFLosesTheMakerNoteButKeepsOrientation() throws {
        var doc = TIFFDocument(bigEndian: true, ifd0: [TIFFEntry(tag: 0x0110, type: 2, count: 4, value: Data("Cam\0".utf8))])
        doc.setOrientation(6)
        doc.exif = [
            TIFFEntry(tag: 0x8827, type: 3, count: 1, value: Data([0x01, 0x90])),
            TIFFEntry(tag: 0x927C, type: 7, count: 70_000, value: Data(repeating: 0x42, count: 70_000)),
        ]
        let exif = doc.serialized()
        #expect(exif.count > JPEGContainer.maxPayload)
        let markers = MetadataEditor.jpegMarkers(.init(exif: exif, xmp: nil, xmpExtension: [], iptc: [], icc: nil))
        let app1 = try #require(markers.first { $0.code == 0xE1 && $0.payload.starts(with: JPEGContainer.exifPrefix) })
        #expect(app1.payload.count <= JPEGContainer.maxPayload)
        let parsed = try TIFFDocument(parsing: app1.payload.dropFirst(JPEGContainer.exifPrefix.count))
        #expect(parsed.entry(0x0112).flatMap { TIFFDocument.integer($0, big: parsed.bigEndian) } == 6)
        #expect(parsed.exif?.map(\.tag) == [0x8827])
        #expect(parsed.entry(0x0110)?.value == Data("Cam\0".utf8))
    }

    @Test func policyRewriteOfAKeptOriginalDropsPreviewsAfterEOI() throws {
        let dir = TempDir("mpf")
        let main = try Data(contentsOf: try MetadataTests.richJPEG(in: dir))
        let previewURL = dir.url.appending(path: "preview.jpg")
        Synth.jpeg(at: previewURL, width: 16, height: 16, seed: 9, extra: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.52, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
        // Main image with an APP2 MPF index, followed by an embedded preview that carries GPS.
        let parsed = try JPEGContainer.parse(main)
        var withMPF = Data([0xFF, 0xD8])
        for s in parsed.segments { try JPEGContainer.append(s, to: &withMPF) }
        try JPEGContainer.append(.init(code: 0xE2, payload: JPEGContainer.mpfPrefix + Data(repeating: 0, count: 16)), to: &withMPF)
        withMPF.append(main.subdata(in: parsed.scanOffset..<main.count))
        #expect(JPEGContainer.endOfImage(withMPF, scanOffset: try JPEGContainer.parse(withMPF).scanOffset) == withMPF.count)
        let combined = withMPF + (try Data(contentsOf: previewURL))
        let url = dir.url.appending(path: "camera.jpg")
        try combined.write(to: url)
        let info = try FakeDecoder().inspect(url)

        #expect(try MetadataEditor.keptOriginal(info, policy: .keepAll) == combined)
        for policy in [MetadataPolicy.removeLocation, .removeAll] {
            let out = try MetadataEditor.keptOriginal(info, policy: policy)
            #expect(out.suffix(2) == Data([0xFF, 0xD9]), "\(policy)")
            #expect(out.range(of: try Data(contentsOf: previewURL).prefix(64)) == nil, "\(policy)")
            #expect(!(try JPEGContainer.parse(out).segments.contains { $0.payload.starts(with: JPEGContainer.mpfPrefix) }))
            #expect(MetadataTests.pixels(out) == MetadataTests.pixels(main), "\(policy)")
            #expect(MetadataTests.properties(out)[kCGImagePropertyGPSDictionary] == nil)
        }
    }

    @Test func endOfImageWalksProgressiveScans() throws {
        let dir = TempDir("prog")
        let url = dir.url.appending(path: "p.jpg")
        Synth.jpeg(at: url, width: 64, height: 48, seed: 4, extra: [
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
        ])
        let data = try Data(contentsOf: url)
        let parsed = try JPEGContainer.parse(data)
        let sosCount = data.withUnsafeBytes { raw in
            (0..<(raw.count - 1)).filter { raw[$0] == 0xFF && raw[$0 + 1] == 0xDA }.count
        }
        #expect(sosCount > 1)          // really progressive
        #expect(JPEGContainer.endOfImage(data, scanOffset: parsed.scanOffset) == data.count)
        #expect(JPEGContainer.endOfImage(data + Data([1, 2, 3]), scanOffset: parsed.scanOffset) == data.count)
    }
}

// D-ENG-7: the optional memory budget shared by full-resolution references and archive transcodes.
@Suite struct MemoryBudgetTests {
    @Test func capsConcurrentReservationsAndLetsAnOversizeOneRunAlone() throws {
        let budget = MemoryBudget(capacity: 4)
        let live = Locked((now: 0, max: 0))
        DispatchQueue.concurrentPerform(iterations: 12) { i in
            let bytes: Int64 = i == 5 ? 9 : 1                     // one reservation larger than the whole budget
            try? budget.withReservation(bytes, cancel: nil) {
                live.withLock { $0.now += Int(bytes); $0.max = max($0.max, $0.now) }
                Thread.sleep(forTimeInterval: 0.02)
                live.withLock { $0.now -= Int(bytes) }
            }
        }
        #expect(live.snapshot.now == 0)
        #expect(live.snapshot.max <= 9)                           // the oversize one ran alone
        #expect(budget.peakReserved == 9 || budget.peakReserved <= 4)
    }

    @Test func aWaitingReservationHonoursCancellation() throws {
        let budget = MemoryBudget(capacity: 1)
        let cancel = CancelToken()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? budget.withReservation(1, cancel: nil) { entered.signal(); release.wait() }
        }
        entered.wait()
        Thread.detachNewThread {                                 // not GCD: the global queues may be saturated by other suites
            Thread.sleep(forTimeInterval: 0.1)
            _ = cancel.request(.stop)
        }
        let started = monotonicSeconds()
        #expect(throws: JobCancelled.self) { try budget.withReservation(1, cancel: cancel) {} }
        #expect(monotonicSeconds() - started < 2.0)
        release.signal()
    }
}
