import Foundation
import Synchronization
@testable import HMBBench
import HMBModel
import Testing

@Suite struct CommandLineParsingTests {
    @Test func compressParsesEveryOption() throws {
        let command = try HMBCommand.parse(["compress", "/a", "/b", "-o", "/out", "--delivery", "couple", "--delivery-json", "/p.json",
                                            "--workers", "4", "--json", "/r.json"])
        guard case .compress(let options) = command else { Issue.record("not compress"); return }
        #expect(options.sources.map(\.path) == ["/a", "/b"])
        #expect(options.output.path == "/out")
        #expect(options.deliveries == [.named("couple"), .json(URL(fileURLWithPath: "/p.json"))])
        #expect(options.workers == 4)
        #expect(options.json?.path == "/r.json")
    }

    @Test func benchParsesEveryOption() throws {
        let command = try HMBCommand.parse(["bench", "--set", "/set", "--out", "/out", "--delivery", "archive", "--repeat", "2",
                                            "--old-engine", "/squeeze", "--label", "A/B", "--resume-check", "--set-kind", "holdout"])
        guard case .bench(let options) = command else { Issue.record("not bench"); return }
        #expect(options.set.path == "/set" && options.out.path == "/out")
        #expect(options.repeatCount == 2 && options.resumeCheck && options.setKind == .holdout && options.label == "A/B")
        #expect(options.oldEngine?.path == "/squeeze")
    }

    @Test func usageErrors() {
        #expect(throws: HMBCommand.UsageError.self) { try HMBCommand.parse(["compress", "/a"]) }            // no -o
        #expect(throws: HMBCommand.UsageError.self) { try HMBCommand.parse(["compress", "-o", "/x"]) }      // no source
        #expect(throws: HMBCommand.UsageError.self) { try HMBCommand.parse(["score", "/a"]) }
        #expect(throws: HMBCommand.UsageError.self) { try HMBCommand.parse(["bench", "--set", "/a"]) }      // no --out
        #expect(throws: HMBCommand.UsageError.self) { try HMBCommand.parse(["bench", "--set", "/a", "--out", "/b", "--repeat", "0"]) }
        #expect(throws: HMBCommand.UsageError.self) { try HMBCommand.parse(["compress", "/a", "-o", "/b", "--frobnicate"]) }
        #expect(throws: HMBCommand.UsageError.self) { try HMBCommand.parse(["estimate", "/a", "-o", "/b"]) }
        #expect((try? HMBCommand.parse([])) == .help)
        #expect((try? HMBCommand.parse(["--version"])) == .version)
    }

    @Test func deliveryNamesMapToPresets() throws {
        #expect(try HMBCommand.presets([]).map(\.id) == DeliveryPreset.defaultOnIDs)
        let all = try HMBCommand.presets(DeliveryCatalog.names.map { .named($0) })
        #expect(all.map(\.id.rawValue) == DeliveryCatalog.names)
        #expect(all.allSatisfy { $0.validationError == nil })
        #expect(DeliveryCatalog.highFull.quality.floor == 85 && DeliveryCatalog.highFull.size == .full && DeliveryCatalog.highFull.format == .jpeg)
        #expect(throws: DeliveryCatalog.UnknownDelivery.self) { try DeliveryCatalog.preset(named: "avif") }
        #expect(throws: HMBCommand.UsageError.self) { try HMBCommand.presets([.named("couple"), .named("couple")]) }
    }

    @Test func deliveryJSONIsValidated() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        var preset = DeliveryCatalog.highFull
        let good = folder.url.appending(path: "good.json")
        try JSONEncoder().encode(preset).write(to: good)
        #expect(try DeliveryCatalog.preset(jsonAt: good) == preset)
        preset.quality = .balanced
        preset.size = .longEdge(2000)
        let bad = folder.url.appending(path: "bad.json")
        try JSONEncoder().encode(preset).write(to: bad)
        #expect(throws: DeliveryCatalog.InvalidPreset.self) { try DeliveryCatalog.preset(jsonAt: bad) }
    }

    @Test func oldEngineEquivalents() {
        #expect(DeliveryCatalog.oldEngineArguments(for: DeliveryPreset.builtIns[0]) == ["-p", "classic"])
        #expect(DeliveryCatalog.oldEngineArguments(for: DeliveryCatalog.highFull) == ["-t", "85"])
        var custom = DeliveryCatalog.highFull
        custom.id = .newCustom()
        #expect(DeliveryCatalog.oldEngineArguments(for: custom) == nil)
    }

    @Test func balancedTargetMatchesTheSpecFormula() {
        #expect(BalancedTarget.target(textureP50: 0) == 74)
        #expect(BalancedTarget.target(textureP50: 4.49) == 74)
        #expect(abs(BalancedTarget.target(textureP50: 4.5) - 85.21) < 1e-9)
        #expect(abs(BalancedTarget.target(textureP50: 10) - 81.8) < 1e-9)
        #expect(BalancedTarget.target(textureP50: 30) == 75)
        #expect(BalancedTarget.target(textureP50: 1.0) == 74)
    }
}

@Suite struct OutputSafetyTests {
    @Test func refusesOutputInsideOrAtASource() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        let source = try folder.makePhotos(2)
        let file = source.appending(path: "IMG0001.jpg")
        #expect(throws: PathSafety.Violation.self) { try PathSafety.check(output: source, sources: [source]) }
        #expect(throws: PathSafety.Violation.self) { try PathSafety.check(output: source.appending(path: "Deliveries/new"), sources: [source]) }
        #expect(throws: PathSafety.Violation.self) { try PathSafety.check(output: file, sources: [file]) }
        // A loose file's folder counts as a source root.
        #expect(throws: PathSafety.Violation.self) { try PathSafety.check(output: source.appending(path: "out"), sources: [file]) }
        // Case variant (APFS is case-insensitive).
        let variant = URL(fileURLWithPath: source.path.replacingOccurrences(of: "/source", with: "/SOURCE")).appending(path: "out")
        #expect(throws: PathSafety.Violation.self) { try PathSafety.check(output: variant, sources: [source]) }
        // A symlink pointing into the source.
        let link = folder.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: PathSafety.Violation.self) { try PathSafety.check(output: link.appending(path: "out"), sources: [source]) }
        // Siblings are fine.
        try PathSafety.check(output: folder.url.appending(path: "Deliveries"), sources: [source])
        try PathSafety.check(output: folder.url.appending(path: "source-deliveries"), sources: [source])
    }

    @Test func compressRefusesBeforeCreatingTheEngine() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        let source = try folder.makePhotos(3)
        let created = Mutex(0)
        let runner = CommandRunner(makeEngine: { created.withLock { $0 += 1 }; return BenchFakeEngine() })
        await #expect(throws: PathSafety.Violation.self) {
            try await runner.compress(.init(sources: [source], output: source.appending(path: "out")))
        }
        await #expect(throws: PathSafety.Violation.self) {
            try await runner.compress(.init(sources: [source], output: folder.url.appending(path: "ok"), json: source.appending(path: "r.json")))
        }
        #expect(created.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: source.appending(path: "out").path))
    }

    @Test func benchRefusesOutInsideTheSet() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        let source = try folder.makePhotos(2)
        let engine = BenchFakeEngine()
        await #expect(throws: PathSafety.Violation.self) {
            try await CommandRunner(engine: engine).bench(.init(set: source, out: source.appending(path: "bench")))
        }
        #expect(engine.counts.runs == 0 && engine.counts.scans == 0)
    }

    @Test func oldEngineOutputsStayOutOfItsRepository() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanup() }
        let repo = folder.url.appending(path: "jpegos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo.appending(path: ".build/release"), withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.0".utf8).write(to: repo.appending(path: "Package.swift"))
        let runner = OldEngineRunner(executable: repo.appending(path: ".build/release/squeeze"))
        #expect(runner.repositoryRoot?.standardizedFileURL.path == repo.standardizedFileURL.path)
        let photos = [SourcePhoto(id: PhotoID(0), url: folder.url.appending(path: "a.jpg"), relativePath: "a.jpg", byteCount: 1,
                                  pixelWidth: 1, pixelHeight: 1, captureDate: nil, camera: nil, kind: .jpeg, modified: Date())]
        #expect(throws: PathSafety.Violation.self) {
            try runner.run(photos: photos, preset: DeliveryPreset.builtIns[0], output: repo.appending(path: "out"), run: 1)
        }
    }
}
