import Foundation
@testable import HMBBench
import HMBModel
import Testing

/// The A/B plumbing against the real old `squeeze` binary on one holdout photo (gated by HMB_OLD_ENGINE + HMB_HOLDOUT;
/// about 2 s). Outputs go to a temporary folder.
@Suite struct OldEngineLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static var available: Bool {
        guard let engine = environment["HMB_OLD_ENGINE"], let holdout = environment["HMB_HOLDOUT"] else { return false }
        return FileManager.default.isExecutableFile(atPath: engine) && FileManager.default.fileExists(atPath: holdout)
    }

    @Test(.enabled(if: available)) func oldEngineRunMatchesTheBaseline() throws {
        let baselines = try Baselines.load(from: repositoryRoot.appending(path: "Benchmarks/baselines.json"))
        let file = try #require(baselines.holdout.files.first)
        let url = URL(fileURLWithPath: Self.environment["HMB_HOLDOUT"]!).appending(path: file.name)
        let photo = SourcePhoto(id: PhotoID(0), url: url, relativePath: file.name, byteCount: file.sourceBytes, pixelWidth: 0,
                                pixelHeight: 0, captureDate: nil, camera: nil, kind: .jpeg, modified: Date())
        let folder = try TemporaryFolder("hmb-old-engine")
        defer { folder.cleanup() }
        let outcome = try OldEngineRunner(executable: URL(fileURLWithPath: Self.environment["HMB_OLD_ENGINE"]!))
            .run(photos: [photo], preset: DeliveryPreset.builtIns[0], output: folder.url.appending(path: "old"), run: 1)
        #expect(outcome.exitStatus == 0)
        let row = try #require(outcome.rows.first)
        #expect(row.outputBytes == file.oldBytes)            // the old engine is deterministic
        #expect(row.score == (file.oldOwnScore * 10).rounded() / 10)
        #expect(outcome.wallSeconds > 0 && outcome.cpuSeconds > 0)
    }
}
