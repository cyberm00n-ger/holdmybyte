// Acceptance §5.2.9: scanner rules, notices, capture order and throughput.
import Foundation
@testable import HMBEngine
import HMBFixtures
import HMBModel
import Testing

/// 1-minute load average (timing assertions only run on a reasonably quiet machine).
func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : 0
}

@Suite struct ScannerTests {
    @Test func rulesNoticesAndCaptureOrder() async throws {
        let dir = TempDir("scan")
        let root = dir.sub("Finn und Lissy/fertig")
        // Out of path order on purpose; IMG_10 and IMG_2 share a timestamp (path order decides, numerically).
        Synth.jpeg(at: root.appending(path: "IMG_10.jpg"), seed: 1, date: "2026:07:12 15:00:00", model: "ILCE-7RM5")
        Synth.jpeg(at: root.appending(path: "IMG_2.jpg"), seed: 2, date: "2026:07:12 15:00:00", model: "ILCE-7RM5")
        Synth.jpeg(at: root.appending(path: "a-first.jpg"), seed: 3, date: "2026:07:12 11:00:00", model: "ILCE-7RM5")
        Synth.jpeg(at: dir.sub("Finn und Lissy/fertig/Reception").appending(path: "late.jpeg"), seed: 4,
                   date: "2026:07:12 23:59:59", model: "Z9")
        Synth.jpeg(at: root.appending(path: "undated.jpg"), seed: 5)
        Synth.write(Synth.cgImage(width: 40, height: 30, seed: 6), to: root.appending(path: "scan.png"), type: .png)
        try FileManager.default.copyItem(at: TestFixtureFiles.cmyk, to: root.appending(path: "cmyk.jpg"))
        try FileManager.default.copyItem(at: TestFixtureFiles.holdMyByteOutput, to: root.appending(path: "again.jpg"))
        for raw in ["A.CR3", "B.nef", "C.ARW"] { try Data([0]).write(to: root.appending(path: raw)) }
        for other in ["A.xmp", "clip.MOV", "notes.txt"] { try Data([0]).write(to: root.appending(path: other)) }
        try Data([0]).write(to: root.appending(path: ".DS_Store"))
        // Skipped folders: a nested deliveries folder, a partial folder, a package, a hidden folder and a symlink.
        Synth.jpeg(at: dir.sub("Finn und Lissy/fertig/Finn und Lissy \u{2013} Deliveries/Couple").appending(path: "out.jpg"))
        Synth.jpeg(at: dir.sub("Finn und Lissy/fertig/Couple/.holdmybyte-partial").appending(path: "x.jpg"))
        Synth.jpeg(at: dir.sub("Finn und Lissy/fertig/Viewer.app").appending(path: "icon.jpg"))
        Synth.jpeg(at: dir.sub("Finn und Lissy/fertig/.hidden").appending(path: "h.jpg"))
        let elsewhere = dir.sub("elsewhere")
        Synth.jpeg(at: elsewhere.appending(path: "linked.jpg"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.jpg"), withDestinationURL: elsewhere.appending(path: "linked.jpg"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linkdir"), withDestinationURL: elsewhere)

        let engine = fakeEngine(dir)
        var updates: [ScanUpdate] = []
        for try await u in engine.scan([root]) { updates.append(u) }
        let finished = updates.compactMap { if case .finished(let r) = $0 { r } else { nil } }
        #expect(finished.count == 1)
        guard case .finished = updates.last else { Issue.record("finished must be last"); return }
        let result = try #require(finished.first)

        #expect(result.suggestedName == "Finn und Lissy")
        #expect(result.sourceRoots == [root.standardizedFileURL])
        #expect(result.rawCount == 3)
        #expect(result.photos.map(\.relativePath) == ["a-first.jpg", "IMG_2.jpg", "IMG_10.jpg", "Reception/late.jpeg",
                                                      "again.jpg", "cmyk.jpg", "scan.png", "undated.jpg"])
        #expect(result.photos.map(\.id.index) == Array(0..<8))
        #expect(result.camera == "ILCE-7RM5")
        #expect(result.weddingDate == result.photos[0].captureDate)
        #expect(result.photos[0].pixelWidth == 120 && result.photos[0].pixelHeight == 80)
        #expect(result.photos.first { $0.relativePath == "scan.png" }?.kind == .png)
        #expect(result.totalBytes == result.photos.reduce(0) { $0 + $1.byteCount })
        #expect(result.notices.contains(.skippedRaw(count: 3)))
        #expect(result.notices.contains(.skippedNonPhotos(count: 3, extensions: ["MOV", "TXT", "XMP"])))
        #expect(result.notices.contains(.cmyk(count: 1)))
        #expect(result.notices.contains(.holdMyByteOutput(count: 1)))
        #expect(result.notices.contains(.convertedToJPEG(count: 1)))
    }

    @Test func alreadyCompressedNoticeAndLooseFiles() async throws {
        let dir = TempDir("scan2")
        let root = dir.sub("Export")
        var files: [URL] = []
        for i in 0..<5 {
            let url = root.appending(path: "p\(i).jpg")
            Synth.jpeg(at: url, seed: UInt32(i), quality: i < 2 ? 0.5 : 0.97)    // 2 of 5 > 20 %
            files.append(url)
        }
        let result = Scanner().scan(files) { _ in }
        #expect(result.notices.contains(.alreadyCompressed(count: 2, of: 5)))
        #expect(result.sourceRoots == [root.standardizedFileURL])
        #expect(result.suggestedName == dir.url.lastPathComponent)     // "Export" is generic → parent
        #expect(result.photos.count == 5)
    }

    @Test func droppedDeliveriesFolderIsScannedAndFlagged() throws {
        let dir = TempDir("scan3")
        let deliveries = dir.sub("Finn und Lissy \u{2013} Deliveries/Couple")
        try FileManager.default.copyItem(at: TestFixtureFiles.holdMyByteOutput, to: deliveries.appending(path: "x.jpg"))
        let result = Scanner().scan([deliveries.deletingLastPathComponent()]) { _ in }
        #expect(result.photos.count == 1)
        #expect(result.notices.contains(.holdMyByteOutput(count: 1)))
    }

    @Test func exifDateParsing() {
        let utc = Scanner.parseEXIFDate("2026:07:12 14:03:22", offset: "+02:00", subseconds: "45")
        #expect(utc == Date(timeIntervalSince1970: 1_783_857_802.45))
        #expect(Scanner.parseEXIFDate("0000:00:00 00:00:00", offset: nil, subseconds: nil) == nil)
    }

    @Test func throughputOnTwoThousandTinyJPEGs() throws {
        let dir = TempDir("scanperf")
        let template = dir.url.appending(path: "t.jpg")
        Synth.jpeg(at: template, width: 16, height: 16, date: "2026:07:12 12:00:00", model: "X")
        let bytes = try Data(contentsOf: template)
        for folder in 0..<20 {
            let sub = dir.sub("set/\(folder)")
            for i in 0..<100 { try bytes.write(to: sub.appending(path: "IMG_\(i).jpg")) }
        }
        let load = loadAverage()
        let start = monotonicSeconds()
        let result = Scanner().scan([dir.url.appending(path: "set")]) { _ in }
        let seconds = monotonicSeconds() - start
        let rate = Double(result.photos.count) / seconds
        print("scanner: \(result.photos.count) files in \(String(format: "%.3f", seconds)) s = \(Int(rate)) files/s (load \(String(format: "%.1f", load)))")
        #expect(result.photos.count == 2000)
        if load < 3 { #expect(rate >= 500) }          // §3.11: budgets hold on a quiet machine (1-minute load < 3)
    }
}
