import Foundation
@testable import HMBBench
import HMBModel
import Testing

/// An end-to-end bench and compress over the file-backed fake engine.
@Suite struct BenchRunTests {
    @Test func benchWritesReportCSVAndSummaryAndChecksResume() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        let source = try folder.makePhotos(10)
        let out = folder.url.appending(path: "bench", directoryHint: .isDirectory)
        let engine = BenchFakeEngine()
        let report = try await CommandRunner(engine: engine).bench(
            .init(set: source, out: out, deliveries: [.named("couple"), .named("archive")], repeatCount: 2, label: "fake",
                  resumeCheck: true, baselines: repositoryRoot.appending(path: "Benchmarks/baselines.json")))
        #expect(report.set.kind == "other" && report.set.photos == 10)
        #expect(report.runs.filter { $0.engine == "holdmybyte" }.count == 2)
        #expect(report.rows.count == 2 * 10 * 2)
        #expect(report.deterministic == true)
        let resume = try #require(report.resumeCheck)
        #expect(resume.identical && resume.filesCompared == 20 && resume.leftoverTemporaryFiles.isEmpty)
        #expect(engine.counts.stops == 1)
        #expect(report.gates.first { $0.id == "G8" }?.status == .pass)
        #expect(report.gates.filter { $0.id != "G8" }.allSatisfy { $0.status == .notApplicable })
        let couple = try #require(report.bestRun?.deliveries.first { $0.delivery == "couple" })
        #expect(couple.delivered == 10 && couple.belowTarget == 0 && couple.estimatedBytes != nil)
        for name in ["report.json", "files.csv", "summary.txt"] {
            #expect(FileManager.default.fileExists(atPath: out.appending(path: name).path), "\(name) missing")
        }
        let decoded = try BenchReport.decode(Data(contentsOf: out.appending(path: "report.json")))
        #expect(decoded.rows.count == report.rows.count)
        let csv = try String(contentsOf: out.appending(path: "files.csv"), encoding: .utf8)
        #expect(csv.split(separator: "\n").count == 1 + 40)
        // Nothing was written into the source folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).count == 10)
    }

    @Test func benchRefusesANonEmptyOut() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        let source = try folder.makePhotos(2)
        let out = folder.url.appending(path: "bench", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data().write(to: out.appending(path: "old.txt"))
        await #expect(throws: CommandRunner.Refused.self) { try await CommandRunner(engine: BenchFakeEngine()).bench(.init(set: source, out: out)) }
    }

    @Test func compressRunsTheJobAndWritesTheJSONReport() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        let source = try folder.makePhotos(3)
        let output = folder.url.appending(path: "Test Wedding – Deliveries", directoryHint: .isDirectory)
        let json = folder.url.appending(path: "report.json")
        let report = try await CommandRunner(engine: BenchFakeEngine()).compress(.init(sources: [source], output: output, json: json))
        #expect(report.runs.first?.phase == "finished")
        #expect(report.rows.count == 3 * 2)                            // default deliveries: couple + website
        #expect(FileManager.default.fileExists(atPath: output.appending(path: "Couple/IMG0001.jpg").path))
        #expect(FileManager.default.fileExists(atPath: json.path))
    }
}
