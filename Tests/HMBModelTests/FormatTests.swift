import Foundation
@testable import HMBModel
import Testing

@Suite struct HMBFormatTests {
    static let enUS = Locale(identifier: "en_US")
    static let enDE = Locale(identifier: "en_DE")
    static let nbsp = "\u{00A0}"

    // S8 status line, every row of the table.
    @Test func statusLineTable() {
        let f = { (done: Int, total: Int, eta: Double?, finishing: Bool) in
            HMBFormat.statusLine(done: done, total: total, etaSeconds: eta, finishing: finishing, locale: Self.enUS)
        }
        #expect(f(0, 535, nil, false) == "Starting…")
        #expect(f(12, 535, nil, false) == "12 of 535 photos · estimating time…")
        #expect(f(9, 535, 300, false) == "9 of 535 photos · estimating time…")          // fewer than 10 finished
        #expect(f(530, 535, 25, false) == "530 of 535 photos · less than a minute left")
        #expect(f(312, 535, 180, false) == "312 of 535 photos · about 3 min left")
        #expect(f(312, 1800, 4800, false) == "312 of 1,800 photos · about 1 h 20 min left")
        #expect(f(533, 535, 2, true) == "Finishing…")
    }

    @Test func statusLineBoundaries() {
        let f = { (eta: Double) in HMBFormat.statusLine(done: 100, total: 535, etaSeconds: eta, finishing: false, locale: Self.enUS) }
        #expect(f(59.9) == "100 of 535 photos · less than a minute left")
        #expect(f(60) == "100 of 535 photos · about 1 min left")
        #expect(f(3600) == "100 of 535 photos · about 60 min left")
        #expect(f(7200) == "100 of 535 photos · about 2 h left")
        #expect(HMBFormat.statusLine(done: 312, total: 1800, etaSeconds: 4800, finishing: false, locale: Self.enDE)
                == "312 of 1.800 photos · about 1 h 20 min left")
        // The verbatim API uses Locale.current.
        #expect(HMBFormat.statusLine(done: 0, total: 5, etaSeconds: nil, finishing: false) == "Starting…")
    }

    @Test func bytes() {
        #expect(HMBFormat.bytes(10_950_000_000, locale: Self.enUS) == "10.95 GB")
        #expect(HMBFormat.bytes(10_950_000_000, locale: Self.enDE) == "10,95 GB")
        #expect(HMBFormat.bytes(1_350_000_000, locale: Self.enUS) == "1.35 GB")
        #expect(HMBFormat.bytes(1_350_000_000, locale: Self.enDE) == "1,35 GB")
        #expect(HMBFormat.bytes(159_000_000, locale: Self.enUS) == "159 MB")
        #expect(HMBFormat.bytes(159_000_000, locale: Self.enDE) == "159 MB")
        #expect(HMBFormat.bytes(1_240_000_000_000, locale: Self.enUS) == "1.24 TB")
        #expect(HMBFormat.bytes(1_240_000_000_000, locale: Self.enDE) == "1,24 TB")
        #expect(!HMBFormat.bytes(0, locale: Self.enUS).lowercased().contains("zero"))
    }

    @Test func savedPercent() {
        #expect(HMBFormat.savedPercent(0.877, locale: Self.enUS) == "−88%")
        #expect(HMBFormat.savedPercent(0.877, locale: Self.enDE) == "−88\(Self.nbsp)%")
        #expect(HMBFormat.savedPercent(0.877, locale: Locale(identifier: "de_DE")) == "−88\(Self.nbsp)%")
        #expect(HMBFormat.savedPercent(0.221, locale: Self.enUS) == "−22%")
        #expect(HMBFormat.savedPercent(0.985, locale: Self.enDE) == "−99\(Self.nbsp)%")
        #expect(HMBFormat.savedPercent(-0.05, locale: Self.enUS) == "+5%")
        #expect(HMBFormat.savedPercent(0.004, locale: Self.enUS) == "0%")
        #expect(HMBFormat.savedPercent(0.5).hasPrefix("\u{2212}"))
    }

    @Test func score() {
        #expect(HMBFormat.score(85.44) == "85.4")
        #expect(HMBFormat.score(74) == "74.0")
        #expect(HMBFormat.score(76.25) == "76.2" || HMBFormat.score(76.25) == "76.3")
        #expect(HMBFormat.score(.nan) == "–")
    }

    @Test func duration() {
        #expect(HMBFormat.duration(38) == "38 s")
        #expect(HMBFormat.duration(0) == "0 s")
        #expect(HMBFormat.duration(252) == "4 min 12 s")
        #expect(HMBFormat.duration(240) == "4 min")
        #expect(HMBFormat.duration(4800) == "1 h 20 min")
        #expect(HMBFormat.duration(7200) == "2 h")
        #expect(HMBFormat.duration(59.6) == "1 min")
        #expect(HMBFormat.duration(-3) == "0 s")
    }

    @Test func folderName() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2026, month: 7, day: 12, hour: 14))!
        #expect(HMBFormat.folderName(pattern: "{wedding} – Deliveries", wedding: "Finn und Lissy", date: date) == "Finn und Lissy – Deliveries")
        #expect(HMBFormat.folderName(pattern: "{year} {wedding}", wedding: "Finn und Lissy", date: date) == "2026 Finn und Lissy")
        #expect(HMBFormat.folderName(pattern: "{date} {wedding}", wedding: "Finn und Lissy", date: date) == "2026-07-12 Finn und Lissy")
        #expect(HMBFormat.folderName(pattern: "{wedding} – {date}", wedding: "Finn und Lissy", date: nil) == "Finn und Lissy")
        #expect(HMBFormat.folderName(pattern: "{year}", wedding: "Finn und Lissy", date: nil) == "Finn und Lissy")
        #expect(HMBFormat.folderName(pattern: "{wedding}/out:put", wedding: "A", date: nil) == "A-out-put")
    }

    @Test func fileName() {
        #expect(HMBFormat.fileName(pattern: "{wedding}-{number}", wedding: "Finn und Lissy", number: 1, count: 535, ext: "jpg")
                == "Finn-und-Lissy-0001.jpg")
        #expect(HMBFormat.fileName(pattern: "{wedding}-{number}", wedding: "Finn und Lissy", number: 535, count: 535, ext: "jpg")
                == "Finn-und-Lissy-0535.jpg")
        #expect(HMBFormat.fileName(pattern: "{wedding}-{number}", wedding: "Big", number: 7, count: 12_000, ext: "webp")
                == "Big-00007.webp")
        #expect(HMBFormat.fileName(pattern: "{number}", wedding: "x", number: 42, count: 50, ext: "jxl") == "0042.jxl")
    }
}
