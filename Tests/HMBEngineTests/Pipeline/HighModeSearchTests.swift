// The high-target mode's policy in MosaicSearch (Docs/variants/highest.md, D-ENG-12): off below the band, both
// searches inside it (the smaller verified result wins), the high mode first above it (the tuned search only if it
// reaches nothing); inside the high mode 4:2:0, plus 4:4:4 from `high444From` unless the mosaic rules it out.
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite struct HighModeSearchTests {
    /// Tuned search: the `tuned` curves; high mode: the `high` curves, bytes × `highBytes`. Mosaic bytes are the
    /// full-size bytes / 20 (same shape, so the 4:4:4 preselection sees the true ratio).
    struct Pair {
        var tuned: AnalyticPhoto
        var high: AnalyticPhoto
        var highBytes: Double
        var mosaicBytes = true
        final class Counter: @unchecked Sendable { var tuned: [ChromaSubsampling] = []; var high: [ChromaSubsampling] = [] }
        func oracles(_ counter: Counter) -> (JPEGSearchOracle, JPEGSearchOracle) {
            let tuned = JPEGSearchOracle(
                proxyScore: { d, chroma in self.tuned.score(d, chroma) + self.tuned.proxyBias },
                probe: { d, chroma in
                    counter.tuned.append(chroma)
                    return ProbeRecord(parameter: d, subsampling: chroma, score: self.tuned.score(d, chroma),
                                       data: Data(count: max(1, self.tuned.bytes(d, chroma))))
                })
            func highBytes(_ d: Double, _ chroma: ChromaSubsampling) -> Int {
                max(1, Int(Double(self.high.bytes(d, chroma)) * self.highBytes))
            }
            var high = JPEGSearchOracle(
                proxyScore: { d, chroma in self.high.score(d, chroma) + self.high.proxyBias },
                probe: { d, chroma in
                    counter.high.append(chroma)
                    return ProbeRecord(parameter: d, subsampling: chroma, score: self.high.score(d, chroma),
                                       data: Data(count: highBytes(d, chroma)))
                })
            if mosaicBytes { high.proxyBytes = { d, chroma in highBytes(d, chroma) / 20 } }
            return (tuned, high)
        }
    }

    static let pair = Pair(tuned: AnalyticPhoto(a: 92, b: 8, c: 3_000_000, k: 0.8, proxyBias: 1.1),
                           high: AnalyticPhoto(a: 92, b: 8, c: 3_000_000, k: 0.8, proxyBias: 0.3, delta444: 0.5),
                           highBytes: 0.9)

    func run(_ pair: Pair, target: Double, constants: SearchConstants = .spec, withHigh: Bool = true)
        throws -> (SearchResult, Pair.Counter) {
        let counter = Pair.Counter()
        let (tuned, high) = pair.oracles(counter)
        let result = try MosaicSearch.search(target: target, oracle: tuned, high: withHigh ? high : nil,
                                             keepOriginalAllowed: false, sourceBytes: 50_000_000, constants: constants)
        return (result, counter)
    }

    func best(_ result: SearchResult) -> ProbeRecord? { if case .encoded(let b) = result.outcome { b } else { nil } }

    @Test func belowTheBandOnlyTheTunedSearchRuns() throws {
        let (with, counter) = try run(Self.pair, target: 80)
        let (without, _) = try run(Self.pair, target: 80, withHigh: false)
        #expect(counter.high.isEmpty)
        #expect(with.probes.map(\.parameter) == without.probes.map(\.parameter))
        #expect(best(with)?.highMode == false)
    }

    @Test func aboveTheBandTheHighModeRunsFirstAndAlone() throws {
        let (result, counter) = try run(Self.pair, target: 86)
        #expect(!counter.high.isEmpty)
        #expect(counter.tuned.isEmpty)
        #expect(counter.high.allSatisfy { $0 == .s420 })             // below high444From: 4:2:0 reaches T
        let b = try #require(best(result))
        #expect(b.highMode && b.score >= 86)
        #expect(result.probes.allSatisfy { $0.highMode })
    }

    @Test func aboveTheBandTheTunedSearchRescuesAnUnreachableHighMode() throws {
        var pair = Self.pair
        pair.high = AnalyticPhoto(a: 70, b: 2, c: 3_000_000, k: 0.8)          // never reaches 90
        let (result, counter) = try run(pair, target: 90)
        #expect(counter.high.contains(.s420) && counter.high.contains(.s444))
        #expect(!counter.tuned.isEmpty)
        let b = try #require(best(result))
        #expect(!b.highMode && b.score >= 90)
    }

    @Test(arguments: [0.8, 1.25])
    func insideTheBandTheSmallerVerifiedResultWins(highBytes: Double) throws {
        var constants = SearchConstants.spec
        constants.highCompareFrom = 85
        constants.highFirstFrom = 88
        var pair = Self.pair
        pair.highBytes = highBytes
        let (result, counter) = try run(pair, target: 86, constants: constants)
        #expect(!counter.high.isEmpty && !counter.tuned.isEmpty)
        let b = try #require(best(result))
        #expect(b.bytes == result.probes.filter { $0.score >= 86 }.map(\.bytes).min())
        #expect(b.highMode == (highBytes < 1))
    }

    @Test func fourFourFourIsSearchedFromHigh444FromUnlessTheMosaicRulesItOut() throws {
        // AnalyticPhoto's 4:4:4 costs 15 % more bytes at the same distance; +0.5 points lets it use a coarser one.
        // With a small score gain 4:4:4 stays larger → preselection skips it.
        let (skipped, c1) = try run(Self.pair, target: 90)
        #expect(c1.high.allSatisfy { $0 == .s420 })
        #expect(best(skipped)?.subsampling == .s420)
        // Without mosaic bytes both are searched (and the smaller verified result is delivered).
        var noBytes = Self.pair
        noBytes.mosaicBytes = false
        let (both, c2) = try run(noBytes, target: 90)
        #expect(c2.high.contains(.s444))
        #expect(best(both)?.bytes == both.probes.filter { $0.score >= 90 }.map(\.bytes).min())
        // A large 4:4:4 gain (5 points) makes it smaller: searched and delivered.
        var gain = Self.pair
        gain.high.delta444 = 5
        let (won, c3) = try run(gain, target: 90)
        #expect(c3.high.contains(.s444))
        #expect(best(won)?.subsampling == .s444)
        // Below high444From only 4:2:0.
        let (low, c4) = try run(gain, target: 88)
        #expect(c4.high.allSatisfy { $0 == .s420 })
        #expect(best(low)?.subsampling == .s420)
    }

    @Test func switchedOffIsTheTunedSearch() throws {
        var constants = SearchConstants.spec
        constants.highCompareFrom = .infinity
        constants.highFirstFrom = .infinity
        let (off, counter) = try run(Self.pair, target: 90, constants: constants)
        let (without, _) = try run(Self.pair, target: 90, withHigh: false)
        #expect(counter.high.isEmpty)
        #expect(off.probes.map(\.parameter) == without.probes.map(\.parameter))
    }
}

/// Live gate of the high-target mode on the holdout (Docs/variants/highest.md): Highest full-size, every photo ≥ 90
/// in the high mode, total below the tuned search's 191,497,771 bytes (main 66e3db0) by at least 4 %.
@Suite(.serialized) struct HighModeLiveTests {
    @Test(.enabled(if: LiveGate.holdoutReady)) func holdoutHighestUsesTheHighModeAboveNinety() async throws {
        let dir = TempDir("live-highest")
        let engine = LiveGate.engine(dir)
        let scan = try await LiveGate.scan(engine, LiveGate.holdout!)
        let highest = DeliveryPreset(id: DeliveryID(rawValue: "highest-full"), name: "Highest full-size", symbol: "star",
                                     format: .jpeg, size: .full, quality: .highest, colour: .keepProfile, metadata: .keepAll,
                                     folderName: "Highest")
        let request = makeRequest(name: "Holdout", photos: scan.photos, roots: scan.sourceRoots,
                                  output: dir.sub("out").appending(path: "Holdout \u{2013} Deliveries"), deliveries: [highest])
        let before = LiveGate.uptime()
        let start = monotonicSeconds()
        let log = await collect(engine.run(request, resume: false))
        #expect(log.terminal == .finished)
        let results = log.results
        #expect(results.count == 19)
        for r in results {
            #expect(r.status == .done, "photo \(r.photo.index)")
            #expect((r.score ?? 0) >= 90, "photo \(r.photo.index)")
            #expect(r.encoder == "jpegli (high)", "photo \(r.photo.index)")
        }
        let total = results.reduce(Int64(0)) { $0 + ($1.outBytes ?? 0) }
        let probes = Double(results.map(\.probes).reduce(0, +)) / 19
        print(String(format: "LIVE holdout Highest: %.3f MB, probes %.2f, 4:4:4 %d, wall %.1f s; before %@, after %@",
                     Double(total) / 1e6, probes, results.filter { $0.chroma == .s444 }.count, monotonicSeconds() - start,
                     before, LiveGate.uptime()))
        #expect(total <= 183_000_000)
        #expect(Double(total) <= 0.96 * 191_497_771)
        #expect(probes <= 3.2)
    }
}
