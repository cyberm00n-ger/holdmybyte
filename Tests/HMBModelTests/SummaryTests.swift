import Foundation
import HMBModel
import Testing

/// Small synthetic weddings for summary math (the large fixtures are tested in HMBUITests/Fixtures).
enum Mini {
    static let date = Date(timeIntervalSince1970: 1_783_850_000)
    static func photos(_ bytes: [Int64]) -> [SourcePhoto] {
        bytes.enumerated().map { i, b in
            SourcePhoto(id: PhotoID(i), url: URL(fileURLWithPath: "/tmp/w/\(i).jpg"), relativePath: "\(i).jpg", byteCount: b,
                        pixelWidth: 6000, pixelHeight: 4000, captureDate: date.addingTimeInterval(Double(i)), camera: "X",
                        kind: .jpeg, modified: date)
        }
    }
    static func done(_ i: Int, _ d: DeliveryID, in inBytes: Int64, out: Int64, score: Double?, target: Double? = nil,
                     byteExact: Bool? = nil) -> PhotoResult {
        PhotoResult(photo: PhotoID(i), delivery: d, status: .done, score: score, target: target, inBytes: inBytes,
                    outBytes: out, byteExact: byteExact)
    }
}

@Suite struct DeliverySummaryTests {
    let couple = DeliveryPreset.builtIns[0]
    let website = DeliveryPreset.builtIns[1]
    let archive = DeliveryPreset.builtIns[3]

    @Test func countsBytesAndScores() {
        let photos = Mini.photos([100, 200, 300, 400, 500])
        let results = [
            Mini.done(0, .couple, in: 100, out: 10, score: 74.5, target: 74.0),
            Mini.done(1, .couple, in: 200, out: 30, score: 76.0, target: 75.5),
            PhotoResult(photo: PhotoID(2), delivery: .couple, status: .keptOriginal, score: nil, inBytes: 300, outBytes: 300),
            PhotoResult(photo: PhotoID(3), delivery: .couple, status: .failed(.encodeFailed), inBytes: 400),
            PhotoResult(photo: PhotoID(4), delivery: .couple, status: .working, inBytes: 500),
            Mini.done(0, .website, in: 100, out: 1, score: 99),   // another delivery: ignored
        ]
        let s = DeliverySummary.make(preset: couple, photos: photos, results: results)
        #expect(s.delivery == .couple)
        #expect(s.total == 5)
        #expect(s.processed == 4)
        #expect(s.delivered == 3)
        #expect(s.keptOriginal == 1)
        #expect(s.failed == 1)
        #expect(s.sourceBytes == 600)
        #expect(s.outputBytes == 340)
        #expect(s.minScore == 74.5)
        #expect(s.maxScore == 76.0)
        #expect(s.medianScore == 75.25)     // even count: mean of the middle two; kept original has no score
        #expect(s.floor == nil)
        #expect(s.targetRange == 74.0...75.5)
        #expect(s.byteExactCount == 0)
        #expect(!s.isComplete)
        #expect(abs(s.savedFraction - (1 - 340.0 / 600.0)) < 1e-12)
    }

    @Test func scoresOnlyOverDone() {
        let photos = Mini.photos([10, 10, 10])
        let results = [
            Mini.done(0, .website, in: 10, out: 1, score: 71),
            Mini.done(1, .website, in: 10, out: 1, score: 75),
            Mini.done(2, .website, in: 10, out: 1, score: 73),
        ]
        let s = DeliverySummary.make(preset: website, photos: photos, results: results)
        #expect(s.medianScore == 73)
        #expect(s.floor == 70)
        #expect(s.targetRange == nil)       // fixed floor, not Balanced
        #expect(s.isComplete)
    }

    @Test func archiveCountsByteExact() {
        let photos = Mini.photos([100, 100])
        let results = [Mini.done(0, .archive, in: 100, out: 78, score: nil, byteExact: true),
                       Mini.done(1, .archive, in: 100, out: 79, score: nil, byteExact: true)]
        let s = DeliverySummary.make(preset: archive, photos: photos, results: results)
        #expect(s.byteExactCount == 2)
        #expect(s.minScore == nil && s.medianScore == nil && s.maxScore == nil)
        #expect(s.floor == nil)
    }

    @Test func retryResultReplacesTheFailure() {
        let photos = Mini.photos([100])
        let results = [PhotoResult(photo: PhotoID(0), delivery: .couple, status: .failed(.writeFailed), inBytes: 100),
                       Mini.done(0, .couple, in: 100, out: 12, score: 75, target: 74)]
        let s = DeliverySummary.make(preset: couple, photos: photos, results: results)
        #expect(s.failed == 0 && s.delivered == 1 && s.isComplete)
    }

    @Test func emptyAndOutOfScope() {
        let s = DeliverySummary.make(preset: couple, photos: [], results: [Mini.done(0, .couple, in: 1, out: 1, score: 80)])
        #expect(s.total == 0 && s.processed == 0 && s.savedFraction == 0 && s.medianScore == nil)
        #expect(s.isComplete)
    }

    @Test func recordSummariesAndLifetimeSaving() {
        let photos = Mini.photos([1000, 1000])
        let results = [
            Mini.done(0, .couple, in: 1000, out: 120, score: 75), Mini.done(1, .couple, in: 1000, out: 130, score: 76),
            Mini.done(0, .website, in: 1000, out: 15, score: 72), Mini.done(1, .website, in: 1000, out: 15, score: 73),
            Mini.done(0, .archive, in: 1000, out: 780, score: nil, byteExact: true),
            PhotoResult(photo: PhotoID(1), delivery: .archive, status: .failed(.encodeFailed), inBytes: 1000),
        ]
        let record = WeddingRecord(
            id: WeddingID(), name: "Mini", createdAt: Mini.date, weddingDate: Mini.date, camera: "X", sourceRoots: [],
            sourceBookmarks: [], photos: photos, deliveries: [couple, website, archive], deliveryCompletedAt: [:],
            outputFolder: URL(fileURLWithPath: "/tmp/out"), outputBookmark: nil, naming: .default, phase: .finished,
            results: results, startedAt: nil, finishedAt: nil, activeSeconds: 1, viewed: false)
        #expect(record.sourceBytes == 2000)
        #expect(record.coverPhoto?.id == PhotoID(0))
        #expect(record.issueCount == 1)
        #expect(record.summary(for: .couple)?.outputBytes == 250)
        #expect(record.summary(for: .social) == nil)
        // couple: 2000 − 250; archive (delivered only): 1000 − 780; website excluded (resized)
        #expect(record.savedBytesFullSize == 1750 + 220)
    }

    @Test func progressFractionAndPreflight() {
        let progress = JobProgress(wedding: WeddingID(), photosDone: 3, photosTotal: 12, photosInFlight: 2,
                                   secondsPerPhoto: 0.5, etaSeconds: nil, summaries: [])
        #expect(progress.fraction == 0.25)
        #expect(JobProgress(wedding: WeddingID(), photosDone: 0, photosTotal: 0, photosInFlight: 0, secondsPerPhoto: nil,
                            etaSeconds: nil, summaries: []).fraction == 0)
        let folder = URL(fileURLWithPath: "/tmp/out")
        #expect(Preflight(outputFolder: folder, estimatedBytes: nil, notices: [.skippedRaw(count: 3), .cmyk(count: 1)]).canStart)
        #expect(!Preflight(outputFolder: folder, estimatedBytes: nil, notices: [.outputInsideSource]).canStart)
        #expect(ScanNotice.notEnoughSpace(volume: "SSD", needed: 2, available: 1).severity == .block)
        #expect(ScanNotice.alreadyCompressed(count: 1, of: 2).severity == .warning)
        #expect(ScanNotice.outputFolderExists(existing: "a", used: "a 2").severity == .info)
    }
}
