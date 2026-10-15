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
        if bestPassing(probes, target: target) == nil, c.aim == .proxyCurve {
            probes += try rescue(target: target, chroma: .s420, after: probes, oracle: oracle, constants: c)
        }
        let gate = c.chromaGate && chromaEnergy >= c.chromaGateThreshold
        if bestPassing(probes, target: target) == nil || gate {
            var extra = try searchOne(target: target, chroma: .s444, oracle: oracle, constants: c)
            if bestPassing(extra, target: target) == nil, c.aim == .proxyCurve {
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

    /// Proxy plus at most `maxFull` full probes for one chroma mode.
    static func searchOne(target t: Double, chroma: ChromaSubsampling, oracle: JPEGSearchOracle,
                          constants c: SearchConstants) throws -> [ProbeRecord] {
        switch c.aim {
        case .proxyCurve: try searchOneProxyCurve(target: t, chroma: chroma, oracle: oracle, constants: c)
        case .mosaicExact: try searchOneMosaicExact(target: t, chroma: chroma, oracle: oracle, constants: c)
        }
    }

    /// The original §3.4 loop: a 3-point piecewise-linear proxy curve, shifted by the last probe's bias.
    static func searchOneProxyCurve(target t: Double, chroma: ChromaSubsampling, oracle: JPEGSearchOracle,
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

    /// `.mosaicExact` (Docs/ENGINE.md §3.2): full(ln d) ≈ mosaic(ln d) + bias(ln d).
    ///
    /// jpegli's scores fall in steps at fixed distances (quantiser changes, e.g. between d 2.065 and 2.117), and the
    /// mosaic falls at the same distances. Instead of a smooth curve through three mosaic points, the aim is solved on
    /// the mosaic itself, encoded and scored at every distance the solver tries (a few cheap 2-MP encodes), so a step
    /// is never bridged by interpolation. The bias (full − mosaic at the same distance) is nearly constant per photo
    /// (holdout: sd 0.1–0.2 over d 1.4…3): before any full probe it is `exactBiasPrior`; with probes on one side of
    /// the target it is the nearest probe's bias plus `exactBiasSlope`·Δln d; once a passing and a failing probe
    /// bracket the target it is interpolated linearly between them (the final step is an interpolation, not a
    /// re-extrapolation). Every distance is a multiple of 1e-4 in ln d, so the solver's and the probes' distances are
    /// identical and runs are deterministic.
    static func searchOneMosaicExact(target t: Double, chroma: ChromaSubsampling, oracle: JPEGSearchOracle,
                                     constants c: SearchConstants) throws -> [ProbeRecord] {
        let q = 1e-4
        func quantised(_ x: Double) -> Double { (x / q).rounded() * q }
        let domain = max(c.lnDistanceRange.lowerBound, log(c.distanceLimits.lowerBound))...min(
            c.lnDistanceRange.upperBound, log(c.distanceLimits.upperBound))

        var mosaic: [Int: Double] = [:]                       // ln d / q → mosaic score
        func m(_ x: Double) throws -> Double {
            let k = Int((x / q).rounded())
            if let v = mosaic[k] { return v }
            let v = try oracle.proxyScore(exp(Double(k) * q), chroma)
            mosaic[k] = v
            return v
        }
        struct Full { var x: Double; var s: Double; var b: Double }
        var fulls: [Full] = []
        var probes: [ProbeRecord] = []

        func bias(at x: Double) -> Double {
            let pass = fulls.filter { $0.s >= t }.max { $0.x < $1.x }
            let fail = fulls.filter { $0.s < t }.min { $0.x < $1.x }
            if let p = pass, let f = fail, f.x > p.x {
                return p.b + (f.b - p.b) * (x - p.x) / (f.x - p.x)
            }
            guard let ref = fulls.min(by: { abs($0.s - t) < abs($1.s - t) }) else { return c.exactBiasPrior }
            return ref.b + c.exactBiasSlope * (x - ref.x)
        }

        /// The largest x in lo…hi whose predicted full score reaches `goal` (bracket refined on the mosaic), or nil if
        /// even `lo` is predicted to fail.
        func solve(goal: Double, lo: Double, hi: Double) throws -> Double? {
            func g(_ x: Double) throws -> Double { try m(x) + bias(at: x) - goal }
            var a: (x: Double, g: Double)?, b: (x: Double, g: Double)?
            func note(_ x: Double, _ v: Double) {
                if v >= 0 { if a == nil || x > a!.x { a = (x, v) } } else if b == nil || x < b!.x { b = (x, v) }
            }
            for k in mosaic.keys.sorted() {
                let x = Double(k) * q
                if x >= lo - q / 2, x <= hi + q / 2 { note(x, try g(x)) }
            }
            // A pass right of the smallest fail (a non-monotone step) does not count: keep the bracket ordered.
            if let fa = a, let fb = b, fa.x > fb.x { a = nil; for k in mosaic.keys.sorted() {
                let x = Double(k) * q
                if x >= lo - q / 2, x < fb.x, let v = try? g(x), v >= 0 { a = (x, v) } } }
            if a == nil, b == nil { let x = quantised((lo + hi) / 2); note(x, try g(x)) }
            var evals = 0
            while a == nil || b == nil, evals < c.exactSolverEvals {
                if a == nil, let fb = b {
                    let x = quantised(max(lo, fb.x - max(0.02, -fb.g / 8)))
                    if x >= fb.x - q / 2 { break }
                    note(x, try g(x)); evals += 1
                } else if let fa = a {
                    let x = quantised(min(hi, fa.x + max(0.02, fa.g / 8)))
                    if x <= fa.x + q / 2 { break }
                    note(x, try g(x)); evals += 1
                }
            }
            guard var pass = a else { return nil }
            guard var fail = b else { return pass.x }
            while fail.x - pass.x > c.exactSolverWidth, evals < c.exactSolverEvals {
                let w = fail.x - pass.x
                let x = quantised(min(fail.x - 0.2 * w, max(pass.x + 0.2 * w, pass.x + w * pass.g / (pass.g - fail.g))))
                if x <= pass.x || x >= fail.x { break }
                let v = try g(x); evals += 1
                if v >= 0 { pass = (x, v) } else { fail = (x, v) }
            }
            if fail.x - pass.x <= c.exactSolverWidth { return pass.x }
            // Out of evaluations with a wide bracket: aim at the interpolated root rather than the conservative side.
            return quantised(pass.x + (fail.x - pass.x) * pass.g / (pass.g - fail.g))
        }

        func probe(_ x: Double) throws {
            let record = try oracle.probe(exp(x), chroma)
            probes.append(record)
            fulls.append(Full(x: x, s: record.score, b: record.score - (try m(x))))
        }

        let prior = Targets.jpegPrior(t)
        for factor in [0.8, 1.0, 1.25] { _ = try m(quantised(log(prior * factor))) }
        try probe(try solve(goal: t + c.exactFirstMargin, lo: domain.lowerBound, hi: domain.upperBound) ?? domain.lowerBound)
        while probes.count < c.maxFull {
            if fulls.contains(where: { $0.s >= t && $0.s - t < c.exactStop }) { break }
            let maxPass = fulls.filter { $0.s >= t }.map(\.x).max()
            let minFail = fulls.filter { $0.s < t }.map(\.x).min()
            let lo = quantised(max(domain.lowerBound, (maxPass ?? -.infinity) + c.exactMinStep))
            let hi = quantised(min(domain.upperBound, (minFail ?? .infinity) - c.exactMinStep))
            guard hi >= lo else { break }
            let failing = fulls.filter { $0.s < t }.count
            let margin = c.exactMargin + c.exactFailStep * Double(max(0, failing - 1))
            guard let x = try solve(goal: t + margin, lo: lo, hi: hi) ?? (maxPass == nil ? lo : nil) else { break }
            if fulls.contains(where: { abs($0.x - x) < q / 2 }) { break }
            try probe(x)
        }
        // Rescue (replaces the generic ×0.8 rescue for this aim): model first, then ×0.8; never below dMin.
        var rescued = 0
        while rescued < c.rescue, !fulls.contains(where: { $0.s >= t }), let minFail = fulls.map(\.x).min() {
            let floor = quantised(log(c.dMin))
            var x = quantised(minFail + log(0.8))
            if rescued == 0, let solved = try solve(goal: t + c.exactRescueMargin, lo: domain.lowerBound,
                                                   hi: quantised(minFail - c.exactMinStep)) {
                x = solved
            }
            x = max(x, floor)
            if x >= minFail - q / 2 { break }                  // already at the floor
            try probe(x)
            rescued += 1
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
