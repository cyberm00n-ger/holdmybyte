// Decoder guard (Docs/DECISIONS.md D-ENG-12): `IslowDecoder` must give exactly libjpeg-turbo's pixels (djpeg default:
// ISLOW IDCT, fancy upsampling). Needs `djpeg` (test-only tool, HMB_DJPEG or PATH); skipped without it.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite struct IslowDecodeTests {
    static var haveDjpeg: Bool { ExternalDecode.djpeg != nil }
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func djpeg(_ data: Data) throws -> PixelImage {
        let scratch = try LocalData.scratchDirectory("islow")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "in.jpg")
        try data.write(to: file)
        return try ExternalDecode.ppm(ExternalDecode.run(ExternalDecode.djpeg!, ["-ppm", file.path]), space: sRGB)
    }

    static func islow(_ data: Data) throws -> PixelImage {
        let header = try ImageIODecoder().decode(encoded: data)
        return try #require(try IslowDecoder.decode(data, width: header.width, height: header.height, colorSpace: sRGB))
    }

    /// Every jpegli shape the engine writes (4:2:0 / 4:4:4, the three tunings, odd sizes down to a 1-sample-wide
    /// chroma plane, low and high distances) decodes to djpeg's pixels.
    @Test(.enabled(if: haveDjpeg)) func matchesDjpegOnJpegliOutputs() throws {
        let encoder = JpegliEncoder()
        var checked = 0
        for (width, height) in [(320, 240), (321, 239), (17, 9), (3, 5), (2, 2), (1, 1), (64, 1)] {
            for kind in Synthetic.Kind.allCases {
                let image = Synthetic.image(kind, width: width, height: height)
                for chroma in [ChromaSubsampling.s420, .s444] {
                    for tuning in [JPEGTuning.jpegli, .fullSize, .resized] {
                        for distance in [0.5, 2.0, 9.0] {
                            let data = try encoder.encode(image, distance: distance, subsampling: chroma, tuning: tuning, markers: [])
                            let ours = try Self.islow(data), theirs = try Self.djpeg(data)
                            #expect(Measure.identical(ours, theirs),
                                    "\(kind) \(width)×\(height) \(chroma.rawValue) d \(distance): PSNR \(Measure.psnr(ours, theirs))")
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 7 * 4 * 2 * 3 * 3)
    }

    /// Non-YCbCr layouts are declined (nil), never decoded wrongly.
    @Test func declinesUnsupportedLayouts() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures")
        let cmyk = try Data(contentsOf: fixtures.appending(path: "cmyk.jpg"))
        let info = try ImageIODecoder.inspect(data: cmyk)
        let image = try ImageIODecoder().decode(info)
        #expect(try IslowDecoder.decode(cmyk, width: image.width, height: image.height, colorSpace: Self.sRGB) == nil)
    }

    /// Real photos: the 6 samples (Lightroom baseline JPEGs) and their 4:2:0 / 4:4:4 jpegli encodes at full size.
    @Test(.enabled(if: haveDjpeg && LocalData.hasSamples)) func matchesDjpegOnSamples() throws {
        let decoder = ImageIODecoder(), encoder = JpegliEncoder()
        for url in LocalData.samplePhotos {
            let data = try Data(contentsOf: url)
            let source = try decoder.decode(encoded: data)
            #expect(Measure.identical(try Self.islow(data), try Self.djpeg(data)), "\(url.lastPathComponent)")
            for (chroma, tuning) in [(ChromaSubsampling.s420, JPEGTuning.fullSize), (.s444, .resized)] {
                let encoded = try encoder.encode(source, distance: 2.1, subsampling: chroma, tuning: tuning, markers: [])
                let start = monotonicSeconds()
                let ours = try #require(try IslowDecoder.decode(encoded, width: source.width, height: source.height, colorSpace: Self.sRGB))
                let seconds = monotonicSeconds() - start
                #expect(Measure.identical(ours, try Self.djpeg(encoded)), "\(url.lastPathComponent) \(chroma.rawValue)")
                print(String(format: "[islow] %@ %@ %d×%d: %.3f s", url.lastPathComponent,
                             chroma.rawValue, source.width, source.height, seconds))
            }
        }
    }
}
