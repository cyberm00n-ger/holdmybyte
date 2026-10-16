// Byte-identity guard for codec patches (Vendor/patches): SHA-256 of jpegli outputs over synthetic images, the sample
// photos and the search's distances, both chroma modes and both scan scripts, compared with a golden file written by
// the unpatched build. Opt-in:
//   HMB_ENCODER_GOLDEN=<file> HMB_ENCODER_GOLDEN_WRITE=1 swift test --filter EncoderGoldenTests   (unpatched codecs)
//   HMB_ENCODER_GOLDEN=<file> swift test --filter EncoderGoldenTests                              (patched codecs)
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite(.serialized) struct EncoderGoldenTests {
    static var goldenPath: String? { LocalData.env["HMB_ENCODER_GOLDEN"] }

    static func cases() throws -> [(String, PixelImage)] {
        var images: [(String, PixelImage)] = []
        for kind in Synthetic.Kind.allCases {
            for (w, h) in [(97, 61), (320, 240), (1031, 517)] {
                images.append(("\(kind.rawValue)-\(w)x\(h)", Synthetic.image(kind, width: w, height: h)))
            }
        }
        let decoder = ImageIODecoder(), processing = VImageProcessing()
        for (i, url) in LocalData.samplePhotos.enumerated() {
            let source = try decoder.decode(try decoder.inspect(url))
            images.append(("sample\(i)-1440", processing.resized(source, longEdge: 1440)))
            if let mosaic = processing.mosaic(source) { images.append(("sample\(i)-mosaic", mosaic)) }
            if i < 2 { images.append(("sample\(i)-full", source)) }
        }
        return images
    }

    @Test(.enabled(if: EncoderGoldenTests.goldenPath != nil))
    func jpegliOutputsMatchTheGoldenFile() throws {
        let path = try #require(Self.goldenPath)
        let encoder = JpegliEncoder()
        let marker = [JPEGMarker(code: 0xFE, payload: Data("golden".utf8))]
        var lines: [String] = []
        for (label, image) in try Self.cases() {
            let full = label.hasSuffix("-full")
            let distances = full ? [1.6, 2.0846] : [0.5, 1.0, 1.6, 2.0, 2.0846, 3.2, 6.0, 12.0]
            for chroma in [ChromaSubsampling.s420, .s444] {
                for d in distances {
                    let delivered = try encoder.encode(image, distance: d, subsampling: chroma, markers: marker)
                    lines.append("\(label) \(chroma) d\(d) p2 \(Measure.sha256(delivered))")
                    let proxy = try encoder.encodeForScoring(image, distance: d, subsampling: chroma)
                    lines.append("\(label) \(chroma) d\(d) proxy \(Measure.sha256(proxy))")
                }
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        if LocalData.env["HMB_ENCODER_GOLDEN_WRITE"] == "1" {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            print("[golden] wrote \(lines.count) hashes to \(path)")
            return
        }
        let golden = try String(contentsOfFile: path, encoding: .utf8)
        let expected = golden.split(separator: "\n").map(String.init)
        #expect(expected.count == lines.count)
        var differing = 0
        for (a, b) in zip(expected, lines) where a != b {
            differing += 1
            if differing <= 5 { Issue.record("differs: \(b) (golden \(a))") }
        }
        print("[golden] \(lines.count) outputs compared, \(differing) differ")
        #expect(differing == 0)
    }
}
