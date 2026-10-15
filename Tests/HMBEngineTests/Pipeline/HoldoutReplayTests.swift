// Replays MosaicSearch (§3.4, binding constants) on measured holdout curves (HoldoutCurves.swift): full-resolution
// scores and bytes are interpolated in ln d between measured points; the proxy uses the measured grid mosaic.
// This checks the Swift port against the simulation that fixed the constants (sim-B: 2.0 probes mean, max 3).
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

/// Piecewise-linear interpolation in x with linear extrapolation from the end segments.
func interpolate(_ points: [(x: Double, y: Double)], at x: Double) -> Double {
    let p = points.sorted { $0.x < $1.x }
    guard p.count >= 2 else { return p.first?.y ?? 0 }
    func line(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double { a.y + (x - a.x) * (b.y - a.y) / (b.x - a.x) }
    if x <= p[0].x { return line(p[0], p[1]) }
    if x >= p[p.count - 1].x { return line(p[p.count - 2], p[p.count - 1]) }
    for i in 1..<p.count where x <= p[i].x { return line(p[i - 1], p[i]) }
    return p[p.count - 1].y
}

extension HoldoutCurve {
    var scorePoints: [(x: Double, y: Double)] { dedup(full.map { (log($0.d), $0.score) }) }
    var bytePoints: [(x: Double, y: Double)] { dedup(full.map { (log($0.d), log(Double($0.bytes))) }) }
    private func dedup(_ pts: [(x: Double, y: Double)]) -> [(x: Double, y: Double)] {
        var out: [(x: Double, y: Double)] = []
        for p in pts.sorted(by: { $0.x < $1.x }) {
            if let last = out.last, p.x - last.x < 1e-3 { out[out.count - 1] = ((last.x + p.x) / 2, (last.y + p.y) / 2) } else { out.append(p) }
        }
        return out
    }

    func oracle(probes: Locked<Int>) -> JPEGSearchOracle {
        let scores = scorePoints, bytes = bytePoints, proxy = mosaic.map { (x: log($0.d), y: $0.score) }
        return JPEGSearchOracle(
            proxyScore: { d, _ in interpolate(proxy, at: log(d)) },
            probe: { d, chroma in
                probes.withLock { $0 += 1 }
                return ProbeRecord(parameter: d, subsampling: chroma, score: interpolate(scores, at: log(d)),
                                   data: Data(count: Int(exp(interpolate(bytes, at: log(d))))))
            })
    }
}

@Suite struct HoldoutReplayTests {
    @Test func replayMatchesTheSimulationThatFixedTheConstants() throws {
        var total = 0, old = 0, probeCounts: [Int] = [], overshoot: [Double] = []
        for curve in holdoutCurves {
            let probes = Locked(0)
            // The replay's proxy is the 3-point mosaic of the old experiments, so only the curve aim can be replayed;
            // the shipped `.mosaicExact` aim is measured live (SearchABTests, Docs/ENGINE.md §3.4).
            var constants = SearchConstants.spec
            constants.aim = .proxyCurve
            let result = try MosaicSearch.search(target: curve.target, oracle: curve.oracle(probes: probes),
                                                 keepOriginalAllowed: false, sourceBytes: 20_000_000, constants: constants)
            guard case .encoded(let best) = result.outcome else { Issue.record("\(curve.name) unresolved"); continue }
            #expect(best.score >= curve.target)
            #expect(probes.snapshot == result.fullProbes)
            total += best.bytes; old += curve.oldBytes
            probeCounts.append(result.fullProbes); overshoot.append(best.score - curve.target)
        }
        let mean = Double(probeCounts.reduce(0, +)) / Double(probeCounts.count)
        print(String(format: "holdout replay: %.2f MB vs old %.2f MB (%+.2f %%), probes mean %.2f max %d, overshoot mean %.2f max %.2f",
                     Double(total) / 1e6, Double(old) / 1e6, 100 * (Double(total) / Double(old) - 1), mean,
                     probeCounts.max() ?? 0, overshoot.reduce(0, +) / Double(overshoot.count), overshoot.max() ?? 0))
        #expect(holdoutCurves.count == 19)
        #expect(mean <= 2.2)
        #expect((probeCounts.max() ?? 0) <= 3)
        #expect(Double(total) <= 50_310_000)
    }
}
