// WP0: the deterministic fakes behind `EnginePrimitives.fakes()` and the codec link check.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBFixtures
import HMBModel
import Testing

@Suite struct FakePrimitivesTests {
    let fakes = EnginePrimitives.fakes()

    /// Smooth gradient plus a little texture, deterministic.
    static func sample(width: Int = 96, height: Int = 64) -> PixelImage {
        let image = PixelImage(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let base = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * image.bytesPerRow + x * 4
                p[0] = UInt8((x * 255) / max(1, width - 1))
                p[1] = UInt8((y * 255) / max(1, height - 1))
                p[2] = UInt8(((x ^ y) & 15) * 8 + 64)
                p[3] = 255
            }
        }
        return image
    }

    @Test func pixelImageLayout() {
        let image = PixelImage(width: 17, height: 3, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        #expect(image.bytesPerRow == 128)          // 17 × 4 = 68, rounded up to 64
        #expect(image.pixelCount == 51)
        #expect(image.pixels.allSatisfy { $0 == 0 })
        #expect(Int(bitPattern: image.pixels.baseAddress) % 64 == 0)
    }

    @Test func jpegFakeIsLossyDeterministicAndMonotone() throws {
        let image = Self.sample()
        let reference = try fakes.metric.prepareReference(image)
        var lastSize = Int.max, lastScore = 101.0
        for distance in [0.0, 0.5, 1.0, 2.0, 4.0, 8.0] {
            let a = try fakes.jpeg.encode(image, distance: distance, subsampling: .s420, markers: [])
            let b = try fakes.jpeg.encode(image, distance: distance, subsampling: .s420, markers: [])
            #expect(a == b)
            let decoded = try fakes.decoder.decode(encoded: a)
            let score = try fakes.metric.score(decoded, against: reference)
            #expect(a.count <= lastSize)
            #expect(score <= lastScore)
            lastSize = a.count; lastScore = score
        }
        let lossless = try fakes.decoder.decode(encoded: try fakes.jpeg.encode(image, distance: 0, subsampling: .s420, markers: []))
        #expect(try fakes.metric.score(lossless, against: reference) == 100)
        #expect(FakeJPEGEncoder.step(distance: 1.6) == 6)
        let s444 = try fakes.jpeg.encode(image, distance: 1.6, subsampling: .s444, markers: [])
        let s420 = try fakes.jpeg.encode(image, distance: 1.6, subsampling: .s420, markers: [])
        #expect(s444.count > s420.count)
    }

    @Test func markersAndMetadataSurvive() throws {
        let image = Self.sample(width: 8, height: 8)
        let markers = [JPEGMarker(code: 0xE1, payload: Data("Exif\0\0MM".utf8)), JPEGMarker(code: 0xFE, payload: Data("holdmybyte".utf8))]
        let jpeg = try fakes.jpeg.encode(image, distance: 1, subsampling: .s420, markers: markers)
        let decoded = try FakeCodecContainer.decode(jpeg)
        #expect(decoded.metadata.map(\.code) == [0xE1, 0xFE])
        #expect(decoded.metadata.map(\.payload) == markers.map(\.payload))

        let prepared = try fakes.webp.prepare(image)
        let webp = try fakes.webp.encode(prepared, quality: 70, icc: Data([1]), exif: nil, xmp: Data([3, 3]))
        let decodedWebP = try FakeCodecContainer.decode(webp)
        #expect(decodedWebP.metadata.map(\.code) == [FakeWebPEncoder.iccCode, FakeWebPEncoder.xmpCode])
        #expect(decodedWebP.step == 4)              // (100 − 70) / 8 = 3.75 → 4
        #expect(try fakes.webp.encode(prepared, quality: 90, icc: nil, exif: nil, xmp: nil).count
                >= (try fakes.webp.encode(prepared, quality: 50, icc: nil, exif: nil, xmp: nil)).count)
    }

    @Test func metricIs100Minus2point5RMSE() throws {
        let a = Self.sample(width: 4, height: 4)
        let b = PixelImage(width: 4, height: 4, colorSpace: a.colorSpace)
        b.pixels.copyMemory(from: UnsafeRawBufferPointer(a.pixels))
        let pb = b.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<4 {
            for x in 0..<4 {
                let g = pb[y * b.bytesPerRow + x * 4 + 1]
                pb[y * b.bytesPerRow + x * 4 + 1] = g >= 6 ? g - 6 : g + 6
            }
        }
        // Only G changes, by ±6 in every pixel: RMSE over R, G, B = sqrt(36 / 3).
        let reference = try fakes.metric.prepareReference(a)
        let score = try fakes.metric.score(b, against: reference)
        #expect(abs(score - (100 - 2.5 * (12.0).squareRoot())) < 1e-9)
        #expect(throws: PrimitiveError.self) { try fakes.metric.score(Self.sample(width: 5, height: 4), against: reference) }
        fakes.metric.release(reference)
    }

    @Test func jxlFakeIsIdentityWithMagic() throws {
        let jpeg = try Data(contentsOf: TestFixtureFiles.gradientSRGB)
        let jxl = try fakes.jxl.transcodeLossless(jpeg: jpeg, effort: 7)
        #expect(jxl.prefix(4) == Data("HMBX".utf8))
        #expect(jxl.count == jpeg.count + 4)
        #expect(try fakes.jxl.reconstructJPEG(jxl: jxl) == jpeg)
        #expect(throws: PrimitiveError.self) { try fakes.jxl.reconstructJPEG(jxl: jpeg) }
    }

    @Test func processing() throws {
        let image = Self.sample(width: 300, height: 200)
        let small = fakes.processing.resized(image, longEdge: 150)
        #expect(small.width == 150 && small.height == 100)
        #expect(fakes.processing.resized(image, longEdge: 600) === image)     // never upscales
        #expect(fakes.processing.mosaic(image) == nil)
        let big = PixelImage(width: 2400, height: 1600, colorSpace: image.colorSpace)
        let mosaic = try #require(fakes.processing.mosaic(big))
        #expect(mosaic.width == 2048 && mosaic.height == 1024)
        let features = fakes.processing.features(image)
        #expect(features.textureP50 > 0 && features.chromaEnergy > 0)
        #expect(fakes.processing.convertedToSRGB(image) === image)
    }

    @Test func decoderInspectsSyntheticFixtures() throws {
        let decoder = fakes.decoder
        let srgb = try decoder.inspect(TestFixtureFiles.gradientSRGB)
        #expect(srgb.kind == .jpeg && !srgb.isCMYK && !srgb.isArithmeticCoded && !srgb.isHoldMyByteOutput)
        #expect(srgb.markers.contains { $0.code == 0xE0 })
        #expect((1...100).contains(srgb.estimatedJPEGQuality ?? 0))
        let decoded = try decoder.decode(srgb)
        #expect(decoded.width == 640 && decoded.height == 427)

        #expect(try decoder.inspect(TestFixtureFiles.rampsP3).iccProfile != nil)
        #expect(try decoder.inspect(TestFixtureFiles.orientation6).orientation == 6)
        #expect(try decoder.inspect(TestFixtureFiles.cmyk).isCMYK)
        #expect(try decoder.inspect(TestFixtureFiles.arithmetic).isArithmeticCoded)
        #expect(try decoder.inspect(TestFixtureFiles.holdMyByteOutput).isHoldMyByteOutput)
        #expect(try decoder.inspect(TestFixtureFiles.patternPNG).kind == .png)
        for url in TestFixtureFiles.all {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            #expect(size <= 256 * 1024, "\(url.lastPathComponent) must stay ≤ 256 KB")
        }
    }

    @Test func codecArchiveIsLinked() {
        #expect(EnginePrimitives.codecVersions == "libjxl 0.11.2 · jpegli (libjxl 0.11.2) · libwebp 1.6.0")
    }
}
