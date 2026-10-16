// Opt-in measurement (not a gate): for each holdout photo and each jpegli knob setting, the largest luma distance whose
// full-resolution output (Couple's Package markers, ImageIO decode, Metal SSIMULACRA2) still reaches the photo's
// Balanced target, found by bracketing + bisection to `width` in ln d; the same on the grid mosaic at T + `mgoal`.
// Writes one JSON line per (photo, knob) to HMB_KNOBS_OUT (Docs/variants/search.md).
//
//   HMB_KNOBS='420;420c1.5;444c2' HMB_KNOBS_OUT=/path/knobs.jsonl swift test -c release -Xswiftc -enable-testing \
//       --filter KnobSurveyTests
//
// Knob syntax: <sampling 420|422|444>[c<chroma ratio>][aq0][t<luma tilt>[/<chroma tilt>]][dc<dc ratio>], e.g. 444c2 = 4:4:4 with
// chroma distance 2 × luma, 420t0.4 = 4:2:0 with the luma table's high frequencies × up to e^0.4.
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

enum KnobSurvey {
    static var spec: String? { ProcessInfo.processInfo.environment["HMB_KNOBS"] }
    static var out: String? { ProcessInfo.processInfo.environment["HMB_KNOBS_OUT"] }

    struct Knob: Sendable {
        var name: String
        var sampling: JPEGKnobs.Sampling
        var ratio: Double
        var aq: Bool
        var lumaTilt = 0.0, chromaTilt = 0.0, dcRatio = 1.0
        func knobs(_ d: Double) -> JPEGKnobs {
            var k = JPEGKnobs(distance: d, chromaDistance: ratio == 1 ? nil : min(25, d * ratio), sampling: sampling,
                              adaptiveQuantization: aq)
            k.lumaTilt = lumaTilt
            k.chromaTilt = chromaTilt
            k.dcRatio = dcRatio
            return k
        }
    }

    static func parse(_ text: String) -> [Knob] {
        text.split(separator: ";").map { item in
            var s = String(item)
            var aq = true
            var lt = 0.0, ct = 0.0, dc = 1.0
            if let t = s.range(of: "dc") { dc = Double(s[t.upperBound...]) ?? 1; s = String(s[..<t.lowerBound]) }
            if let t = s.range(of: "t") {           // …t<luma>[/<chroma>]
                let parts = s[t.upperBound...].split(separator: "/").map { Double($0) ?? 0 }
                lt = parts.first ?? 0; ct = parts.count > 1 ? parts[1] : 0
                s = String(s[..<t.lowerBound])
            }
            if s.hasSuffix("aq0") { aq = false; s.removeLast(3) }
            var ratio = 1.0
            if let c = s.firstIndex(of: "c") { ratio = Double(s[s.index(after: c)...]) ?? 1; s = String(s[..<c]) }
            let sampling: JPEGKnobs.Sampling = s == "444" ? .s444 : s == "422" ? .s422 : .s420
            return Knob(name: String(item), sampling: sampling, ratio: ratio, aq: aq, lumaTilt: lt, chromaTilt: ct, dcRatio: dc)
        }
    }

    struct Point: Codable, Sendable { var d: Double; var bytes: Int; var score: Double }

    /// Largest passing ln d (bracket with ±step, then bisection to `width`); returns every evaluated point.
    static func frontier(start: Double, goal: Double, width: Double, eval: (Double) throws -> Point) rethrows -> [Point] {
        let q = 1e-4
        func quant(_ x: Double) -> Double { (x / q).rounded() * q }
        var points: [Point] = []
        func at(_ x: Double) throws -> Point {
            let p = try eval(exp(quant(x)))
            points.append(p)
            return p
        }
        var x = quant(start)
        var lo: Double?, hi: Double?
        var step = 0.12
        for _ in 0..<8 {
            if try at(x).score >= goal { lo = x; if hi != nil { break }; x += step } else { hi = x; if lo != nil { break }; x -= step }
            step *= 1.5
            if x < log(0.3) || x > log(25) { break }
        }
        guard var a = lo, var b = hi else { return points }
        while b - a > width {
            let m = quant((a + b) / 2)
            if m <= a || m >= b { break }
            if try at(m).score >= goal { a = m } else { b = m }
        }
        return points
    }
}

@Suite(.serialized) struct KnobSurveyTests {
    @Test(.enabled(if: KnobSurvey.spec != nil && KnobSurvey.out != nil && LiveGate.holdoutReady)) func surveyHoldout() throws {
        let knobs = KnobSurvey.parse(KnobSurvey.spec!)
        let p = LiveGate.primitives!
        let jpegli = JpegliEncoder()
        let files = LocalData.jpegs(in: LiveGate.holdout!.path)
        let couple = DeliveryPreset.builtIns[0]
        let width = Double(ProcessInfo.processInfo.environment["HMB_KNOBS_WIDTH"] ?? "") ?? 0.01
        let mgoal = Double(ProcessInfo.processInfo.environment["HMB_KNOBS_MGOAL"] ?? "") ?? 1.1
        let lines = Locked([String]())
        let before = LiveGate.uptime()
        let start = monotonicSeconds()
        let gate = DispatchSemaphore(value: Int(ProcessInfo.processInfo.environment["HMB_KNOBS_PAR"] ?? "") ?? 4)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            gate.wait(); defer { gate.signal() }
            do {
                let info = try p.decoder.inspect(files[i])
                let decoded = try p.decoder.decode(info)
                let features = p.processing.features(decoded)
                // HMB_KNOBS_EDGE: the Social-style variant (sRGB, resized); HMB_KNOBS_TARGET: a fixed floor.
                let env = ProcessInfo.processInfo.environment
                let edge = Int(env["HMB_KNOBS_EDGE"] ?? "")
                let source = edge.map { p.processing.resized(p.processing.convertedToSRGB(decoded), longEdge: $0) } ?? decoded
                let target = Double(env["HMB_KNOBS_TARGET"] ?? "") ?? Targets.balanced(textureP50: features.textureP50)
                let markers = MetadataEditor.jpegMarkers(MetadataEditor.output(for: info, policy: couple.metadata, colour: couple.colour))
                let ref = try p.metric.prepareReference(source)
                defer { p.metric.release(ref) }
                let mosaic = p.processing.mosaic(source)
                let mref = try mosaic.map { try p.metric.prepareReference($0) }
                defer { if let mref { p.metric.release(mref) } }
                var seed = log(Targets.jpegPrior(target)) - 0.1
                for knob in knobs {
                    let mosaicPoints = try mosaic.map { mosaic in
                        try KnobSurvey.frontier(start: seed + 0.1, goal: target + mgoal, width: width) { d in
                            let data = try jpegli.encode(mosaic, knobs: knob.knobs(d), markers: [])
                            return .init(d: d, bytes: data.count, score: try p.metric.score(try p.decoder.decode(encoded: data), against: mref!))
                        }
                    } ?? []
                    let mBest = mosaicPoints.filter { $0.score >= target + mgoal }.max { $0.d < $1.d }
                    let fullStart = mBest.map { log($0.d) } ?? seed
                    let t0 = monotonicSeconds()
                    let fullPoints = try KnobSurvey.frontier(start: fullStart, goal: target, width: width) { d in
                        let data = try jpegli.encode(source, knobs: knob.knobs(d), markers: markers)
                        return .init(d: d, bytes: data.count, score: try p.metric.score(try p.decoder.decode(encoded: data), against: ref))
                    }
                    let elapsed = monotonicSeconds() - t0
                    if let best = fullPoints.filter({ $0.score >= target }).min(by: { $0.bytes < $1.bytes }) { seed = log(best.d) }
                    struct Line: Codable {
                        var photo: String; var knob: String; var target: Double; var p50: Double; var chroma: Double
                        var full: [KnobSurvey.Point]; var mosaic: [KnobSurvey.Point]; var seconds: Double
                    }
                    let line = Line(photo: files[i].lastPathComponent, knob: knob.name, target: target, p50: features.textureP50,
                                    chroma: features.chromaEnergy, full: fullPoints, mosaic: mosaicPoints, seconds: elapsed)
                    let json = String(decoding: try JSONEncoder().encode(line), as: UTF8.self)
                    lines.withLock {
                        $0.append(json)
                        if !FileManager.default.fileExists(atPath: KnobSurvey.out!) {
                            FileManager.default.createFile(atPath: KnobSurvey.out!, contents: nil)
                        }
                        if let h = FileHandle(forWritingAtPath: KnobSurvey.out!) {
                            h.seekToEndOfFile(); h.write(Data((json + "\n").utf8)); try? h.close()
                        }
                    }
                }
            } catch {
                Issue.record("\(files[i].lastPathComponent): \(error)")
            }
        }
        print(String(format: "KNOB SURVEY: %.0f s; before %@, after %@", monotonicSeconds() - start, before, LiveGate.uptime()))
    }
}
