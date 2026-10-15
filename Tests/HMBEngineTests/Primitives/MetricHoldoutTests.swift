// WP1 acceptance 3 (HMB_HOLDOUT): the new port reproduces the old engine's scores on the 19 holdout outputs.
//
// Two comparisons, because the old engine decoded its candidates with libjpeg-turbo while v2 decodes with ImageIO
// (§3.0 E6), and the two decoders differ (RMSE ≈ 0.43 on 45 MP 4:2:0 JPEGs):
//  A. same pixels as the old engine's own search (reference via ImageIO, candidate via libjpeg-turbo `djpeg`):
//     expectation `old-holdout-ownscores.txt` (printed with one decimal, so the tolerance is 0.05 + 0.05 rounding);
//  B. same pixels as the old `squeeze score` CLI (both via ImageIO): expectation the full-precision old-port scores
//     below (`squeeze score holdout/X old-holdout/X`, measured 2026-10-15), tolerance 0.05.
// The v2 pipeline's own reading is B; the B − A shift is reported in Docs/METRIC.md.
import CoreGraphics
import Foundation
@testable import HMBEngine
import Testing

@Suite(.serialized) struct MetricHoldoutTests {
    static let djpeg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HMB_DJPEG"] ?? "/opt/homebrew/opt/jpeg-turbo/bin/djpeg")

    /// Old port (jpegos MetalSSIMULACRA2), both images decoded by ImageIO: `squeeze score` output.
    static let oldPortImageIO: [String: Double] = [
        "SH_Wedding_Lissy_Finn0014.jpg": 73.76932731, "SH_Wedding_Lissy_Finn0042.jpg": 75.03328668,
        "SH_Wedding_Lissy_Finn0070.jpg": 74.04904694, "SH_Wedding_Lissy_Finn0098.jpg": 74.33147125,
        "SH_Wedding_Lissy_Finn0126.jpg": 74.37944360, "SH_Wedding_Lissy_Finn0154.jpg": 74.15318805,
        "SH_Wedding_Lissy_Finn0182.jpg": 74.47129586, "SH_Wedding_Lissy_Finn0210.jpg": 74.03606057,
        "SH_Wedding_Lissy_Finn0238.jpg": 74.00188426, "SH_Wedding_Lissy_Finn0266.jpg": 74.12875239,
        "SH_Wedding_Lissy_Finn0294.jpg": 74.09523739, "SH_Wedding_Lissy_Finn0322.jpg": 74.33537619,
        "SH_Wedding_Lissy_Finn0350.jpg": 74.12124780, "SH_Wedding_Lissy_Finn0378.jpg": 74.51176256,
        "SH_Wedding_Lissy_Finn0406.jpg": 73.87549012, "SH_Wedding_Lissy_Finn0434.jpg": 73.83971234,
        "SH_Wedding_Lissy_Finn0462.jpg": 73.97416322, "SH_Wedding_Lissy_Finn0490.jpg": 73.99790130,
        "SH_Wedding_Lissy_Finn0518.jpg": 74.30135419,
    ]

    static func ownScores(_ holdout: URL) throws -> [String: Double] {
        let file = holdout.deletingLastPathComponent().appending(path: "old-holdout-ownscores.txt")
        var result: [String: Double] = [:]
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let value = Double(parts[1]) { result[String(parts[0])] = value }
        }
        return result
    }

    /// libjpeg-turbo decode (djpeg: ISLOW DCT, fancy upsampling, like the old engine's `sq_jpeg_decode`) via PPM.
    static func turboDecode(_ url: URL, scratch: URL) throws -> PixelImage {
        let ppm = scratch.appending(path: url.deletingPathExtension().lastPathComponent + ".ppm")
        let process = Process()
        process.executableURL = djpeg
        process.arguments = ["-outfile", ppm.path, url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PrimitiveError("djpeg failed on \(url.lastPathComponent)") }
        defer { try? FileManager.default.removeItem(at: ppm) }
        let data = try Data(contentsOf: ppm)
        // "P6\n<w> <h>\n255\n" then RGB.
        var fields: [Int] = [], index = 2, current = ""
        while fields.count < 3 {
            let byte = data[index]; index += 1
            if byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D {
                if !current.isEmpty { fields.append(Int(current)!); current = "" }
            } else { current.append(Character(UnicodeScalar(byte))) }
        }
        let (width, height) = (fields[0], fields[1])
        let image = PixelImage(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let base = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        data.withUnsafeBytes { raw in
            let rgb = raw.bindMemory(to: UInt8.self).baseAddress! + index
            for y in 0..<height {
                let row = base + y * image.bytesPerRow, src = rgb + y * width * 3
                for x in 0..<width { row[x * 4] = src[x * 3]; row[x * 4 + 1] = src[x * 3 + 1]; row[x * 4 + 2] = src[x * 3 + 2]; row[x * 4 + 3] = 255 }
            }
        }
        return image
    }

    @Test(.enabled(if: LocalData.hasHoldout))
    func newPortMatchesOldEngineOnHoldout() throws {
        let holdout = try #require(LocalData.holdout)
        let outputs = holdout.deletingLastPathComponent().appending(path: "old-holdout", directoryHint: .isDirectory)
        let own = try Self.ownScores(holdout)
        let metal = try MetalSSIMULACRA2()
        let decoder = ImageIODecoder()
        let haveTurbo = FileManager.default.isExecutableFile(atPath: Self.djpeg.path)
        let scratch = try LocalData.scratchDirectory("holdout")
        defer { try? FileManager.default.removeItem(at: scratch) }
        print("[holdout] \(LocalData.loadAverage()); djpeg \(haveTurbo ? "present" : "missing")")
        var shifts: [Double] = []
        for name in own.keys.sorted() {
            let reference = try decoder.decode(try decoder.inspect(holdout.appending(path: name)))
            let session = try metal.prepareReference(reference)
            defer { metal.release(session) }
            let output = outputs.appending(path: name)
            let viaImageIO = try metal.score(try decoder.decode(try decoder.inspect(output)), against: session)
            let expectedB = try #require(Self.oldPortImageIO[name])
            var line = String(format: "[holdout] %@ B(ImageIO) %.5f old %.5f Δ %+.5f", name, viaImageIO, expectedB, viaImageIO - expectedB)
            #expect(abs(viaImageIO - expectedB) <= 0.05, "\(name): ImageIO path \(viaImageIO) vs old port \(expectedB)")
            if haveTurbo {
                let viaTurbo = try metal.score(try Self.turboDecode(output, scratch: scratch), against: session)
                let expectedA = own[name]!
                line += String(format: " | A(turbo) %.5f own %.1f Δ %+.5f | B−A %+.4f", viaTurbo, expectedA, viaTurbo - expectedA, viaImageIO - viaTurbo)
                shifts.append(viaImageIO - viaTurbo)
                #expect(abs(viaTurbo - expectedA) <= 0.10, "\(name): turbo path \(viaTurbo) vs own score \(expectedA)")
            }
            print(line)
        }
        if !shifts.isEmpty {
            print(String(format: "[holdout] decoder shift ImageIO − libjpeg-turbo: mean %+.3f, min %+.3f, max %+.3f",
                         shifts.reduce(0, +) / Double(shifts.count), shifts.min()!, shifts.max()!))
        }
    }
}
