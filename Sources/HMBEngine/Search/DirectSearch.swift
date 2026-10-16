// Resized (and small full-size) deliveries (§3.5): a secant search on score vs. parameter with bracket
// bookkeeping, directly on the variant. The parameter is mapped to an axis x on which the score decreases:
// JPEG x = ln d, WebP x = −q.
import Foundation
import HMBModel

enum DirectSearch {
    struct Axis: Sendable {
        var start: Double            // x0
        var slope: Double            // default ds/dx (< 0) until two probes give a secant
        var range: ClosedRange<Double>
        var quantum: Double          // x is rounded to multiples of this (deterministic, avoids re-probing)
        var maxStep: Double
        var toParameter: @Sendable (Double) -> Double

        static func jpeg(prior: Double, constants c: SearchConstants) -> Axis {
            Axis(start: log(prior), slope: -10, range: log(c.dMin)...log(c.distanceLimits.upperBound),
                 quantum: 0.001, maxStep: 1.0, toParameter: { exp($0) })
        }
        static func webp(prior: Double) -> Axis {
            Axis(start: -prior, slope: -0.5, range: -100...0, quantum: 1, maxStep: 30, toParameter: { -$0 })
        }
        /// Rounds to the quantum and clamps; values within one quantum of a bound snap to that exact bound.
        func clamp(_ x: Double) -> Double {
            let q = (x / quantum).rounded() * quantum
            if q - range.lowerBound < quantum { return range.lowerBound }
            if range.upperBound - q < quantum { return range.upperBound }
            return q
        }
    }

    /// The core loop. `probe` receives the parameter (d or q).
    static func run(target t: Double, axis: Axis, constants c: SearchConstants, stop: Double? = nil,
                    probe: (Double) throws -> ProbeRecord) throws -> [ProbeRecord] {
        var xs: [Double] = []
        var probes: [ProbeRecord] = []
        var x = axis.clamp(axis.start)
        let stop = stop ?? c.directStop
        let aim = t + stop / 2
        while probes.count < c.directMaxProbes {
            let record = try probe(axis.toParameter(x))
            xs.append(x); probes.append(record)
            if record.passes(t) && record.score - t < stop { break }
            // Secant through the two most recent probes, if it is usable; otherwise the default slope.
            var slope = axis.slope
            if xs.count >= 2 {
                let (x1, s1) = (xs[xs.count - 2], probes[probes.count - 2].score)
                let candidate = (record.score - s1) / (x - x1)
                if x != x1, candidate.isFinite, candidate < 0 { slope = candidate }
            }
            var next = x + max(-axis.maxStep, min(axis.maxStep, (aim - record.score) / slope))
            let lo = zip(xs, probes).filter { $0.1.passes(t) }.map(\.0).max()
            let hi = zip(xs, probes).filter { !$0.1.passes(t) }.map(\.0).min()
            if let lo { next = max(next, lo + axis.quantum) }
            if let hi { next = min(next, hi - axis.quantum) }
            if let lo, let hi {
                if hi - lo <= axis.quantum * 1.5 { break }
                if !(lo < next && next < hi) { next = (lo + hi) / 2 }
            }
            next = axis.clamp(next)
            if xs.contains(where: { abs($0 - next) < axis.quantum / 2 }) { break }
            x = next
        }
        return probes
    }

    /// JPEG: 4:2:0, then the d = dMin floor, then 4:4:4 from the floor. Unreachable only if 4:4:4 at dMin fails.
    /// From `direct444From` up: 4:4:4 from the prior, then the d = dMin floor.
    static func jpeg(target t: Double, constants c: SearchConstants, keepOriginalAllowed: Bool = false,
                     sourceBytes: Int = 0,
                     probe: (Double, ChromaSubsampling) throws -> ProbeRecord) throws -> SearchResult {
        let first: ChromaSubsampling = t >= c.direct444From ? .s444 : .s420
        var probes = try run(target: t, axis: .jpeg(prior: Targets.jpegPrior(t), constants: c), constants: c,
                             stop: c.directStopJPEG) {
            try probe($0, first)
        }
        if bestPassing(probes, target: t) == nil, !probes.contains(where: { abs($0.parameter - c.dMin) < 1e-6 }) {
            probes.append(try probe(c.dMin, first))
        }
        if bestPassing(probes, target: t) == nil, first == .s420 {
            var axis = Axis.jpeg(prior: c.dMin, constants: c)
            axis.start = log(c.dMin)
            probes += try run(target: t, axis: axis, constants: c, stop: c.directStopJPEG) { try probe($0, .s444) }
        }
        let best = bestPassing(probes, target: t)
        if keepOriginalAllowed, best.map({ Double($0.bytes) >= 0.95 * Double(sourceBytes) }) ?? true {
            return SearchResult(outcome: .keepOriginal, probes: probes)
        }
        guard let best else { return SearchResult(outcome: .unreachable, probes: probes) }
        return SearchResult(outcome: .encoded(best), probes: probes)
    }

    /// WebP: search q; if nothing passes, q = 100 must be tried; if that fails too, nil (fall back to JPEG).
    static func webp(target t: Double, constants c: SearchConstants,
                     probe: (Double) throws -> ProbeRecord) throws -> (best: ProbeRecord?, probes: [ProbeRecord]) {
        var probes = try run(target: t, axis: .webp(prior: Targets.webpPrior(t)), constants: c, probe: probe)
        if bestPassing(probes, target: t) == nil, !probes.contains(where: { $0.parameter >= 100 }) {
            probes.append(try probe(100))
        }
        return (bestPassing(probes, target: t), probes)
    }
}
