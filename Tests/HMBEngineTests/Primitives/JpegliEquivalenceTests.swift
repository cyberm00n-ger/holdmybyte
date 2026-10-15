// WP1 acceptance 2 (§3.13): in-process jpegli (libjxl v0.11.2) vs jpegos/Vendor/bin/cjpegli (google/jpegli, used in
// every experiment) at d ∈ {1.6, 2.0}, 4:2:0, progressive level 2, on the 6 sample photos: sizes within ±1.0 %,
// scores within ±0.2. Both encoders get the same pixels (the ImageIO decode, written as PPM for cjpegli).
import CoreGraphics
import Foundation
@testable import HMBEngine
import Testing

@Suite(.serialized) struct JpegliEquivalenceTests {
    static func writePPM(_ image: PixelImage, to url: URL) throws {
        var data = Data("P6\n\(image.width) \(image.height)\n255\n".utf8)
        var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for y in 0..<image.height {
            let row = image.bytes + y * image.bytesPerRow
            for x in 0..<image.width {
                let o = (y * image.width + x) * 3
                rgb[o] = row[x * 4]; rgb[o + 1] = row[x * 4 + 1]; rgb[o + 2] = row[x * 4 + 2]
            }
        }
        data.append(contentsOf: rgb)
        try data.write(to: url)
    }

    @Test(.enabled(if: LocalData.hasSamples && FileManager.default.isExecutableFile(atPath: LocalData.cjpegli.path)))
    func inProcessJpegliMatchesCjpegli() throws {
        let decoder = ImageIODecoder()
        let metal = try MetalSSIMULACRA2()
        let scratch = try LocalData.scratchDirectory("equivalence")
        defer { try? FileManager.default.removeItem(at: scratch) }
        print("[jpegli-eq] \(EnginePrimitives.codecVersions) vs \(LocalData.cjpegli.path); \(LocalData.loadAverage())")
        var worstSize = 0.0, worstScore = 0.0
        for url in LocalData.samplePhotos {
            let source = try decoder.decode(try decoder.inspect(url))
            let ppm = scratch.appending(path: "source.ppm")
            try Self.writePPM(source, to: ppm)
            let session = try metal.prepareReference(source)
            defer { metal.release(session) }
            for distance in [1.6, 2.0] {
                let ours = try JpegliEncoder().encode(source, distance: distance, subsampling: .s420, markers: [])
                let output = scratch.appending(path: "cjpegli.jpg")
                let process = Process()
                process.executableURL = LocalData.cjpegli
                process.arguments = [ppm.path, output.path, "-d", String(format: "%.4f", distance),
                                     "--chroma_subsampling=420", "-p", "2", "--quiet"]
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
                let theirs = try Data(contentsOf: output)
                let ourScore = try metal.score(try decoder.decode(encoded: ours), against: session)
                let theirScore = try metal.score(try decoder.decode(encoded: theirs), against: session)
                let sizeDelta = Double(ours.count) / Double(theirs.count) - 1
                worstSize = max(worstSize, abs(sizeDelta)); worstScore = max(worstScore, abs(ourScore - theirScore))
                print(String(format: "[jpegli-eq] %@ d%.1f: in-process %d B %.3f | cjpegli %d B %.3f | size %+.3f %% score %+.3f | byte-identical %@",
                             url.lastPathComponent, distance, ours.count, ourScore, theirs.count, theirScore,
                             sizeDelta * 100, ourScore - theirScore, ours == theirs ? "yes" : "no"))
                #expect(abs(sizeDelta) <= 0.01, "\(url.lastPathComponent) d\(distance): size \(sizeDelta * 100) %")
                #expect(abs(ourScore - theirScore) <= 0.2, "\(url.lastPathComponent) d\(distance): score \(ourScore - theirScore)")
            }
        }
        print(String(format: "[jpegli-eq] worst size %.3f %%, worst score %.3f", worstSize * 100, worstScore))
    }
}
