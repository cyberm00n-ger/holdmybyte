// Acceptance §5.2.5: search logic on analytic score curves.
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

/// score(d) = a − b·ln d (+ δ for 4:4:4), bytes(d) = c·d^−k (× 1.15 for 4:4:4); the proxy reads `proxyBias` higher.
struct AnalyticPhoto: Sendable {
    var a: Double, b: Double, c: Double, k: Double
    var proxyBias: Double = 1.5
    var delta444: Double = 0
    var noise: Double = 0           // deterministic wobble on full probes

    func score(_ d: Double, _ chroma: ChromaSubsampling) -> Double {
        a - b * log(d) + (chroma == .s444 ? delta444 : 0) + noise * sin(d * 37)
    }
    func bytes(_ d: Double, _ chroma: ChromaSubsampling) -> Int {
        Int(c * pow(d, -k) * (chroma == .s444 ? 1.15 : 1))
    }
    final class Counter: @unchecked Sendable { var full: [ChromaSubsampling] = []; var proxy = 0 }

    func oracle(_ counter: Counter) -> JPEGSearchOracle {
        JPEGSearchOracle(
            proxyScore: { d, chroma in counter.proxy += 1; return score(d, chroma) + proxyBias - noise * sin(d * 37) },
            probe: { d, chroma in
                counter.full.append(chroma)
                return ProbeRecord(parameter: d, subsampling: chroma, score: score(d, chroma),
                                   data: Data(count: max(1, bytes(d, chroma))))
            })
    }
}

@Suite struct SearchTests {
    /// Deterministic family of photos around the holdout regime (targets 74…87, slopes 6…14 per ln d).
    static func family(_ n: Int, seed: UInt64 = 7) -> [(AnalyticPhoto, Double)] {
        var state = seed
        func next() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
        return (0..<n).map { _ in
            let b = 6 + 8 * next()
            let t = 74 + 13 * next()
            let dStar = 0.6 + 2.6 * next()                           // where the curve crosses T
            let photo = AnalyticPhoto(a: t + b * log(dStar), b: b, c: 3_000_000, k: 0.8,
                                      proxyBias: 1.5 + (next() - 0.5) * 1.2, noise: 0.15 * next())
            return (photo, t)
        }
    }

    @Test(arguments: [SearchConstants.Aim.proxyCurve, .mosaicExact])
    func neverReturnsAFailingProbeAndStaysWithinTheProbeBudget(aim: SearchConstants.Aim) throws {
        var constants = SearchConstants.spec
        constants.aim = aim
        var totalProbes = 0
        for (photo, t) in Self.family(200) {
            let counter = AnalyticPhoto.Counter()
            let result = try MosaicSearch.search(target: t, oracle: photo.oracle(counter), keepOriginalAllowed: false,
                                                 sourceBytes: 20_000_000, constants: constants)
            guard case .encoded(let best) = result.outcome else { Issue.record("unresolved at T \(t)"); continue }
            #expect(best.score >= t)
            #expect(best.bytes == result.probes.filter { $0.score >= t }.map(\.bytes).min())
            let s420 = counter.full.filter { $0 == .s420 }.count
            #expect(s420 <= 3 + 2)
            #expect(counter.full.count <= 2 * (3 + 2))
            #expect(counter.full.allSatisfy { $0 == .s420 })                // 4:2:0 reachable → no 4:4:4
            if aim == .proxyCurve {
                #expect(counter.proxy == 3)
            } else {
                // 3 seeds plus at most `exactSolverEvals` (+1 start, +1 bias read-back) per aimed probe.
                #expect(counter.proxy <= 3 + (3 + 2) * (constants.exactSolverEvals + 2))
            }
            totalProbes += result.fullProbes
        }
        let mean = Double(totalProbes) / 200
        print(String(format: "analytic family (200 photos, %@): mean full probes %.2f", aim.rawValue, mean))
        #expect(mean <= 2.6, "mean full probes \(mean)")
    }

    @Test func keepOriginalAtNinetyFivePercentOfTheSource() throws {
        let photo = AnalyticPhoto(a: 80, b: 10, c: 1_000_000, k: 0.8)
        // Find the delivered size first, then put the source just above and just below 0.95 of it.
        let counter = AnalyticPhoto.Counter()
        let free = try MosaicSearch.search(target: 74, oracle: photo.oracle(counter), keepOriginalAllowed: false, sourceBytes: 0)
        guard case .encoded(let best) = free.outcome else { Issue.record("expected an encode"); return }
        let atThreshold = Int((Double(best.bytes) / 0.95).rounded(.down))      // best ≥ 0.95 × source
        let kept = try MosaicSearch.search(target: 74, oracle: photo.oracle(.init()), keepOriginalAllowed: true,
                                           sourceBytes: atThreshold)
        #expect({ if case .keepOriginal = kept.outcome { true } else { false } }())
        let comfortable = try MosaicSearch.search(target: 74, oracle: photo.oracle(.init()), keepOriginalAllowed: true,
                                                  sourceBytes: atThreshold + 200)
        #expect({ if case .encoded = comfortable.outcome { true } else { false } }())
        // Not allowed (non-JPEG source or sRGB conversion): never kept, even when larger.
        let notAllowed = try MosaicSearch.search(target: 74, oracle: photo.oracle(.init()), keepOriginalAllowed: false,
                                                 sourceBytes: 10)
        #expect({ if case .encoded = notAllowed.outcome { true } else { false } }())
    }

    @Test func failOpenTo444OnlyWhenFourTwoZeroIsUnreachable() throws {
        // 4:2:0 tops out below the target even at tiny distances; 4:4:4 gains 12 points.
        let hard = AnalyticPhoto(a: 70, b: 2, c: 1_000_000, k: 0.8, delta444: 12)
        let counter = AnalyticPhoto.Counter()
        let result = try MosaicSearch.search(target: 75, oracle: hard.oracle(counter), keepOriginalAllowed: false,
                                             sourceBytes: 50_000_000)
        guard case .encoded(let best) = result.outcome else { Issue.record("expected 4:4:4 to resolve"); return }
        #expect(best.subsampling == .s444)
        #expect(best.score >= 75)
        #expect(counter.full.prefix { $0 == .s420 }.count <= 5)
        #expect(counter.full.contains(.s444))
        #expect(counter.full.count <= 10)

        // Reachable with 4:2:0 → 4:4:4 never probed (gate off).
        let easy = AnalyticPhoto(a: 85, b: 10, c: 1_000_000, k: 0.8, delta444: 12)
        let easyCounter = AnalyticPhoto.Counter()
        _ = try MosaicSearch.search(target: 75, oracle: easy.oracle(easyCounter), keepOriginalAllowed: false, sourceBytes: 50_000_000)
        #expect(!easyCounter.full.contains(.s444))
    }

    @Test func unreachableWithoutKeepOriginalIsReported() throws {
        let impossible = AnalyticPhoto(a: 50, b: 2, c: 1_000_000, k: 0.8, delta444: 1)
        let counter = AnalyticPhoto.Counter()
        let result = try MosaicSearch.search(target: 90, oracle: impossible.oracle(counter), keepOriginalAllowed: false,
                                             sourceBytes: 1)
        #expect({ if case .unreachable = result.outcome { true } else { false } }())
        #expect(counter.full.count <= 10)
        let kept = try MosaicSearch.search(target: 90, oracle: impossible.oracle(.init()), keepOriginalAllowed: true,
                                           sourceBytes: 1)
        #expect({ if case .keepOriginal = kept.outcome { true } else { false } }())
    }

    @Test func chromaGateSearchesBothWhenEnabled() throws {
        var constants = SearchConstants.spec
        constants.chromaGate = true
        let photo = AnalyticPhoto(a: 85, b: 10, c: 1_000_000, k: 0.8, delta444: 3)
        let counter = AnalyticPhoto.Counter()
        _ = try MosaicSearch.search(target: 75, oracle: photo.oracle(counter), keepOriginalAllowed: false,
                                    sourceBytes: 50_000_000, chromaEnergy: 3.0, constants: constants)
        #expect(counter.full.contains(.s444))
        let low = AnalyticPhoto.Counter()
        _ = try MosaicSearch.search(target: 75, oracle: photo.oracle(low), keepOriginalAllowed: false,
                                    sourceBytes: 50_000_000, chromaEnergy: 1.0, constants: constants)
        #expect(!low.full.contains(.s444))
    }

    @Test func proxyCurveInvertsAndExtrapolates() {
        let curve = ProxyCurve(points: [(log(1.6), 80), (log(2.0), 77), (log(2.5), 74)])
        let range = log(0.3)...log(8)
        #expect(abs(curve.score(atLn: curve.inverse(77, range: range)) - 77) < 1e-6)
        #expect(abs(curve.score(atLn: curve.inverse(85, range: range)) - 85) < 1e-6)     // extrapolated
        #expect(abs(exp(curve.inverse(77, range: range)) - 2.0) < 1e-6)
        #expect(abs(Targets.jpegPrior(74) - 2.0) < 0.01 && abs(Targets.jpegPrior(85) - 1.03) < 0.01)
        #expect(abs(Targets.jpegPrior(90) - 0.77) < 0.01)
    }

    @Test func balancedTargetMatchesClassicTarget() {
        #expect(Targets.balanced(textureP50: 3) == 74)
        #expect(Targets.balanced(textureP50: 5.3) == 88 - 0.62 * 5.3)
        #expect(Targets.balanced(textureP50: 30) == 75)
        #expect(abs(Targets.balanced(textureP50: 4.5) - 85.21) < 1e-9)
        #expect(Targets.target(.high, features: nil) == 85)
        #expect(Targets.target(.web, features: nil) == 70)
        #expect(Targets.target(.highest, features: nil) == 90)
        #expect(Targets.target(.lossless, features: nil) == nil)
    }

    // MARK: DirectSearch

    @Test func directJPEGNeverFailsAndStopsWithinFiveProbes() throws {
        for (photo, t) in Self.family(100, seed: 11) {
            var count = 0
            let result = try DirectSearch.jpeg(target: t, constants: .spec) { d, chroma in
                count += 1
                return ProbeRecord(parameter: d, subsampling: chroma, score: photo.score(d, chroma),
                                   data: Data(count: photo.bytes(d, chroma)))
            }
            guard case .encoded(let best) = result.outcome else { Issue.record("unresolved"); continue }
            #expect(best.score >= t)
            #expect(count <= 5)
        }
    }

    @Test func directJPEGUnreachableAfterFourFourFourAtTheFloor() throws {
        var probes: [(Double, ChromaSubsampling)] = []
        let result = try DirectSearch.jpeg(target: 95, constants: .spec) { d, chroma in
            probes.append((d, chroma))
            return ProbeRecord(parameter: d, subsampling: chroma, score: 60 - log(d), data: Data(count: 10))
        }
        #expect({ if case .unreachable = result.outcome { true } else { false } }())
        #expect(probes.contains { abs($0.0 - 0.5) < 1e-9 && $0.1 == .s420 })
        #expect(probes.contains { abs($0.0 - 0.5) < 1e-9 && $0.1 == .s444 })
        #expect(probes.allSatisfy { $0.0 >= 0.5 - 1e-9 })
    }

    @Test func webpSearchTriesQualityHundredBeforeFallingBack() throws {
        var qs: [Double] = []
        let unreachable = try DirectSearch.webp(target: 90, constants: .spec) { q in
            qs.append(q)
            return ProbeRecord(parameter: q, subsampling: nil, score: 50 + q * 0.3, data: Data(count: Int(q) + 1))
        }
        #expect(unreachable.best == nil)
        #expect(qs.contains(100))
        var count = 0
        let reachable = try DirectSearch.webp(target: 70, constants: .spec) { q in
            count += 1
            return ProbeRecord(parameter: q, subsampling: nil, score: 40 + q * 0.42, data: Data(count: Int(q * 1000) + 1))
        }
        #expect((reachable.best?.score ?? 0) >= 70)
        #expect((reachable.best?.score ?? 100) - 70 < 1.0)
        #expect(count <= 5)
    }
}
