// jpegli knobs of the high-target mode (Docs/variants/highest.md): standard (Annex K) tables, sequential coding and
// the high tuning's 4:4:4 / AQ-off settings produce the JPEG structure they claim.
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite struct HighModeCodecTests {
    /// DQT tables (natural order) and the SOF marker of a JPEG.
    static func structure(_ jpeg: Data) -> (tables: [Int: [Int]], sof: UInt8?, sampling: [Int]) {
        let zigzag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7,
                      14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39,
                      46, 53, 60, 61, 54, 47, 55, 62, 63]
        let b = [UInt8](jpeg)
        var tables: [Int: [Int]] = [:], sof: UInt8?, sampling: [Int] = []
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1], length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if marker == 0xDB {
                var j = i + 4
                while j < i + 2 + length {
                    let id = Int(b[j] & 15)
                    var natural = [Int](repeating: 0, count: 64)
                    for k in 0..<64 { natural[zigzag[k]] = Int(b[j + 1 + k]) }
                    tables[id] = natural
                    j += 65
                }
            } else if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                sof = marker
                let n = Int(b[i + 9])
                sampling = (0..<n).map { Int(b[i + 11 + 3 * $0]) }
            } else if marker == 0xDA { break }
            i += 2 + length
        }
        return (tables, sof, sampling)
    }

    static let annexKLuma = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
                             14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
                             49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
    static let annexKChroma = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
                               47, 66, 99, 99, 99, 99, 99, 99] + [Int](repeating: 99, count: 32)

    @Test func standardTablesAreAnnexKScaledFromTheDistance() throws {
        let image = Synthetic.image(.blocks, width: 333, height: 201)
        // jpegli scales the standard tables linearly: 22.22 × (d − 0.1) %, so d = 4.6 is the tables themselves.
        var knobs = JPEGKnobs(distance: 4.6, sampling: .s444, adaptiveQuantization: false)
        knobs.standardTables = true
        let s = Self.structure(try JpegliEncoder().encode(image, knobs: knobs, markers: []))
        #expect(s.tables.count == 2)
        #expect(s.tables[0] == Self.annexKLuma)
        #expect(s.tables[1] == Self.annexKChroma)
        #expect(s.sof == 0xC2)
        #expect(s.sampling == [0x11, 0x11, 0x11])
        // Half the scale: every entry halved (rounded), never below 1.
        knobs.distance = 0.1 + 50 / (200.0 / 9)
        let half = Self.structure(try JpegliEncoder().encode(image, knobs: knobs, markers: []))
        #expect(half.tables[0] == Self.annexKLuma.map { max(1, Int((Double($0) * 0.5).rounded())) })
    }

    @Test func sequentialIsBaselineAndScoringOnlyKeepsIt() throws {
        let image = Synthetic.image(.blocks, width: 333, height: 201)
        var knobs = JPEGTuning.highTarget.knobs(distance: 0.5, subsampling: .s444)
        let progressive = try JpegliEncoder().encode(image, knobs: knobs, markers: [])
        knobs.sequential = true
        let sequential = try JpegliEncoder().encode(image, knobs: knobs, markers: [])
        knobs.scoringOnly = true                              // a scoring-only candidate keeps the delivered mode
        let scoring = try JpegliEncoder().encode(image, knobs: knobs, markers: [])
        #expect(Self.structure(progressive).sof == 0xC2)
        #expect(Self.structure(sequential).sof == 0xC0)
        #expect(scoring == sequential)
        #expect(Self.structure(progressive).tables == Self.structure(sequential).tables)
        // (Same coefficients, but ImageIO decodes the two modes differently: research F4 — hence the scoring-only rule.)
    }

    @Test func highTuningIsTheFullSizeShapeWithoutAdaptiveQuantisation() {
        let high = JPEGTuning.highTarget, full = JPEGTuning.fullSize
        #expect(high.chromaRatio == full.chromaRatio && high.lumaTilt == full.lumaTilt && high.dcRatio == full.dcRatio)
        #expect(!high.adaptiveQuantization && full.adaptiveQuantization)
        #expect(!high.standardTables && !high.sequential)
        #expect(JPEGTuning.annexK.standardTables && !JPEGTuning.annexK.adaptiveQuantization)
        // The existing tunings are unchanged by the new fields.
        #expect(!full.standardTables && !full.sequential && !JPEGTuning.resized.standardTables)
    }
}
