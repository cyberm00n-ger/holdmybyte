// Acceptance §5.2.6, 8, 10 — live primitives on local photos. Enabled only when `EnginePrimitives.live()` works
// (WP1 merged) and the §5.6 variables point at local data: HMB_HOLDOUT (19 photos), HMB_TEST_PHOTOS (6 photos).
// Outputs go to a temporary folder; the source folders are only read.
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

enum LiveGate {
    static let primitives: EnginePrimitives? = try? EnginePrimitives.live()
    static func folder(_ variable: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static var holdout: URL? { folder("HMB_HOLDOUT") }
    static var samples: URL? { folder("HMB_TEST_PHOTOS") }
    static var holdoutReady: Bool { primitives != nil && holdout != nil }
    static var samplesReady: Bool { primitives != nil && samples != nil }

    static func engine(_ dir: TempDir) -> LiveEngine {
        LiveEngine(primitives: primitives!, supportDirectory: dir.sub("support"),
                   options: EngineOptions(learnedEstimatesSuite: "hmb-live-tests-\(UUID().uuidString)"))
    }

    static func scan(_ engine: LiveEngine, _ folder: URL) async throws -> ScanResult {
        for try await update in engine.scan([folder]) { if case .finished(let r) = update { return r } }
        throw CancellationError()
    }

    static func uptime() -> String {
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        return String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }
}

@Suite(.serialized) struct LiveEngineTests {
    @Test(.enabled(if: LiveGate.holdoutReady)) func holdoutBalancedMeetsTargetsProbesAndBytes() async throws {
        let dir = TempDir("live-holdout")
        let engine = LiveGate.engine(dir)
        let scan = try await LiveGate.scan(engine, LiveGate.holdout!)
        #expect(scan.photos.count == 19)
        let couple = DeliveryPreset.builtIns[0]
        let request = makeRequest(name: "Holdout", photos: scan.photos, roots: scan.sourceRoots,
                                  output: dir.sub("out").appending(path: "Holdout \u{2013} Deliveries"), deliveries: [couple])
        let before = LiveGate.uptime()
        let start = monotonicSeconds()
        let log = await collect(engine.run(request, resume: false))
        let wall = monotonicSeconds() - start
        #expect(log.terminal == .finished)
        let results = log.results
        #expect(results.count == 19)
        for r in results {
            switch r.status {
            case .done: #expect((r.score ?? 0) >= (r.target ?? 101), "photo \(r.photo.index)")
            case .keptOriginal: break
            default: Issue.record("photo \(r.photo.index): \(r.status)")
            }
        }
        let probes = results.map(\.probes)
        let mean = Double(probes.reduce(0, +)) / Double(max(1, probes.count))
        let total = results.reduce(Int64(0)) { $0 + ($1.outBytes ?? 0) }
        print("LIVE holdout Balanced: \(String(format: "%.2f", Double(total) / 1e6)) MB, probes mean \(String(format: "%.2f", mean)) max \(probes.max() ?? 0), kept \(results.filter { $0.status == .keptOriginal }.count), wall \(String(format: "%.1f", wall)) s; before \(before), after \(LiveGate.uptime())")
        for r in results.sorted(by: { $0.photo < $1.photo }) {
            print(String(format: "  %@ T %.2f s %.2f %d probes %.3f MB %@", scan.photos[r.photo.index].relativePath,
                         r.target ?? 0, r.score ?? 0, r.probes, Double(r.outBytes ?? 0) / 1e6, r.chroma?.rawValue ?? "-"))
        }
        #expect(mean <= 2.2)
        #expect((probes.max() ?? 0) <= 5)
        #expect(total <= 50_301_670)       // G1 (D-ENG-1): the old engine held to the v2-measured floor
    }

    @Test(.enabled(if: LiveGate.samplesReady)) func determinismSixPhotosFourDeliveries() async throws {
        let dir = TempDir("live-determinism")
        let engine = LiveGate.engine(dir)
        let scan = try await LiveGate.scan(engine, LiveGate.samples!)
        let wedding = WeddingID()
        var manifests: [[String: String]] = []
        for run in ["a", "b"] {
            let output = dir.sub(run).appending(path: "S \u{2013} Deliveries")
            let log = await collect(engine.run(makeRequest(name: "S", photos: scan.photos, roots: scan.sourceRoots,
                                                           output: output, wedding: wedding), resume: false))
            #expect(log.terminal == .finished)
            manifests.append(fileManifest(output))
        }
        #expect(manifests[0].count == scan.photos.count * 4)
        #expect(manifests[0] == manifests[1])
    }

    @Test(.enabled(if: LiveGate.holdoutReady)) func estimatorWithinFifteenPercentAndFiveSeconds() async throws {
        let dir = TempDir("live-estimate")
        let engine = LiveGate.engine(dir)
        let scan = try await LiveGate.scan(engine, LiveGate.holdout!)
        let deliveries = DeliveryPreset.builtIns
        let before = LiveGate.uptime()
        let start = monotonicSeconds()
        let estimates = try await engine.estimate(photos: scan.photos, deliveries: deliveries)
        let seconds = monotonicSeconds() - start
        print("LIVE estimate: \(String(format: "%.2f", seconds)) s (\(before))")
        if loadAverage() < 3 { #expect(seconds <= 5) }
        let log = await collect(engine.run(makeRequest(name: "Holdout", photos: scan.photos, roots: scan.sourceRoots,
                                                       output: dir.sub("out").appending(path: "H \u{2013} Deliveries"),
                                                       deliveries: deliveries), resume: false))
        #expect(log.terminal == .finished)
        for preset in deliveries {
            let actual = log.results.filter { $0.delivery == preset.id }.reduce(Int64(0)) { $0 + ($1.outBytes ?? 0) }
            let estimated = try #require(estimates[preset.id]).bytes
            let ratio = Double(actual) / Double(max(1, estimated))
            print("LIVE estimate \(preset.id.rawValue): estimated \(estimated) actual \(actual) ratio \(String(format: "%.3f", ratio))")
            #expect(abs(ratio - 1) <= 0.15, "\(preset.id.rawValue): actual/estimate \(ratio)")
        }
    }
}
