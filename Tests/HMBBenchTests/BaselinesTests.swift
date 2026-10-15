import Foundation
@testable import HMBBench
import Testing

/// `Benchmarks/baselines.json` (§5.5 acceptance 5).
@Suite struct BaselinesTests {
    let baselines = try! Baselines.load(from: repositoryRoot.appending(path: "Benchmarks/baselines.json"))

    @Test func datenlageTotalsAndTimes() {
        let wedding = baselines.wedding
        #expect(wedding.photos == 535 && wedding.sourceBytes == 10_950_000_000)
        #expect(wedding.oldEngine.couple.bytes == 1_350_000_000 && wedding.oldEngine.couple.wallSeconds == 1044)
        #expect(wedding.oldEngine.highFull.bytes == 3_050_000_000)
        #expect(wedding.oldEngine.website.bytes == 159_000_000 && wedding.oldEngine.social.bytes == 155_000_000)
        #expect(wedding.oldEngine.archive.bytes == 8_550_000_000 && wedding.oldEngine.archive.byteExact == 535)
        #expect(wedding.oldEngine.allFourSeparateRunsWallSeconds == 2370)
    }

    @Test func jpegminiTotalsAndThroughput() {
        let jpegmini = baselines.wedding.jpegmini
        #expect(jpegmini.bytes == 5_360_000_000 && jpegmini.secondsPerPhoto == 0.42 && jpegmini.scoreMin == 75.0)
    }

    @Test func holdoutPerFileNumbers() {
        let holdout = baselines.holdout
        #expect(holdout.files.count == 19 && holdout.photos == 19)
        #expect(holdout.files.reduce(0) { $0 + $1.oldBytes } == holdout.oldEngine.bytes)
        #expect(holdout.oldEngine.bytes == 49_806_559)                      // "old engine 49.81 MB" (§6.2 G1)
        #expect(holdout.files.reduce(0) { $0 + $1.sourceBytes } == holdout.sourceBytes)
        #expect(holdout.files.allSatisfy { $0.oldReferenceScore > 73 && $0.oldReferenceScore < 76 && $0.oldOwnScore >= 74 })
        #expect(Set(holdout.files.map(\.name)).count == 19)
    }

    @Test func gateThresholdsMatchTheSpec() {
        let gates = baselines.gates
        #expect(gates.quietLoadAverage == 3)
        #expect(gates.G1.maxBytes == 50_310_000 && gates.G1.maxMeanProbes == 2.2)
        #expect(gates.G2.maxWallRatioToOldEngine == 0.6)
        #expect(gates.G3.maxBytes == 1_370_000_000 && gates.G3.maxWallSeconds == 600)
        #expect(gates.G4.minScore == 85 && gates.G4.maxBytes == 3_100_000_000)
        #expect(gates.G5.website.maxBytes == 165_000_000 && gates.G5.website.maxWallSecondsAlone == 150 && gates.G5.social.minScore == 85)
        #expect(gates.G6.maxBytes == 8_600_000_000 && gates.G6.maxWallSecondsAlone == 360)
        #expect(gates.G7.maxWallSeconds == 840 && gates.G7.maxEstimateError == 0.15 && gates.G7.maxPeakRSSBytes == 8_000_000_000)
    }
}
