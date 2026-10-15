// Acceptance §5.2.2–4, 8, 11 (with fakes): jobs, journal and resume, pause/stop, error mapping, determinism,
// event cadence, plus the per-photo pipeline end to end.
import Darwin
import Foundation
@testable import HMBEngine
import HMBFixtures
import HMBModel
import Testing

@Suite(.serialized) struct JobTests {
    static func run(_ engine: LiveEngine, _ request: JobRequest, resume: Bool = false,
                    onEvent: (@Sendable (EngineEvent) async -> Void)? = nil) async -> EventLog {
        await collect(engine.run(request, resume: resume), onEvent: onEvent)
    }

    struct Setup {
        let dir: TempDir
        let root: URL
        let photos: [SourcePhoto]
        func output(_ parent: String = "out") -> URL { dir.sub(parent).appending(path: "Finn und Lissy \u{2013} Deliveries") }
    }

    static func pngSetup(_ count: Int = 6, label: String = "job") -> Setup {
        let dir = TempDir(label)
        let root = dir.sub("Finn und Lissy/fertig")
        let urls = Synth.pngWedding(in: root, count: count)
        return Setup(dir: dir, root: root, photos: sourcePhotos(urls, root: root))
    }

    // MARK: Pipeline end to end

    @Test func fullJobWritesEveryDeliveryWithVerifiedScores() async throws {
        let s = Self.pngSetup()
        let engine = fakeEngine(s.dir)
        let output = s.output()
        let log = await Self.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output, deliveries: lossyPresets))
        #expect(log.phases.first == .running)
        #expect(log.terminal == .finished)
        let results = log.results
        #expect(results.count == 6 * 3)
        for r in results {
            switch r.delivery {
            case .archive:
                #expect(r.status == .keptOriginal && r.encoder == "copy" && r.byteExact == true)   // PNG: copied
            default:
                #expect(r.status == .done)
                #expect((r.score ?? 0) >= (r.target ?? 101))
                #expect(r.probes >= 1)
            }
            let file = output.appending(path: r.outRelativePath ?? "missing")
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect((try? Data(contentsOf: file).count).map(Int64.init) == r.outBytes)
        }
        let names = Set(results.compactMap(\.outRelativePath))
        #expect(names.contains("Website/Finn-und-Lissy-0001.webp"))
        #expect(names.contains("Couple/Finn-und-Lissy-0006.jpg"))
        #expect(names.contains("Archive/Finn-und-Lissy-0003.png"))
        let website = results.first { $0.delivery == .website }!
        #expect(website.outPixelWidth == 64 && website.outPixelHeight == 43)
        for folder in ["Website", "Couple", "Archive"] {
            #expect(!FileManager.default.fileExists(atPath: output.appending(path: "\(folder)/.holdmybyte-partial").path))
        }
        #expect(await engine.unfinishedJobs().isEmpty)
        // Sources untouched (only the six PNGs in the source folder).
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.root.path).count == 6)
        let progress = log.progress.last!
        #expect(progress.photosDone == 6 && progress.photosTotal == 6)
        #expect(progress.summaries.allSatisfy { $0.processed == 6 })
    }

    @Test func determinismTwoRunsAreByteIdentical() async throws {
        let s = Self.pngSetup()
        let a = s.output("a"), b = s.output("b")
        let wedding = WeddingID()
        _ = await Self.run(fakeEngine(s.dir, workers: 3), makeRequest(photos: s.photos, roots: [s.root], output: a,
                                                                      deliveries: lossyPresets, wedding: wedding))
        _ = await Self.run(fakeEngine(s.dir, workers: 1), makeRequest(photos: s.photos, roots: [s.root], output: b,
                                                                      deliveries: lossyPresets, wedding: wedding))
        let ma = fileManifest(a), mb = fileManifest(b)
        #expect(ma.count == 18)
        #expect(ma == mb)
    }

    // MARK: Journal and resume

    @Test func resumeAfterStopAtThreeRandomPointsMatchesUninterruptedRun() async throws {
        let s = Self.pngSetup(8, label: "resume")
        let baseline = s.output("baseline")
        _ = await Self.run(fakeEngine(s.dir), makeRequest(photos: s.photos, roots: [s.root], output: baseline,
                                                          deliveries: lossyPresets))
        let expected = fileManifest(baseline)
        #expect(expected.count == 24)

        var rng = SplitMix(seed: 2026)
        for point in 0..<3 {
            let stopAfter = 1 + Int(rng.next() % 20)
            let output = s.output("run\(point)")
            let engine = fakeEngine(s.dir, primitives: .slowFakes(delay: 0.01))
            let request = makeRequest(photos: s.photos, roots: [s.root], output: output, deliveries: lossyPresets)
            let seen = Counter()
            let first = await Self.run(engine, request) { event in
                if case .results(_, let r) = event, seen.add(r.count) >= stopAfter, seen.once() {
                    Task.detached { await engine.stop(request.wedding) }
                }
            }
            #expect(first.terminal == .stopped || first.terminal == .finished)
            let unfinished = await engine.unfinishedJobs()
            if first.terminal == .stopped { #expect(unfinished.map(\.request.wedding) == [request.wedding]) }
            let second = await Self.run(fakeEngine(s.dir), request, resume: true)
            #expect(second.terminal == .finished)
            #expect(fileManifest(output) == expected, "stop after \(stopAfter) results")
            #expect(second.results.count == 24)    // carried + new, nothing twice
        }
    }

    @Test func resumeAfterSimulatedCrashAdoptsRenamedFilesWithoutDuplicates() async throws {
        let s = Self.pngSetup(6, label: "crash")
        let baseline = s.output("baseline")
        _ = await Self.run(fakeEngine(s.dir), makeRequest(photos: s.photos, roots: [s.root], output: baseline,
                                                          deliveries: lossyPresets))
        let expected = fileManifest(baseline)

        let output = s.output("crash")
        let engine = fakeEngine(s.dir)
        let request = makeRequest(photos: s.photos, roots: [s.root], output: output, deliveries: lossyPresets)
        _ = await Self.run(engine, request)
        // Crash state: only 5 journal lines survived (+ a torn sixth), no finished marker, a stray .tmp,
        // and one renamed-but-unjournaled file deleted as if it was still in flight.
        let jobDir = Journal.directory(support: engine.supportDirectory, wedding: request.wedding)
        let journalURL = jobDir.appending(path: Journal.journalFile)
        let lines = try String(contentsOf: journalURL, encoding: .utf8).split(separator: "\n")
        let kept = lines.prefix(5).joined(separator: "\n") + "\n" + lines[5].prefix(20)
        try kept.write(to: journalURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: jobDir.appending(path: Journal.finishedFile))
        let partial = output.appending(path: "Couple/.holdmybyte-partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("half a photo".utf8).write(to: partial.appending(path: "\(UUID().uuidString).tmp"))
        let inFlight = try #require(Journal.load(directory: jobDir)).results.count
        #expect(inFlight == 5)
        try FileManager.default.removeItem(at: output.appending(path: "Archive/Finn-und-Lissy-0006.png"))

        #expect(await engine.unfinishedJobs().count == 1)
        let resumed = await Self.run(fakeEngine(s.dir), request, resume: true)
        #expect(resumed.terminal == .finished)
        #expect(fileManifest(output) == expected)
        // Journal now holds every pair exactly once as its latest entry.
        let final = try #require(Journal.load(directory: jobDir))
        #expect(Set(final.results.map(ResultKey.init)).count == 18)
        #expect(final.finished)
    }

    @Test func truncatedLastJournalLineIsTolerated() throws {
        let dir = TempDir("journal")
        let request = makeRequest(photos: [], roots: [], output: dir.url)
        let journal = try Journal.create(support: dir.url, request: request, layout: JobLayout(deliveryFolders: [:], createdOutputFolder: true))
        for i in 0..<3 { try journal.append(PhotoResult(photo: PhotoID(i), delivery: .couple, status: .done, inBytes: 10, outBytes: 5)) }
        journal.close()
        let url = journal.directory.appending(path: Journal.journalFile)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"photo\":{\"index\":3},\"deliv".utf8))
        try handle.close()
        #expect(Journal.load(directory: journal.directory)?.results.count == 3)
        let reopened = try #require(try Journal.reopen(support: dir.url, wedding: request.wedding))
        try reopened.append(PhotoResult(photo: PhotoID(3), delivery: .couple, status: .done, inBytes: 10, outBytes: 5))
        reopened.close()
        let loaded = try #require(Journal.load(directory: journal.directory))
        #expect(loaded.results.map(\.photo.index) == [0, 1, 2, 3])
        #expect(!loaded.finished)
    }

    // MARK: Pause, stop, errors

    @Test func pauseLatencyIsUnderOneAndAHalfSecondsAndLeavesNoPartialFiles() async throws {
        let s = Self.pngSetup(10, label: "pause")
        let engine = fakeEngine(s.dir, primitives: .slowFakes(delay: 0.25), workers: 3)
        let output = s.output()
        let request = makeRequest(photos: s.photos, roots: [s.root], output: output, deliveries: lossyPresets)
        let requested = Locked<Double?>(nil)
        let log = await Self.run(engine, request) { event in
            guard case .results = event else { return }
            let first = requested.withLock { t -> Bool in
                if t == nil { t = monotonicSeconds(); return true }
                return false
            }
            if first {
                Task.detached { await engine.pause(request.wedding) }
            }
        }
        #expect(log.terminal == .paused(.user))
        let pausedAt = try #require(log.events.last?.t)
        let latency = pausedAt - (requested.snapshot ?? pausedAt)
        #expect(latency < 1.5, "pause latency \(latency) s")
        // No .tmp anywhere, and every delivered file is journaled with its size.
        let manifest = fileManifest(output)
        #expect(!manifest.keys.contains { $0.hasSuffix(".tmp") })
        let journaled = try #require(Journal.load(support: engine.supportDirectory, wedding: request.wedding))
        let paths = Set(journaled.results.compactMap(\.outRelativePath))
        #expect(Set(manifest.keys) == paths)
        #expect(journaled.results.allSatisfy { JobRunner.isStillDelivered($0, output: output) })
        let resumed = await Self.run(fakeEngine(s.dir), request, resume: true)
        #expect(resumed.terminal == .finished)
        #expect(fileManifest(output).count == 30)
    }

    @Test func diskFullMapsToPausedDiskFull() async throws {
        let s = Self.pngSetup(6, label: "enospc")
        let writes = Counter()
        let engine = fakeEngine(s.dir) { o in o.writeFaultHook = { _ in writes.add(1) > 4 ? ENOSPC : nil } }
        let output = s.output()
        let request = makeRequest(photos: s.photos, roots: [s.root], output: output, deliveries: lossyPresets)
        let log = await Self.run(engine, request)
        guard case .paused(.diskFull(let volume, let needed)) = log.terminal else {
            Issue.record("expected paused(diskFull), got \(String(describing: log.terminal))"); return
        }
        #expect(!volume.isEmpty)
        #expect(needed > 0)
        #expect(!fileManifest(output).keys.contains { $0.hasSuffix(".tmp") })
        let resumed = await Self.run(fakeEngine(s.dir), request, resume: true)
        #expect(resumed.terminal == .finished)
        #expect(fileManifest(output).count == 18)
    }

    @Test func notWritableOutputMapsToPausedOutputNotWritable() async throws {
        let s = Self.pngSetup(3, label: "erofs")
        let engine = fakeEngine(s.dir) { o in o.writeFaultHook = { _ in EACCES } }
        let log = await Self.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: s.output(), deliveries: lossyPresets))
        guard case .paused(.outputNotWritable) = log.terminal else { Issue.record("got \(String(describing: log.terminal))"); return }
    }

    @Test func unmountedSourceMapsToPausedSourceUnavailable() async throws {
        let s = Self.pngSetup(6, label: "unmount")
        let moved = s.root.deletingLastPathComponent().appending(path: "fertig-unmounted")
        let once = Counter()
        let root = s.root
        var primitives = EnginePrimitives.fakes()
        primitives.decoder = HookedDecoder { url in
            if url.lastPathComponent == "IMG_0004.png", once.once() { try? FileManager.default.moveItem(at: root, to: moved) }
        }
        let engine = fakeEngine(s.dir, primitives: primitives, workers: 1)
        let output = s.output()
        let request = makeRequest(photos: s.photos, roots: [s.root], output: output, deliveries: lossyPresets)
        let log = await Self.run(engine, request)
        guard case .paused(.sourceUnavailable(let volume)) = log.terminal else {
            Issue.record("expected paused(sourceUnavailable), got \(String(describing: log.terminal))"); return
        }
        #expect(!volume.isEmpty)
        #expect(!log.results.contains { if case .failed = $0.status { true } else { false } })
        try FileManager.default.moveItem(at: moved, to: root)
        let resumed = await Self.run(fakeEngine(s.dir), request, resume: true)
        #expect(resumed.terminal == .finished)
        #expect(fileManifest(output).count == 18)
    }

    @Test func missingFileWithDrivePresentFailsOnlyThatPhoto() async throws {
        let s = Self.pngSetup(4, label: "missing")
        try FileManager.default.removeItem(at: s.photos[2].url)
        let log = await Self.run(fakeEngine(s.dir), makeRequest(photos: s.photos, roots: [s.root], output: s.output(),
                                                                deliveries: lossyPresets))
        #expect(log.terminal == .finished)
        let failed = log.results.filter { $0.status == .failed(.sourceMissing) }
        #expect(failed.count == 3 && failed.allSatisfy { $0.photo == PhotoID(2) })
    }

    @Test func eventCadenceResultsAtMostTenHertzProgressAtLeastOneHertz() async throws {
        let s = Self.pngSetup(30, label: "cadence")
        let engine = fakeEngine(s.dir, primitives: .slowFakes(delay: 0.004), workers: 4)
        let log = await Self.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: s.output(), deliveries: lossyPresets))
        #expect(log.terminal == .finished)
        let resultTimes = log.events.filter { if case .results = $0.event { true } else { false } }.map(\.t)
        let gaps = zip(resultTimes.dropFirst(), resultTimes).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= 0.08 }, "smallest results gap \(gaps.min() ?? 0)")
        let progressTimes = log.events.filter { if case .progress = $0.event { true } else { false } }.map(\.t)
        let start = log.events.first!.t, end = log.events.last!.t
        let checkpoints = [start] + progressTimes + [end]
        let maxGap = zip(checkpoints.dropFirst(), checkpoints).map { $0 - $1 }.max() ?? 0
        #expect(maxGap <= 1.0, "longest gap without progress \(maxGap) s")
        #expect(log.results.count == 90)
    }

    @Test func progressCoalescerUnit() {
        var c = ProgressCoalescer()
        #expect(c.tick(now: 0, hasPending: true) == .resultsAndProgress)
        #expect(c.tick(now: 0.05, hasPending: true) == .none)
        #expect(c.tick(now: 0.1, hasPending: true) == .resultsAndProgress)
        #expect(c.tick(now: 0.3, hasPending: false) == .none)
        #expect(c.tick(now: 0.6, hasPending: false) == .progress)
        var rate = PhotoRate(start: 0, parallelism: 2)
        for i in 1...9 { rate.photoFinished(at: Double(i)) }
        #expect(rate.eta(remaining: 5) == nil)
        rate.photoFinished(at: 10)
        #expect(rate.eta(remaining: 5) != nil)
    }

    // MARK: Delivery semantics

    @Test func jpegSourcesKeepOriginalAndArchiveIsVerified() async throws {
        let dir = TempDir("keep")
        let root = dir.sub("fertig")
        let urls = (0..<3).map { i -> URL in
            let u = root.appending(path: "DSC_\(i).jpg")
            Synth.jpeg(at: u, seed: UInt32(i + 1), date: "2026:07:12 14:0\(i):00")
            return u
        }
        let photos = sourcePhotos(urls, root: root)
        let couple = DeliveryPreset.builtIns[0], archive = DeliveryPreset.builtIns[3]
        let output = dir.sub("out").appending(path: "W \u{2013} Deliveries")
        let log = await Self.run(fakeEngine(dir), makeRequest(photos: photos, roots: [root], output: output,
                                                              deliveries: [couple, archive], naming: .init(renameByCaptureTime: false, pattern: "")))
        #expect(log.terminal == .finished)
        for r in log.results where r.delivery == .couple {
            // The fake encoder cannot beat a real JPEG: the original is delivered, byte for byte (keepAll).
            #expect(r.status == .keptOriginal && r.encoder == "copy")
            #expect(try Data(contentsOf: output.appending(path: r.outRelativePath!)) == Data(contentsOf: urls[r.photo.index]))
        }
        for r in log.results where r.delivery == .archive {
            #expect(r.status == .done && r.encoder == "libjxl" && r.byteExact == true)
            #expect(r.outRelativePath == "Archive/DSC_\(r.photo.index).jxl")
            let jxl = try Data(contentsOf: output.appending(path: r.outRelativePath!))
            #expect(try FakeJXLTranscoder().reconstructJPEG(jxl: jxl) == Data(contentsOf: urls[r.photo.index]))
        }

        // A transcoder that does not reconstruct byte-exactly: the original is copied instead.
        var lossy = EnginePrimitives.fakes()
        lossy.jxl = LossyJXL()
        let out2 = dir.sub("out2").appending(path: "W \u{2013} Deliveries")
        let log2 = await Self.run(fakeEngine(dir, primitives: lossy), makeRequest(photos: photos, roots: [root], output: out2,
                                                                                deliveries: [archive]))
        for r in log2.results {
            #expect(r.status == .keptOriginal && r.encoder == "copy" && r.byteExact == true)
            #expect(r.outRelativePath?.hasSuffix(".jpg") == true)
            #expect(try Data(contentsOf: out2.appending(path: r.outRelativePath!)) == Data(contentsOf: urls[r.photo.index]))
        }
    }

    @Test func cmykFailsLossyDeliveriesButIsArchived() async throws {
        let dir = TempDir("cmyk")
        let root = dir.sub("src")
        let url = root.appending(path: "cmyk.jpg")
        try FileManager.default.copyItem(at: TestFixtureFiles.cmyk, to: url)
        let photos = sourcePhotos([url], root: root)
        let log = await Self.run(fakeEngine(dir), makeRequest(photos: photos, roots: [root], output: dir.sub("o").appending(path: "D"),
                                                              deliveries: [DeliveryPreset.builtIns[0], DeliveryPreset.builtIns[3]]))
        #expect(log.results.first { $0.delivery == .couple }?.status == .failed(.cmykUnsupported))
        #expect(log.results.first { $0.delivery == .archive }?.status == .done)
        #expect(log.terminal == .finished)
    }

    @Test func outputInsideSourceFailsWithoutWriting() async throws {
        let s = Self.pngSetup(2, label: "inside")
        let inside = s.root.appending(path: "Deliveries")
        let log = await Self.run(fakeEngine(s.dir), makeRequest(photos: s.photos, roots: [s.root], output: inside, deliveries: lossyPresets))
        guard case .failed = log.terminal else { Issue.record("expected failed"); return }
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.root.path).count == 2)
    }

    @Test func existingNonEmptyOutputFolderIsNeverWrittenIntoOnAFreshRun() async throws {
        let s = Self.pngSetup(2, label: "exists")
        let output = s.output()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: output.appending(path: "notes.txt"))
        let log = await Self.run(fakeEngine(s.dir), makeRequest(photos: s.photos, roots: [s.root], output: output, deliveries: lossyPresets))
        guard case .failed = log.terminal else { Issue.record("expected failed"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["notes.txt"])
    }

    @Test func retryAndCreateMoreWriteIntoTheExistingFolders() async throws {
        let s = Self.pngSetup(3, label: "retry")
        let output = s.output()
        let engine = fakeEngine(s.dir)
        let wedding = WeddingID()
        _ = await Self.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output,
                                               deliveries: [lossyPresets[1]], wedding: wedding))
        try FileManager.default.removeItem(at: output.appending(path: "Couple/Finn-und-Lissy-0002.jpg"))
        let retry = await Self.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output,
                                                       deliveries: [lossyPresets[1]], wedding: wedding, onlyPhotos: [PhotoID(1)]))
        #expect(retry.terminal == .finished)
        #expect(retry.results.map(\.outRelativePath) == ["Couple/Finn-und-Lissy-0002.jpg"])
        let more = await Self.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: output,
                                                      deliveries: [lossyPresets[2]], wedding: wedding, append: true))
        #expect(more.terminal == .finished)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == ["Couple", "Archive"])
    }

    @Test func secondJobWhileRunningIsRejected() async throws {
        let s = Self.pngSetup(4, label: "queue")
        let engine = fakeEngine(s.dir, primitives: .slowFakes(delay: 0.05))
        let first = makeRequest(photos: s.photos, roots: [s.root], output: s.output("a"), deliveries: lossyPresets)
        let stream = engine.run(first, resume: false)
        let second = await Self.run(engine, makeRequest(photos: s.photos, roots: [s.root], output: s.output("b"), deliveries: lossyPresets))
        guard case .failed = second.terminal else { Issue.record("expected the second job to be refused"); return }
        await engine.stop(first.wedding)
        let log = await collect(stream)
        #expect(log.terminal == .stopped)
    }

    @Test func mosaicSearchRunsOnLargePhotos() async throws {
        let dir = TempDir("mosaic")
        let root = dir.sub("src")
        let url = root.appending(path: "big.png")
        Synth.write(Synth.cgImage(width: 2048, height: 1024, seed: 9), to: url, type: .png)
        let photos = sourcePhotos([url], root: root)
        let log = await Self.run(fakeEngine(dir), makeRequest(photos: photos, roots: [root], output: dir.sub("o").appending(path: "D"),
                                                              deliveries: [lossyPresets[1]]))
        let r = try #require(log.results.first)
        #expect(r.status == .done)
        #expect((r.score ?? 0) >= (r.target ?? 100))
        #expect(r.probes >= 1 && r.probes <= 5)
        #expect(r.chroma == .s420)
    }
}

// MARK: - Small helpers

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var fired = false
    @discardableResult func add(_ n: Int) -> Int { lock.withLock { value += n; return value } }
    /// True exactly once.
    func once() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
