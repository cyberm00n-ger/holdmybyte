// WP1 acceptance 6: ImageIO decoder (determinism, fidelity) and header inspection (CMYK, arithmetic, holdmybyte COM).
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBFixtures
import HMBModel
import ImageIO
import Testing

@Suite struct DecoderTests {
    let decoder = ImageIODecoder()

    @Test func inspectsTheFixtures() throws {
        let gradient = try decoder.inspect(TestFixtureFiles.gradientSRGB)
        #expect(gradient.kind == .jpeg && gradient.orientation == 1 && !gradient.isCMYK && !gradient.isArithmeticCoded)
        #expect(!gradient.isHoldMyByteOutput)
        #expect(gradient.estimatedJPEGQuality.map { (80...100).contains($0) } == true)

        let p3 = try decoder.inspect(TestFixtureFiles.rampsP3)
        let icc = try #require(p3.iccProfile)
        #expect(CGColorSpace(iccData: icc as CFData) != nil)
        #expect(p3.markers.contains { $0.code == 0xE2 })

        #expect(try decoder.inspect(TestFixtureFiles.orientation6).orientation == 6)
        #expect(try decoder.inspect(TestFixtureFiles.patternPNG).kind == .png)

        let cmyk = try decoder.inspect(TestFixtureFiles.cmyk)
        #expect(cmyk.isCMYK && !cmyk.isArithmeticCoded)
        let arithmetic = try decoder.inspect(TestFixtureFiles.arithmetic)
        #expect(arithmetic.isArithmeticCoded && !arithmetic.isCMYK)
        let ours = try decoder.inspect(TestFixtureFiles.holdMyByteOutput)
        #expect(ours.isHoldMyByteOutput)
        #expect(ours.markers.contains { $0.code == 0xFE })
    }

    @Test func inspectRejectsGarbage() {
        #expect(throws: PrimitiveError.self) { try ImageIODecoder.inspect(data: Data("not an image at all".utf8)) }
        #expect(throws: PrimitiveError.self) { try ImageIODecoder.inspect(data: Data([0xFF, 0xD8, 0xFF, 0xE1, 0x40, 0x00, 0x01])) }
        #expect(throws: PrimitiveError.self) { try decoder.decode(encoded: Data([0xFF, 0xD8, 0xFF, 0xD9])) }
    }

    @Test func decodeKeepsStoredOrientationAndColourSpace() throws {
        let rotated = try decoder.decode(try decoder.inspect(TestFixtureFiles.orientation6))
        let imageSource = try #require(CGImageSourceCreateWithURL(TestFixtureFiles.orientation6 as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        #expect(rotated.width == props[kCGImagePropertyPixelWidth] as? Int)
        #expect(rotated.height == props[kCGImagePropertyPixelHeight] as? Int)
        let p3 = try decoder.decode(try decoder.inspect(TestFixtureFiles.rampsP3))
        #expect(!VImageProcessing.isSRGB(p3.colorSpace))
        let png = try decoder.decode(try decoder.inspect(TestFixtureFiles.patternPNG))
        #expect(png.width == 512 && png.height == 512)
        // Opaque: every X byte is 255.
        for y in stride(from: 0, to: png.height, by: 7) {
            for x in stride(from: 0, to: png.width, by: 5) { #expect(png.bytes[y * png.bytesPerRow + x * 4 + 3] == 255) }
        }
        let cmyk = try decoder.decode(try decoder.inspect(TestFixtureFiles.cmyk))
        #expect(cmyk.colorSpace.model == .rgb)
    }

    @Test func repeatedDecodesArePixelIdentical() throws {
        var files = [TestFixtureFiles.gradientSRGB, TestFixtureFiles.rampsP3, TestFixtureFiles.patternPNG, TestFixtureFiles.mosaicSource]
        if let sample = LocalData.samplePhotos.first { files.append(sample) }
        for url in files {
            let info = try decoder.inspect(url)
            let first = try decoder.decode(info)
            for _ in 0..<2 { #expect(Measure.identical(first, try decoder.decode(info)), "\(url.lastPathComponent)") }
        }
    }

    @Test func jpegliAtHalfDistanceDecodesFaithfully() throws {
        // Smooth synthetic content: the integer gradient and the soft-shape fixture (gradient-srgb.jpg), both subsamplings.
        let images = [("gradient", Synthetic.image(.gradient, width: 320, height: 240)),
                      ("gradient-srgb.jpg", try decoder.decode(try decoder.inspect(TestFixtureFiles.gradientSRGB)))]
        for (name, image) in images {
            for subsampling in [ChromaSubsampling.s444, .s420] {
                let decoded = try decoder.decode(encoded: try JpegliEncoder().encode(image, distance: 0.5, subsampling: subsampling, markers: []))
                let psnr = Measure.psnr(image, decoded)
                #expect(psnr >= 40, "\(name) \(subsampling.rawValue): PSNR \(psnr)")
            }
        }
        // Noise, sawtooth chroma and hard high-chroma edges are the worst case for any DCT codec; still faithful.
        for kind in [Synthetic.Kind.noise, .blocks, .waves] {
            let image = Synthetic.image(kind, width: 320, height: 240)
            let decoded = try decoder.decode(encoded: try JpegliEncoder().encode(image, distance: 0.5, subsampling: .s444, markers: []))
            #expect(Measure.psnr(image, decoded) >= 30, "\(kind)")
        }
    }

    @Test func qualityEstimateFollowsTheIJGScale() {
        // A DQT with the standard luma table scaled to quality 75 (scale 50 %).
        var dqt = Data([0x00])
        dqt.append(contentsOf: JPEGInspector.standardLuma.map { UInt8(max(1, ($0 * 50 + 50) / 100)) })
        #expect(JPEGInspector.estimateQuality(dqt: dqt) == 75)
        var q95 = Data([0x00])
        q95.append(contentsOf: JPEGInspector.standardLuma.map { UInt8(max(1, ($0 * 10 + 50) / 100)) })
        #expect(JPEGInspector.estimateQuality(dqt: q95).map { (94...96).contains($0) } == true)
    }
}
