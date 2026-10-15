// WP0: the domain fixtures match the numbers the spec and DATENLAGE §8 promise, and FixtureEngine replays jobs.
import CoreGraphics
import Foundation
import HMBFixtures
import HMBModel
import Testing

@Suite struct FixturesTests {
    static let enUS = Locale(identifier: "en_US")

    @Test func finnUndLissyMatchesDatenlage() throws {
        let record = Fixtures.finnUndLissy
        #expect(record.photos.count == 535)
        #expect(record.sourceBytes == 10_950_000_000)
        #expect(record.deliveries.map(\.id) == [.couple, .website, .social, .archive])
        #expect(record.photos.map(\.id) == (0..<535).map(PhotoID.init))
        #expect(record.photos.map { $0.captureDate! } == record.photos.map { $0.captureDate! }.sorted())

        let couple = try #require(record.summary(for: .couple))
        #expect(couple.outputBytes == 1_350_000_000)
        #expect(couple.minScore == 74.0 && couple.maxScore == 76.2 && couple.medianScore == 74.5)
        #expect(couple.delivered == 535 && couple.isComplete)
        #expect(HMBFormat.bytes(couple.outputBytes, locale: Self.enUS) == "1.35 GB")
        #expect(HMBFormat.savedPercent(couple.savedFraction, locale: Self.enUS) == "−88%")
        let range = try #require(couple.targetRange)
        #expect(range.lowerBound >= 74 && range.upperBound <= 87)

        let website = try #require(record.summary(for: .website))
        #expect(website.outputBytes == 159_000_000 && (website.minScore ?? 0) >= 70)
        let social = try #require(record.summary(for: .social))
        #expect(social.outputBytes == 155_000_000 && (social.minScore ?? 0) >= 85)
        let archive = try #require(record.summary(for: .archive))
        #expect(archive.outputBytes == 8_550_000_000 && archive.byteExactCount == 535)
        #expect(record.results.filter { $0.delivery == .website }.allSatisfy { max($0.outPixelWidth ?? 0, $0.outPixelHeight ?? 0) == 2560 })
        #expect(record.results.first?.outRelativePath == "Couple/Finn-und-Lissy-0001.jpg")
        #expect(record.issueCount == 0)
        for result in record.results { if let score = result.score, let target = result.target { #expect(score >= target) } }
    }

    @Test func annaUndBenIsQueued() {
        let record = Fixtures.annaUndBen
        #expect(record.photos.count == 412)
        #expect(record.phase == .queued(position: 1))
        #expect(record.results.isEmpty)
        #expect(record.deliveries.map(\.id) == DeliveryPreset.defaultOnIDs)
    }

    @Test func historyTotals() {
        let history = Fixtures.history
        #expect(history.count == 38)
        #expect(Set(history.map(\.id)).count == 38)
        #expect(history.contains { $0.id == Fixtures.finnUndLissyID })
        let saved = history.reduce(Int64(0)) { $0 + $1.savedBytesFullSize }
        #expect(saved == Fixtures.historySavedBytes)
        #expect(HMBFormat.bytes(saved, locale: Self.enUS) == "1.24 TB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = FixtureFactory.timeZone
        let months = Set(history.compactMap(\.weddingDate).map { calendar.dateComponents([.year, .month], from: $0) })
        #expect(months.count == 14)
        #expect(history.allSatisfy { $0.phase == .finished && $0.issueCount == 0 })
        #expect(zip(history, history.dropFirst()).allSatisfy { ($0.weddingDate ?? .distantPast) >= ($1.weddingDate ?? .distantPast) })
        #expect(history.allSatisfy { ($0.finishedAt ?? .distantFuture) < FixtureFactory.date(2026, 10, 15) })
    }

    @Test func fixturesAreDeterministic() {
        #expect(Fixtures.finnUndLissy.results.map(\.outBytes) == Fixtures.finnUndLissy.results.map(\.outBytes))
        let a = FixtureFactory.scores(count: 100, min: 70, max: 80, median: 72, seed: 9)
        let b = FixtureFactory.scores(count: 100, min: 70, max: 80, median: 72, seed: 9)
        #expect(a == b)
        #expect(a.min() == 70 && a.max() == 80)
        #expect(a.sorted()[49] == 72 && a.sorted()[50] == 72)
    }

    @Test func inputsAndVariants() {
        #expect(Fixtures.scanResult.photos.count == 535)
        #expect(Fixtures.scanResult.suggestedName == "Finn und Lissy")
        #expect(Fixtures.scanResult.totalBytes == 10_950_000_000)
        #expect(Set(Fixtures.estimates.keys) == Set(DeliveryPreset.builtIns.map(\.id)))
        let defaultTotal = DeliveryPreset.defaultOnIDs.compactMap { Fixtures.estimates[$0]?.bytes }.reduce(0, +)
        #expect(HMBFormat.bytes(defaultTotal, locale: Self.enUS) == "1.56 GB")

        let issues = Fixtures.withIssues(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy))
        #expect(issues.issueCount == 5)        // 2 unreadable × 2 deliveries + 1 encode failure
        #expect(issues.summary(for: .website)?.failed == 3)
        #expect(issues.summary(for: .couple)?.failed == 2)
        #expect(issues.results.contains { $0.status == .failed(.encodeFailed) && $0.delivery == .website })

        let kept = Fixtures.keptOriginal(7)
        #expect(kept.summary(for: .couple)?.keptOriginal == 7)
        #expect(kept.summary(for: .couple)?.delivered == 535)

        let (running, progress) = Fixtures.inProgress(Fixtures.finnUndLissy, done: 312)
        #expect(progress.photosDone == 312 && progress.photosTotal == 535 && progress.photosInFlight == 4)
        #expect(running.phase == .running)
        #expect(HMBFormat.statusLine(done: progress.photosDone, total: progress.photosTotal, etaSeconds: progress.etaSeconds,
                                     finishing: false, locale: Self.enUS) == "312 of 535 photos · about 2 min left")
        #expect(Fixtures.inProgress(Fixtures.finnUndLissy, done: 5).progress.etaSeconds == nil)
        #expect(Fixtures.failed(Fixtures.finnUndLissy).results.isEmpty)
    }

    @Test func thumbnailsAreDeterministicAndPhotoShaped() async throws {
        let thumbnails = FixtureThumbnails(photoFolder: nil)
        let photo = Fixtures.finnUndLissy.photos[3]
        let a = try #require(await thumbnails.thumbnail(for: photo, maxPixelSize: 320))
        #expect(max(a.cgImage.width, a.cgImage.height) == 320)
        #expect((a.cgImage.width > a.cgImage.height) == (photo.pixelWidth > photo.pixelHeight))
        let other = FixtureThumbnails(photoFolder: nil).image(for: photo, maxPixelSize: 320)
        #expect(Self.pixels(a.cgImage) == Self.pixels(other.cgImage))
        let different = thumbnails.image(for: Fixtures.finnUndLissy.photos[4], maxPixelSize: 320)
        #expect(Self.pixels(a.cgImage) != Self.pixels(different.cgImage))
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}

@Suite struct FixtureEngineTests {
    static func request(_ photos: Int = 30) -> JobRequest {
        let record = Fixtures.finnUndLissy
        return JobRequest(wedding: record.id, name: record.name, photos: Array(record.photos.prefix(photos)),
                          sourceRoots: record.sourceRoots, deliveries: Array(record.deliveries.prefix(2)),
                          outputFolder: record.outputFolder, naming: .default, processorUse: .automatic)
    }

    @Test func scanReportsProgressThenTheResult() async throws {
        var found: [Int] = []
        var result: ScanResult?
        for try await update in FixtureEngine().scan([Fixtures.finnUndLissyFolder]) {
            switch update {
            case .progress(let n): found.append(n)
            case .finished(let r): result = r
            }
        }
        #expect(found == [107, 214, 321, 428])
        #expect(result == Fixtures.scanResult)
    }

    @Test func runReplaysAJobToTheEnd() async {
        let engine = FixtureEngine()
        var phases: [JobPhase] = []
        var results: [PhotoResult] = []
        var lastProgress: JobProgress?
        for await event in engine.run(Self.request(), resume: false) {
            switch event {
            case .phase(_, let phase): phases.append(phase)
            case .results(_, let batch): results += batch
            case .progress(let progress): lastProgress = progress
            }
        }
        #expect(phases == [.running, .finished])
        #expect(results.count == 60)
        #expect(lastProgress?.photosDone == 30)
        #expect(lastProgress?.summaries.first?.delivered == 30)
        #expect(await engine.unfinishedJobs().isEmpty)
    }

    @Test func pausePointAndResume() async {
        let engine = FixtureEngine(.init(pausePoint: .init(afterPhotos: 10, reason: .sourceUnavailable(volume: "Wedding SSD"))))
        var phases: [JobPhase] = []
        var count = 0
        for await event in engine.run(Self.request(), resume: false) {
            if case .phase(_, let phase) = event { phases.append(phase) }
            if case .results(_, let batch) = event { count += batch.count }
        }
        #expect(phases == [.running, .paused(.sourceUnavailable(volume: "Wedding SSD"))])
        #expect(count == 20)
        #expect(await engine.unfinishedJobs().first?.results.count == 20)
        phases = []
        for await event in engine.run(Self.request(), resume: true) {
            if case .phase(_, let phase) = event { phases.append(phase) }
            if case .results(_, let batch) = event { count += batch.count }
        }
        #expect(phases == [.running, .finished])
        #expect(count == 60)
    }

    @Test func failuresAndFailedJobs() async {
        let engine = FixtureEngine(.init(failures: [.init(photo: PhotoID(3), delivery: .website, failure: .encodeFailed)]))
        var failed: [PhotoResult] = []
        for await event in engine.run(Self.request(), resume: false) {
            if case .results(_, let batch) = event { failed += batch.filter { if case .failed = $0.status { true } else { false } } }
        }
        #expect(failed.map(\.photo) == [PhotoID(3)])
        var phases: [JobPhase] = []
        for await event in FixtureEngine(.init(failJob: "nope")).run(Self.request(), resume: false) {
            if case .phase(_, let phase) = event { phases.append(phase) }
        }
        #expect(phases == [.failed(reason: "nope")])
    }

    @Test func stopWhileRunning() async {
        let engine = FixtureEngine(.init(secondsPerPhoto: 0.01))
        var phases: [JobPhase] = []
        for await event in engine.run(Self.request(200), resume: false) {
            if case .phase(_, let phase) = event {
                phases.append(phase)
                if phase == .running { await engine.stop(Fixtures.finnUndLissyID) }
            }
        }
        #expect(phases == [.running, .stopped])
    }

    @Test func estimatesPreflightAndCompare() async throws {
        let engine = FixtureEngine(.init(preflightNotices: [.notEnoughSpace(volume: "Macintosh HD", needed: 2, available: 1)],
                                         compareUnavailableVolume: "Wedding SSD"))
        let estimates = try await engine.estimate(photos: Fixtures.scanResult.photos, deliveries: DeliveryPreset.builtIns)
        #expect(estimates == Fixtures.estimates)
        let preflight = await engine.preflight(Self.request())
        #expect(!preflight.canStart)
        let pair = try await engine.comparePair(record: Fixtures.finnUndLissy, photo: PhotoID(0), delivery: .website, maxPixelSize: 1024)
        #expect(pair.original == nil && pair.unavailableVolume == "Wedding SSD")
        #expect(pair.comparedAtLongEdge == 2560)
        #expect(max(pair.delivered.cgImage.width, pair.delivered.cgImage.height) == 1024)
    }
}
