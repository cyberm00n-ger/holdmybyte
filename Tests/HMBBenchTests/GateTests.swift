import Foundation
@testable import HMBBench
import HMBModel
import Testing

/// Gate evaluation against a synthetic baseline (§5.5 acceptance 3).
@Suite struct GateTests {
    static var baselines: Baselines {
        let data = """
        {"schema": 1,
         "wedding": {"name": "W", "photos": 4, "sourceBytes": 4000,
           "jpegmini": {"bytes": 2000},
           "oldEngine": {"couple": {"bytes": 500, "wallSeconds": 100}, "highFull": {"bytes": 900}, "website": {"bytes": 50},
                         "social": {"bytes": 50}, "archive": {"bytes": 3000}, "allFourSeparateRunsWallSeconds": 400}},
         "holdout": {"photos": 2, "sourceBytes": 2000, "oldEngine": {"bytes": 300, "wallSeconds": 20},
           "files": [{"name": "a.jpg", "sourceBytes": 1000, "oldBytes": 150, "oldReferenceScore": 73.5, "oldOwnScore": 74.1},
                     {"name": "b.jpg", "sourceBytes": 1000, "oldBytes": 150, "oldReferenceScore": 73.6, "oldOwnScore": 74.2}]},
         "gates": {"quietLoadAverage": 3.0,
           "G1": {"set": "holdout", "delivery": "couple", "maxBytes": 300, "maxMeanProbes": 2.2},
           "G2": {"set": "holdout", "delivery": "couple", "maxWallRatioToOldEngine": 0.6},
           "G3": {"set": "wedding", "delivery": "couple", "maxBytes": 600, "maxWallSeconds": 60},
           "G4": {"set": "wedding", "delivery": "high-full", "minScore": 85.0, "maxBytes": 1000},
           "G5": {"set": "wedding", "website": {"minScore": 70, "maxBytes": 100, "maxWallSecondsAlone": 30}, "social": {"minScore": 85, "maxBytes": 100}},
           "G6": {"set": "wedding", "delivery": "archive", "maxBytes": 3200, "maxWallSecondsAlone": 60},
           "G7": {"set": "wedding", "deliveries": ["couple", "website", "social", "archive"], "maxWallSeconds": 120,
                  "maxEstimateError": 0.15, "maxPeakRSSBytes": 8000000000},
           "G8": {"set": "wedding", "delivery": "couple", "stopFraction": 0.4}}}
        """
        return try! JSONDecoder().decode(Baselines.self, from: Data(data.utf8))
    }

    static func rows(_ delivery: String, names: [String], output: Int64, score: Double?, target: Double?, byteExact: Bool? = nil) -> [BenchFileRow] {
        names.map { BenchFileRow(run: 1, delivery: delivery, name: $0, sourceBytes: 1000, outputBytes: output, score: score, target: target,
                                 probes: score == nil ? 0 : 2, seconds: 1, encoder: nil, chroma: nil, status: "done", byteExact: byteExact) }
    }

    static func gate(_ id: String, _ report: BenchReport) -> GateResult {
        GateEvaluator.evaluate(report, baselines: baselines).first { $0.id == id }!
    }

    @Test func holdoutPassesG1AndNeedsTheOldEngineForG2() {
        let report = ReportTests.sampleReport(rows: Self.rows("couple", names: ["a.jpg", "b.jpg"], output: 140, score: 75, target: 74.5))
        #expect(Self.gate("G1", report).status == .pass)
        #expect(Self.gate("G2", report).status == .notEvaluated)
        #expect(Self.gate("G3", report).status == .notApplicable)
    }

    @Test func g1FailsOnBytesOrABelowTargetPhoto() {
        let heavy = ReportTests.sampleReport(rows: Self.rows("couple", names: ["a.jpg", "b.jpg"], output: 160, score: 75, target: 74.5))
        #expect(Self.gate("G1", heavy).status == .fail)
        var rows = Self.rows("couple", names: ["a.jpg", "b.jpg"], output: 100, score: 75, target: 74.5)
        rows[1].score = 74.4
        #expect(Self.gate("G1", ReportTests.sampleReport(rows: rows)).status == .fail)
    }

    @Test func g2ComparesWithTheOldEngineRun() {
        var report = ReportTests.sampleReport(rows: Self.rows("couple", names: ["a.jpg", "b.jpg"], output: 140, score: 75, target: 74.5), wall: 10)
        var old = report.runs[0]
        old.engine = "old"
        old.wallSeconds = 20
        report.runs.append(old)
        #expect(Self.gate("G2", report).status == .pass)             // 0.5× ≤ 0.6×
        report.runs[1].wallSeconds = 15
        #expect(Self.gate("G2", report).status == .fail)             // 0.67×
    }

    @Test func timingGatesAreNotReportedOnALoadedMachine() {
        var report = ReportTests.sampleReport(rows: Self.rows("couple", names: ["a.jpg", "b.jpg"], output: 140, score: 75, target: 74.5), load: 4.4)
        var old = report.runs[0]
        old.engine = "old"
        old.wallSeconds = 100
        report.runs.append(old)
        let g2 = Self.gate("G2", report)
        #expect(g2.status == .notEvaluated && g2.detail.contains("load"))
        // Bytes and scores are still reported.
        #expect(Self.gate("G1", report).status == .pass)
    }

    @Test func weddingGates() {
        let names = ["1", "2", "3", "4"]
        let couple = ReportTests.sampleReport(kind: .wedding, rows: Self.rows("couple", names: names, output: 140, score: 75, target: 74), wall: 50)
        #expect(Self.gate("G3", couple).status == .pass)
        #expect(Self.gate("G1", couple).status == .notApplicable)
        let slow = ReportTests.sampleReport(kind: .wedding, rows: Self.rows("couple", names: names, output: 140, score: 75, target: 74), wall: 70)
        #expect(Self.gate("G3", slow).status == .fail)
        let loaded = ReportTests.sampleReport(kind: .wedding, rows: Self.rows("couple", names: names, output: 140, score: 75, target: 74), wall: 70, load: 9)
        #expect(Self.gate("G3", loaded).status == .notEvaluated)
        #expect(Self.gate("G8", couple).status == .notEvaluated)

        let high = ReportTests.sampleReport(kind: .wedding, deliveries: [DeliveryCatalog.highFull],
                                            rows: Self.rows("high-full", names: names, output: 200, score: 84.9, target: 85))
        #expect(Self.gate("G4", high).status == .fail)

        let archive = ReportTests.sampleReport(kind: .wedding, deliveries: [DeliveryPreset.builtIns[3]],
                                               rows: Self.rows("archive", names: names, output: 780, score: nil, target: nil, byteExact: true), wall: 30)
        #expect(Self.gate("G6", archive).status == .pass)
        var notExact = Self.rows("archive", names: names, output: 780, score: nil, target: nil, byteExact: true)
        notExact[2].byteExact = false
        #expect(Self.gate("G6", ReportTests.sampleReport(kind: .wedding, deliveries: [DeliveryPreset.builtIns[3]], rows: notExact, wall: 30)).status == .fail)

        let website = ReportTests.sampleReport(kind: .wedding, deliveries: [DeliveryPreset.builtIns[1]],
                                               rows: Self.rows("website", names: names, output: 20, score: 71, target: 70), wall: 20)
        #expect(Self.gate("G5", website).status == .pass)
    }

    @Test func g7NeedsEstimatesWithinFifteenPercent() {
        let names = ["1", "2", "3", "4"]
        let ids = ["couple", "website", "social", "archive"]
        let rows = ids.flatMap { Self.rows($0, names: names, output: 100, score: $0 == "archive" ? nil : 90, target: $0 == "archive" ? nil : 70,
                                           byteExact: $0 == "archive" ? true : nil) }
        var report = ReportTests.sampleReport(kind: .wedding, deliveries: DeliveryPreset.builtIns, rows: rows, wall: 100)
        for i in report.runs[0].deliveries.indices {
            report.runs[0].deliveries[i].estimatedBytes = 420
            report.runs[0].deliveries[i].estimateError = 400.0 / 420 - 1
        }
        #expect(Self.gate("G7", report).status == .pass)
        report.runs[0].deliveries[1].estimateError = 0.2
        #expect(Self.gate("G7", report).status == .fail)
    }

    @Test func g8UsesTheResumeCheck() {
        var report = ReportTests.sampleReport(kind: .wedding, rows: Self.rows("couple", names: ["1", "2", "3", "4"], output: 140, score: 75, target: 74))
        report.resumeCheck = ResumeCheck(stoppedAfterPhotos: 2, filesCompared: 4, identical: true, mismatches: [], leftoverTemporaryFiles: [])
        #expect(Self.gate("G8", report).status == .pass)
        report.resumeCheck?.leftoverTemporaryFiles = ["/x/.holdmybyte-partial/a.tmp"]
        #expect(Self.gate("G8", report).status == .fail)
    }

    @Test func setKindDetection() {
        func photo(_ name: String, _ bytes: Int64) -> SourcePhoto {
            SourcePhoto(id: PhotoID(0), url: URL(fileURLWithPath: "/s/" + name), relativePath: name, byteCount: bytes, pixelWidth: 1,
                        pixelHeight: 1, captureDate: nil, camera: nil, kind: .jpeg, modified: Date())
        }
        #expect(SetKind.detect(photos: [photo("a.jpg", 1), photo("b.jpg", 1)], baselines: Self.baselines) == .holdout)
        #expect(SetKind.detect(photos: (1...4).map { photo("\($0).jpg", 1000) }, baselines: Self.baselines) == .wedding)
        #expect(SetKind.detect(photos: [photo("a.jpg", 1)], baselines: Self.baselines) == .other)
        #expect(SetKind.detect(photos: [photo("a.jpg", 1)], baselines: nil) == .other)
    }
}
