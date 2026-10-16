// Opt-in live A/B of DirectSearch constants for the resized deliveries (Website WebP 2560 ≥ 70, Social JPEG 1440 ≥ 85)
// on the holdout. Every variant runs the real search on the real variant (sRGB conversion, resize, final metadata);
// probes are memoised per photo and delivery across variants (same parameter → same bytes and score).
//
//   HMB_DIRECT_AB='spec:;old:jstop=1.0' swift test -c release --filter DirectSearchABTests
//
// Variant syntax: name:key=value,…; keys stop (directStop, WebP), jstop (directStopJPEG), max (directMaxProbes),
// from444 (direct444From), cr / aq (directJPEGTuning), jpegli=1 (jpegli's tables, §3.5 order).
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite(.serialized) struct DirectSearchABTests {
    static var spec: String? { ProcessInfo.processInfo.environment["HMB_DIRECT_AB"] }

    static func variants(_ text: String) throws -> [(String, SearchConstants)] {
        try text.split(separator: ";").map { item in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            var c = SearchConstants.spec
            for pair in (parts.count > 1 ? parts[1] : "").split(separator: ",") {
                let kv = pair.split(separator: "=").map(String.init)
                guard kv.count == 2, let v = Double(kv[1]) else { throw PrimitiveError("bad pair \(pair)") }
                switch kv[0] {
                case "stop": c.directStop = v
                case "jstop": c.directStopJPEG = v
                case "max": c.directMaxProbes = Int(v)
                case "from444": c.direct444From = v
                case "cr": c.directJPEGTuning.chromaRatio = v
                case "aq": c.directJPEGTuning.adaptiveQuantization = v != 0
                case "jpegli": c.directJPEGTuning = .jpegli; c.direct444From = .infinity
                default: throw PrimitiveError("unknown key \(kv[0])")
                }
            }
            return (parts[0], c)
        }
    }

    struct Row: Sendable { var bytes: Int; var probes: Int; var over: Double }

    @Test(.enabled(if: spec != nil && LiveGate.holdoutReady)) func abOnHoldout() throws {
        let variants = try Self.variants(Self.spec!.isEmpty ? "spec:" : Self.spec!)
        let p = LiveGate.primitives!
        let files = LocalData.jpegs(in: LiveGate.holdout!.path)
        let presets = DeliveryPreset.builtIns.filter { $0.id == .website || $0.id == .social }
        let rows = Locked([String: [Row]]())
        let before = LiveGate.uptime()
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            gate.wait(); defer { gate.signal() }
            do {
                let info = try p.decoder.inspect(files[i])
                let srgb = p.processing.convertedToSRGB(try p.decoder.decode(info))
                for preset in presets {
                    let target = try #require(Targets.target(preset.quality, features: nil))
                    let v = p.processing.resized(srgb, longEdge: preset.size.longEdge!)
                    let meta = MetadataEditor.output(for: info, policy: preset.metadata, colour: preset.colour)
                    let markers = MetadataEditor.jpegMarkers(meta)
                    let ref = try p.metric.prepareReference(v)
                    defer { p.metric.release(ref) }
                    var cache: [String: (Int, Double)] = [:]
                    func measure(_ key: String, _ encode: () throws -> Data) throws -> (Int, Double) {
                        if let hit = cache[key] { return hit }
                        let data = try encode()
                        let value = (data.count, try p.metric.score(try p.decoder.decode(encoded: data), against: ref))
                        cache[key] = value
                        return value
                    }
                    let prepared = preset.format == .webp ? try p.webp.prepare(v) : nil
                    for (name, c) in variants {
                        var best: ProbeRecord?
                        var probes = 0
                        if let prepared {
                            let web = try DirectSearch.webp(target: target, constants: c) { q in
                                let (n, s) = try measure("q\(q)") {
                                    try p.webp.encode(prepared, quality: Float(q), icc: meta.icc, exif: meta.exif, xmp: meta.xmp)
                                }
                                return ProbeRecord(parameter: q, subsampling: nil, score: s, data: Data(count: n))
                            }
                            best = web.best; probes = web.probes.count
                        }
                        if best == nil {
                            let r = try DirectSearch.jpeg(target: target, constants: c) { d, chroma in
                                let (n, s) = try measure("d\(d)-\(chroma.rawValue)-\(c.directJPEGTuning)") {
                                    try p.jpeg.encode(v, distance: d, subsampling: chroma, tuning: c.directJPEGTuning, markers: markers)
                                }
                                return ProbeRecord(parameter: d, subsampling: chroma, score: s, data: Data(count: n))
                            }
                            if case .encoded(let b) = r.outcome { best = b }
                            probes += r.fullProbes
                        }
                        let b = try #require(best)
                        rows.withLock { $0["\(preset.id.rawValue) \(name)", default: []].append(Row(bytes: b.bytes, probes: probes, over: b.score - target)) }
                    }
                }
            } catch {
                Issue.record("\(files[i].lastPathComponent): \(error)")
            }
        }
        print("DIRECT A/B: before \(before), after \(LiveGate.uptime())")
        for (key, r) in rows.snapshot.sorted(by: { $0.key < $1.key }) {
            print(String(format: "DAB %-24@ %.4f MB  probes %.2f max %d  over mean %.3f max %.2f  n %d", key,
                         Double(r.reduce(0) { $0 + $1.bytes }) / 1e6, Double(r.reduce(0) { $0 + $1.probes }) / Double(r.count),
                         r.map(\.probes).max() ?? 0, r.map(\.over).reduce(0, +) / Double(r.count), r.map(\.over).max() ?? 0, r.count))
        }
    }
}
