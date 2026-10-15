// WP1 acceptance 5: features (port of the old GrainEstimator), resize, sRGB conversion, mosaic.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBFixtures
import Testing

@Suite struct ImagingTests {
    let processing = VImageProcessing()

    /// Computed once by running jpegos/Sources/SqueezeCore/GrainEstimator.swift (statistics(of:).p50 and
    /// chromaEnergy(of:)) on `Synthetic.rgba` (2026-10-15).
    static let expectedFeatures: [(Synthetic.Kind, Int, Int, Double, Double)] = [
        (.gradient, 320, 240, 0.072039062499999987, 1.2906249999999999),
        (.gradient, 333, 201, 0.11006054687500016, 1.263855421686747),
        (.gradient, 1031, 517, 0.14674999999999816, 0.56198534069314998),
        (.noise, 320, 240, 5.8439062500000007, 27.737291666666668),
        (.noise, 333, 201, 5.8099941406250002, 27.696144578313252),
        (.noise, 1031, 517, 5.7963085937499983, 27.964618586553254),
        (.blocks, 320, 240, 5.153187500000004, 13.633333333333333),
        (.blocks, 333, 201, 5.5656562499999946, 13.116144578313254),
        (.blocks, 1031, 517, 5.373875, 16.562724338672215),
        (.waves, 320, 240, 4.6167646484374991, 8.5338541666666661),
        (.waves, 333, 201, 4.4127050781250041, 8.8518072289156624),
        (.waves, 1031, 517, 6.8097490234375062, 27.708367266914006),
    ]

    @Test func featuresMatchOldGrainEstimator() {
        for (kind, width, height, p50, chroma) in Self.expectedFeatures {
            let features = processing.features(Synthetic.image(kind, width: width, height: height))
            #expect(abs(features.textureP50 - p50) <= 1e-6, "\(kind) \(width)×\(height) p50 \(features.textureP50) vs \(p50)")
            #expect(abs(features.chromaEnergy - chroma) <= 1e-6, "\(kind) \(width)×\(height) chroma \(features.chromaEnergy) vs \(chroma)")
        }
    }

    @Test func featuresOfTinyImagesAreZero() {
        let features = processing.features(Synthetic.image(.noise, width: 20, height: 20))
        #expect(features.textureP50 == 0 && features.chromaEnergy == 0)
    }

    @Test func resizeNeverUpscales() {
        let image = Synthetic.image(.waves, width: 640, height: 480)
        #expect(processing.resized(image, longEdge: 640) === image)
        #expect(processing.resized(image, longEdge: 4000) === image)
        let landscape = processing.resized(image, longEdge: 320)
        #expect(landscape.width == 320 && landscape.height == 240)
        #expect(landscape.colorSpace === image.colorSpace)
        let portrait = processing.resized(Synthetic.image(.waves, width: 333, height: 1000), longEdge: 400)
        #expect(portrait.height == 400 && portrait.width == 133)
        // Lanczos keeps a smooth gradient close to the box average.
        let gradient = Synthetic.image(.gradient, width: 1000, height: 500)
        let small = processing.resized(gradient, longEdge: 100)
        let p = small.bytes + 25 * small.bytesPerRow + 50 * 4
        #expect(abs(Int(p[0]) - 128) <= 3)
    }

    @Test func srgbToSRGBIsIdentity() throws {
        let image = Synthetic.image(.blocks, width: 333, height: 201)
        #expect(processing.convertedToSRGB(image) === image)
        // Forced through a real vImageConverter: still the identity within one code value.
        let converted = try VImageProcessing.convert(image, to: VImageProcessing.sRGB)
        var maxDelta = 0
        for y in 0..<image.height {
            for x in 0..<(image.width * 4) where x % 4 != 3 {
                maxDelta = max(maxDelta, abs(Int(image.bytes[y * image.bytesPerRow + x]) - Int(converted.bytes[y * converted.bytesPerRow + x])))
            }
        }
        #expect(maxDelta <= 1)
    }

    @Test func displayP3IsConvertedToSRGB() throws {
        let decoder = ImageIODecoder()
        let p3 = try decoder.decode(try decoder.inspect(TestFixtureFiles.rampsP3))
        #expect(p3.colorSpace.name == CGColorSpace.displayP3 || !VImageProcessing.isSRGB(p3.colorSpace))
        let converted = processing.convertedToSRGB(p3)
        #expect(converted !== p3)
        #expect(VImageProcessing.isSRGB(converted.colorSpace))
        #expect(converted.width == p3.width && converted.height == p3.height)
        // Saturated P3 colours are compressed into sRGB: the images differ, but not wildly.
        let psnr = Measure.psnr(p3, converted)
        #expect(psnr < 60 && psnr > 15)
    }

    @Test func mosaicLayout() throws {
        #expect(processing.mosaic(Synthetic.image(.waves, width: 2047, height: 1500)) == nil)
        #expect(processing.mosaic(Synthetic.image(.waves, width: 3000, height: 1023)) == nil)
        let origins = try #require(VImageProcessing.mosaicOrigins(width: 8256, height: 5504))
        #expect(origins.count == 32)
        // scripts/mosaic.py "grid": y = (r·h//4 + h//4//2 − 128)//16·16, x likewise with 8 columns.
        #expect(origins[0].x == 384 && origins[0].y == 560)
        #expect(origins[31].x == 7600 && origins[31].y == 4688)
        #expect(origins.allSatisfy { $0.x % 16 == 0 && $0.y % 16 == 0 })

        let decoder = ImageIODecoder()
        let source = try decoder.decode(try decoder.inspect(TestFixtureFiles.mosaicSource))
        let mosaic = try #require(processing.mosaic(source))
        #expect(mosaic.width == 2048 && mosaic.height == 1024)
        let tileOrigins = try #require(VImageProcessing.mosaicOrigins(width: source.width, height: source.height))
        for (index, origin) in tileOrigins.enumerated() {
            let mx = (index % 8) * 256 + 17, my = (index / 8) * 256 + 200
            let a = mosaic.bytes + my * mosaic.bytesPerRow + mx * 4
            let b = source.bytes + (origin.y + 200) * source.bytesPerRow + (origin.x + 17) * 4
            #expect(a[0] == b[0] && a[1] == b[1] && a[2] == b[2])
        }
    }
}
