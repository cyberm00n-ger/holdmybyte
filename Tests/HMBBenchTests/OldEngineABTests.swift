import Foundation
@testable import HMBBench
import HMBModel
import Testing

/// The old-engine A/B plumbing without the real `squeeze`: a shell stand-in that copies each source into `-o` and
/// prints the old CLI's per-file line.
@Suite struct OldEngineABTests {
    static func fakeSqueeze(in folder: TemporaryFolder) throws -> URL {
        let script = folder.url.appending(path: "bin/squeeze")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        out=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -o) out="$2"; shift 2 ;;
                -p|-t) shift 2 ;;
                *) cp "$1" "$out/"; echo "$(basename "$1")  1,0 MB → 0,1 MB  (−90.0%)  JPEG  score 80.0  0.1s"; shift ;;
            esac
        done

        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func benchAlternatesWithTheOldEngineAndKeepsRepeatIndices() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        let source = try folder.makePhotos(4)
        let out = folder.url.appending(path: "bench", directoryHint: .isDirectory)
        let report = try await CommandRunner(engine: BenchFakeEngine()).bench(
            .init(set: source, out: out, deliveries: [.named("couple")], repeatCount: 2, oldEngine: try Self.fakeSqueeze(in: folder),
                  baselines: repositoryRoot.appending(path: "Benchmarks/baselines.json")))
        let old = report.runs.filter { $0.engine == "old" }
        #expect(old.map(\.index).sorted() == [1, 2])
        #expect(old.allSatisfy { $0.phase == "finished" && $0.deliveries.first?.delivered == 4 })
        #expect(report.rows.filter { $0.delivery == "old:couple" }.count == 2 * 4)
        #expect(report.bestOldRun != nil)
        for run in 1...2 {
            let files = try FileManager.default.contentsOfDirectory(atPath: out.appending(path: "old/run-\(run)/Couple").path)
            #expect(files.count == 4)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).count == 4)
    }

    @Test func outputMatchingNeverClaimsALongerName() {
        let outputs = ["IMG_10.jpg", "IMG_1.webp", "DSC_5-web.jpg", "DSC_50.jpg"].map { URL(fileURLWithPath: "/out/" + $0) }
        #expect(OldEngineRunner.output(for: "IMG_1.jpg", in: outputs)?.lastPathComponent == "IMG_1.webp")
        #expect(OldEngineRunner.output(for: "IMG_10.jpg", in: outputs)?.lastPathComponent == "IMG_10.jpg")
        #expect(OldEngineRunner.output(for: "DSC_5.jpg", in: outputs)?.lastPathComponent == "DSC_5-web.jpg")
        #expect(OldEngineRunner.output(for: "IMG_2.jpg", in: outputs) == nil)
    }
}
