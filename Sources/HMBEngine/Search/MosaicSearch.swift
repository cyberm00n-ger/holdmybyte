// Full-size JPEG search (§3.4): a mosaic proxy curve plus bias-corrected full-resolution probes.
//
// The algorithm is written against two closures so the logic can be tested with analytic score curves:
//   proxyScore(d, chroma) — encode the mosaic at d, decode, score against the mosaic reference
//   probe(d, chroma)      — encode the full variant at d (final settings and markers), decode, score
// Delivered bytes are exactly the bytes of a passing probe (E3).
import Foundation
import HMBModel

struct JPEGSearchOracle {
    var proxyScore: (_ distance: Double, _ chroma: ChromaSubsampling) throws -> Double
    var probe: (_ distance: Double, _ chroma: ChromaSubsampling) throws -> ProbeRecord
}

/// Piecewise-linear s(ln d) through the proxy points, linear extrapolation outside; inverse by bisection.
struct ProxyCurve: Sendable {
    let points: [(x: Double, s: Double)]    // sorted by x = ln d

    init(points: [(x: Double, s: Double)]) {
        self.points = points.sorted { $0.x < $1.x }
        precondition(self.points.count >= 2, "a proxy curve needs at least two points")
    }

    func score(atLn x: Double) -> Double {
        let p = points
        func line(_ a: (x: Double, s: Double), _ b: (x: Double, s: Double), _ x: Double) -> Double {
            b.x == a.x ? a.s : a.s + (x - a.x) * (b.s - a.s) / (b.x - a.x)
        }
        if x <= p[0].x { return line(p[0], p[1], x) }
        if x >= p[p.count - 1].x { return line(p[p.count - 2], p[p.count - 1], x) }
        for i in 1..<p.count where x <= p[i].x { return line(p[i - 1], p[i], x) }
        return p[p.count - 1].s
    }

    /// ln d with s(ln d) = target, assuming s decreases with d; 60 bisection steps over `range`.
    func inverse(_ target: Double, range: ClosedRange<Double>) -> Double {
        var lo = range.lowerBound, hi = range.upperBound
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if score(atLn: mid) > target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

enum MosaicSearch {
    /// The complete §3.4 policy: 4:2:0 search, rescue, 4:4:4 fail-open, keep-original.
    /// - Parameters:
    ///   - keepOriginalAllowed: source is JPEG and colour == .keepProfile.
    ///   - sourceBytes: B_src, for the 0.95 rule.
    ///   - chromaEnergy: for the (default-off) E2 gate.
    static func search(target: Double, oracle: JPEGSearchOracle, keepOriginalAllowed: Bool, sourceBytes: Int,
                       chromaEnergy: Double = 0, constants c: SearchConstants = .spec) throws -> SearchResult {
        var probes = try searchOne(target: target, chroma: .s420, oracle: oracle, constants: c)
        if bestPassing(probes, target: target) == nil {
            probes += try rescue(target: target, chroma: .s420, after: probes, oracle: oracle, constants: c)
        }
        let gate = c.chromaGate && chromaEnergy >= c.chromaGateThreshold
        if bestPassing(probes, target: target) == nil || gate {
            var extra = try searchOne(target: target, chroma: .s444, oracle: oracle, constants: c)
            if bestPassing(extra, target: target) == nil {
                extra += try rescue(target: target, chroma: .s444, after: extra, oracle: oracle, constants: c)
            }
            probes += extra
        }
        let best = bestPassing(probes, target: target)
        if keepOriginalAllowed, best.map({ Double($0.bytes) >= 0.95 * Double(sourceBytes) }) ?? true {
            return SearchResult(outcome: .keepOriginal, probes: probes)
        }
        guard let best else { return SearchResult(outcome: .unreachable, probes: probes) }
        return SearchResult(outcome: .encoded(best), probes: probes)
    }

    /// Proxy curve plus at most `maxFull` full probes for one chroma mode.
    static func searchOne(target t: Double, chroma: ChromaSubsampling, oracle: JPEGSearchOracle,
                          constants c: SearchConstants) throws -> [ProbeRecord] {
        let prior = Targets.jpegPrior(t)
        var points: [(x: Double, s: Double)] = []
        for factor in [0.8, 1.0, 1.25] {
            let d = prior * factor
            points.append((log(d), try oracle.proxyScore(d, chroma)))
        }
        let curve = ProxyCurve(points: points)
        let lnLimits = log(c.distanceLimits.lowerBound)...log(c.distanceLimits.upperBound)
        func clampLn(_ x: Double) -> Double { min(lnLimits.upperBound, max(lnLimits.lowerBound, x)) }

        var probes: [ProbeRecord] = []
        probes.append(try oracle.probe(exp(clampLn(curve.inverse(t + c.m0 - c.bias, range: c.lnDistanceRange))), chroma))
        while probes.count < c.maxFull {
            let passing = probes.filter { $0.passes(t) }
            let failing = probes.filter { !$0.passes(t) }
            if passing.contains(where: { $0.score - t < c.stop }) { break }
            let last = probes[probes.count - 1]
            let bias = last.score - curve.score(atLn: log(last.parameter))
            var ld = curve.inverse(t + c.m1 - bias, range: c.lnDistanceRange)
            let lo = passing.map { log($0.parameter) }.max()
            let hi = failing.map { log($0.parameter) }.min()
            if let lo { ld = max(ld, lo + 0.003) }
            if let hi { ld = min(ld, hi - 0.003) }
            if let lo, let hi {
                if hi - lo < 0.01 { break }
                if !(lo < ld && ld < hi) { ld = (lo + hi) / 2 }
            }
            ld = clampLn(ld)
            if probes.contains(where: { abs(log($0.parameter) - ld) < 1e-9 }) { break }
            probes.append(try oracle.probe(exp(ld), chroma))
        }
        return probes
    }

    /// Up to `rescue` probes at d ← min(failing d)·0.8, never below `dMin`.
    static func rescue(target t: Double, chroma: ChromaSubsampling, after probes: [ProbeRecord],
                       oracle: JPEGSearchOracle, constants c: SearchConstants) throws -> [ProbeRecord] {
        var all = probes, added: [ProbeRecord] = []
        for _ in 0..<c.rescue {
            guard let minFail = all.filter({ !$0.passes(t) }).map(\.parameter).min() else { break }
            let d = max(c.dMin, minFail * 0.8)
            if d >= minFail - 1e-9 { break }        // already at the floor
            let probe = try oracle.probe(d, chroma)
            all.append(probe); added.append(probe)
            if probe.passes(t) { break }
        }
        return added
    }
}
