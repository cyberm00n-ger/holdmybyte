// Opt-in live A/B of MosaicSearch variants on the holdout (Docs/ENGINE.md §3.4). Every variant runs the real search
// against real full-resolution probes (jpegli + ImageIO decode + Metal SSIMULACRA2) of the 19 holdout photos; probes
// and mosaic scores are memoised per photo across variants (identical distance → identical bytes and score).
//
//   HMB_SEARCH_AB='spec:;exact:aim=exact,emargin=0.1' swift test -c release -Xswiftc -enable-testing \
//       --filter SearchABTests
//
// Variant syntax: name:key=value,key=value;… with keys aim (curve|exact), m0, m1, bias, stop, maxFull, ebias, eslope,
// efirst, emargin, estop, eevals, ewidth. An empty list means the shipped constants (.spec).
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

enum SearchAB {
    static var spec: String? { ProcessInfo.processInfo.environment["HMB_SEARCH_AB"] }

    static func variants(_ text: String) throws -> [(String, SearchConstants)] {
        try text.split(separator: ";").map { item in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            var c = SearchConstants.spec
            for pair in (parts.count > 1 ? parts[1] : "").split(separator: ",") {
                let kv = pair.split(separator: "=").map(String.init)
                guard kv.count == 2 else { throw PrimitiveError("bad pair \(pair)") }
                let v = Double(kv[1]) ?? .nan
                switch kv[0] {
                case "aim": c.aim = kv[1] == "exact" ? .mosaicExact : .proxyCurve
                case "m0": c.m0 = v
                case "m1": c.m1 = v
                case "bias": c.bias = v
                case "stop": c.stop = v
                case "maxFull": c.maxFull = Int(v)
                case "ebias": c.exactBiasPrior = v
                case "eslope": c.exactBiasSlope = v
                case "efirst": c.exactFirstMargin = v
                case "emargin": c.exactMargin = v
                case "estop": c.exactStop = v
                case "eevals": c.exactSolverEvals = Int(v)
                case "ewidth": c.exactSolverWidth = v
                case "estep": c.exactMinStep = v
                case "efail": c.exactFailStep = v
                case "erescue": c.exactRescueMargin = v
                default: throw PrimitiveError("unknown key \(kv[0])")
                }
            }
            return (parts[0], c)
        }
    }
}

@Suite(.serialized) struct SearchABTests {
    struct Row: Sendable { var bytes: Int; var probes: Int; var score: Double; var target: Double; var proxies: Int }

    @Test(.enabled(if: SearchAB.spec != nil && LiveGate.holdoutReady)) func abOnHoldout() throws {
        let variants = try SearchAB.variants(SearchAB.spec!.isEmpty ? "spec:" : SearchAB.spec!)
        let p = LiveGate.primitives!
        let files = LocalData.jpegs(in: LiveGate.holdout!.path)
        let couple = DeliveryPreset.builtIns[0]
        let rows = Locked([[Row?]](repeating: [Row?](repeating: nil, count: files.count), count: variants.count))
        let before = LiveGate.uptime()
        let start = monotonicSeconds()
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            gate.wait(); defer { gate.signal() }
            do {
                let info = try p.decoder.inspect(files[i])
                let source = try p.decoder.decode(info)
                let target = Targets.balanced(textureP50: p.processing.features(source).textureP50)
                let markers = MetadataEditor.jpegMarkers(MetadataEditor.output(for: info, policy: couple.metadata, colour: couple.colour))
                let ref = try p.metric.prepareReference(source)
                defer { p.metric.release(ref) }
                let mosaic = p.processing.mosaic(source)!
                let mref = try p.metric.prepareReference(mosaic)
                defer { p.metric.release(mref) }
                var fullCache: [String: (Int, Double)] = [:]
                var proxyCache: [String: Double] = [:]
                for (v, (_, constants)) in variants.enumerated() {
                    var proxies = 0
                    let oracle = JPEGSearchOracle(
                        proxyScore: { d, chroma in
                            proxies += 1
                            let key = "\(d)-\(chroma.rawValue)"
                            if let s = proxyCache[key] { return s }
                            let data = try p.jpeg.encode(mosaic, distance: d, subsampling: chroma, markers: [])
                            let s = try p.metric.score(try p.decoder.decode(encoded: data), against: mref)
                            proxyCache[key] = s
                            return s
                        },
                        probe: { d, chroma in
                            let key = "\(d)-\(chroma.rawValue)"
                            if let (n, s) = fullCache[key] {
                                return ProbeRecord(parameter: d, subsampling: chroma, score: s, data: Data(count: n))
                            }
                            let data = try p.jpeg.encode(source, distance: d, subsampling: chroma, markers: markers)
                            let s = try p.metric.score(try p.decoder.decode(encoded: data), against: ref)
                            fullCache[key] = (data.count, s)
                            return ProbeRecord(parameter: d, subsampling: chroma, score: s, data: Data(count: data.count))
                        })
                    let result = try MosaicSearch.search(target: target, oracle: oracle, keepOriginalAllowed: true,
                                                         sourceBytes: info.fileBytes.count, constants: constants)
                    if ProcessInfo.processInfo.environment["HMB_SEARCH_AB_TRACE"] == variants[v].0 {
                        print("TRACE \(files[i].lastPathComponent.suffix(8)) T \(target): " + result.probes.map {
                            String(format: "d %.4f s %.3f %.3f MB", $0.parameter, $0.score, Double($0.bytes) / 1e6) }.joined(separator: " | "))
                    }
                    let row: Row
                    switch result.outcome {
                    case .encoded(let best):
                        row = Row(bytes: best.bytes, probes: result.fullProbes, score: best.score, target: target, proxies: proxies)
                    case .keepOriginal:
                        row = Row(bytes: info.fileBytes.count, probes: result.fullProbes, score: 100, target: target, proxies: proxies)
                    case .unreachable:
                        row = Row(bytes: 0, probes: result.fullProbes, score: 0, target: target, proxies: proxies)
                    }
                    rows.withLock { $0[v][i] = row }
                }
            } catch {
                Issue.record("\(files[i].lastPathComponent): \(error)")
            }
        }
        print(String(format: "SEARCH A/B: %.0f s; before %@, after %@", monotonicSeconds() - start, before, LiveGate.uptime()))
        for (v, (name, _)) in variants.enumerated() {
            let r = rows.snapshot[v].compactMap { $0 }
            let total = r.reduce(0) { $0 + $1.bytes }
            let over = r.map { $0.score - $0.target }
            let below = over.filter { $0 < 0 }.count
            print(String(format: "AB %-28@ %.3f MB  probes %.2f max %d  over mean %.3f max %.2f  below %d  proxies %.1f  dist %@",
                         name, Double(total) / 1e6, Double(r.reduce(0) { $0 + $1.probes }) / Double(max(1, r.count)),
                         r.map(\.probes).max() ?? 0, over.reduce(0, +) / Double(max(1, over.count)), over.max() ?? 0, below,
                         Double(r.reduce(0) { $0 + $1.proxies }) / Double(max(1, r.count)),
                         r.map { String($0.probes) }.joined()))
        }
    }
}
