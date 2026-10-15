// WP1 acceptance 1 and 7: codec round trips (JPEG, WebP, JXL), determinism, error paths, no leaks.
import CHMBCodecs
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBFixtures
import HMBModel
import Testing

@Suite struct CodecTests {
    let decoder = ImageIODecoder()
    let jpeg = JpegliEncoder()
    let webp = LibWebPEncoder()
    let jxl = LibJXLTranscoder()

    /// The 4 synthetic fixture images (decoded), plus the sample photos when HMB_TEST_PHOTOS is set.
    func images(includeSamples: Int = 6) throws -> [(String, PixelImage, SourceInfo)] {
        var urls = [TestFixtureFiles.gradientSRGB, TestFixtureFiles.rampsP3, TestFixtureFiles.patternPNG, TestFixtureFiles.mosaicSource]
        urls += LocalData.samplePhotos.prefix(includeSamples)
        return try urls.map { url in
            let info = try decoder.inspect(url)
            return (url.lastPathComponent, try decoder.decode(info), info)
        }
    }

    static func markers(icc: Data?) -> [JPEGMarker] {
        var exif = Data("Exif\u{0}\u{0}".utf8)
        exif.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00])    // empty big-endian TIFF
        var result = [JPEGMarker(code: 0xE1, payload: exif)]
        result.append(JPEGMarker(code: 0xE1, payload: Data("http://ns.adobe.com/xap/1.0/\u{0}<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)))
        if let icc {
            var payload = Data("ICC_PROFILE\u{0}".utf8)
            payload.append(contentsOf: [1, 1])
            payload.append(icc)
            result.append(JPEGMarker(code: 0xE2, payload: payload))
        }
        result.append(JPEGMarker(code: 0xED, payload: Data("Photoshop 3.0\u{0}".utf8)))
        result.append(JPEGMarker(code: 0xFE, payload: Data("holdmybyte 2.0".utf8)))
        return result
    }

    // MARK: JPEG

    @Test func jpegRoundTripKeepsSizeAndMarkerOrder() throws {
        for (name, image, info) in try images() {
            let markers = Self.markers(icc: info.iccProfile)
            for subsampling in [ChromaSubsampling.s420, .s444] {
                let bytes = try jpeg.encode(image, distance: 1.0, subsampling: subsampling, markers: markers)
                let decoded = try decoder.decode(encoded: bytes)
                #expect(decoded.width == image.width && decoded.height == image.height, "\(name)")
                let header = try JPEGInspector.scan(bytes)
                #expect(header.markers == markers, "\(name): markers must be exactly the given ones, in order")
                #expect(header.frameMarker == 0xC2, "\(name): progressive")
                #expect(header.isHoldMyByteOutput)
                let sampling = try Self.lumaSampling(bytes)
                #expect(sampling == (subsampling == .s420 ? 0x22 : 0x11), "\(name) \(subsampling.rawValue)")
                if let icc = info.iccProfile { #expect(header.iccProfile == icc) }
            }
        }
    }

    /// The luma component's sampling byte from the SOF.
    static func lumaSampling(_ jpeg: Data) throws -> UInt8 {
        let b = [UInt8](jpeg)
        var i = 2
        while i + 4 < b.count {
            let code = b[i + 1], length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xC2).contains(code) { return b[i + 11] }
            i += 2 + length
        }
        throw PrimitiveError("no SOF")
    }

    @Test func jpegIsDeterministicAndMonotone() throws {
        let image = Synthetic.image(.waves, width: 512, height: 384)
        let a = try jpeg.encode(image, distance: 1.6, subsampling: .s420, markers: [])
        let b = try jpeg.encode(image, distance: 1.6, subsampling: .s420, markers: [])
        #expect(a == b)
        var last = Int.max
        for distance in [0.5, 1.0, 2.0, 4.0, 8.0] {
            let size = try jpeg.encode(image, distance: distance, subsampling: .s420, markers: []).count
            #expect(size < last)
            last = size
        }
        #expect(try jpeg.encode(image, distance: 1.6, subsampling: .s444, markers: []).count > a.count)
    }

    @Test func jpegErrorPathsReturnMessages() throws {
        let image = Synthetic.image(.noise, width: 64, height: 64)
        #expect(throws: PrimitiveError.self) { try jpeg.encode(image, distance: -1, subsampling: .s420, markers: []) }
        #expect(throws: PrimitiveError.self) { try jpeg.encode(image, distance: 30, subsampling: .s420, markers: []) }
        let tooBig = JPEGMarker(code: 0xE1, payload: Data(count: 70_000))
        do {
            _ = try jpeg.encode(image, distance: 1, subsampling: .s420, markers: [tooBig])
            Issue.record("an oversized marker must fail")
        } catch let error as PrimitiveError { #expect(error.message.contains("too large")) }
        do {
            _ = try jpeg.encode(image, distance: 1, subsampling: .s420, markers: [JPEGMarker(code: 0xC4, payload: Data([1]))])
            Issue.record("a non-APP marker must fail")
        } catch let error as PrimitiveError { #expect(error.message.contains("APPn")) }
        // Straight C calls: a failing call fills the message and leaves no buffer.
        var out = hmb_buffer(data: nil, size: 0)
        var message = [CChar](repeating: 0, count: 256)
        let status = image.pixels.withUnsafeBytes { raw in
            hmb_jpegli_encode(raw.bindMemory(to: UInt8.self).baseAddress, 0, 64, image.bytesPerRow, 1, 0, 2, nil, 0, &out, &message, 256)
        }
        #expect(status != 0 && out.data == nil && message[0] != 0)
        #expect(hmb_jpegli_encode(nil, 8, 8, 32, 1, 0, 2, nil, 0, &out, &message, 256) != 0)
        #expect(hmb_jpegli_encode(image.bytes, 64, 64, 16, 1, 0, 2, nil, 0, &out, &message, 256) != 0)   // stride too small
        #expect(hmb_jpegli_encode(image.bytes, 64, 64, image.bytesPerRow, 1, 0, 7, nil, 0, &out, &message, 256) != 0)
    }

    // MARK: WebP

    /// RIFF chunk FourCCs of a WebP file, in order.
    static func webpChunks(_ data: Data) -> [String] {
        let b = [UInt8](data)
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "WEBP" else { return [] }
        var chunks: [String] = [], i = 12
        while i + 8 <= b.count {
            chunks.append(String(decoding: b[i..<(i + 4)], as: UTF8.self))
            let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            i += 8 + size + (size & 1)
        }
        return chunks
    }

    @Test func webpCarriesICCEXIFAndXMP() throws {
        let icc = try #require(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        let exif = Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00])
        let xmp = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)
        for (name, image, _) in try images() {
            let source = name.hasPrefix("SH_") ? VImageProcessing().resized(image, longEdge: 2560) : image
            let prepared = try webp.prepare(source)
            let bytes = try webp.encode(prepared, quality: 75, icc: icc, exif: exif, xmp: xmp)
            #expect(Self.webpChunks(bytes) == ["VP8X", "ICCP", "VP8 ", "EXIF", "XMP "], "\(name)")
            let decoded = try decoder.decode(encoded: bytes)
            #expect(decoded.width == source.width && decoded.height == source.height)
            #expect(Measure.psnr(source, decoded) > 25, "\(name)")
            let plain = try webp.encode(prepared, quality: 75, icc: nil, exif: nil, xmp: nil)
            #expect(Self.webpChunks(plain) == ["VP8 "])
            let partial = try webp.encode(prepared, quality: 75, icc: nil, exif: nil, xmp: xmp)
            #expect(Self.webpChunks(partial) == ["VP8X", "VP8 ", "XMP "])
        }
    }

    @Test func webpPreparedInputIsReusable() throws {
        let image = Synthetic.image(.waves, width: 400, height: 300)
        let prepared = try webp.prepare(image)
        let first = try webp.encode(prepared, quality: 50, icc: nil, exif: nil, xmp: nil)
        let high = try webp.encode(prepared, quality: 90, icc: nil, exif: nil, xmp: nil)
        let again = try webp.encode(prepared, quality: 50, icc: nil, exif: nil, xmp: nil)
        #expect(first == again)
        #expect(high.count > first.count)
        #expect(try webp.encode(try webp.prepare(image), quality: 50, icc: nil, exif: nil, xmp: nil) == first)
        #expect(throws: PrimitiveError.self) { try webp.encode(prepared, quality: 101, icc: nil, exif: nil, xmp: nil) }
        #expect(throws: PrimitiveError.self) { try webp.encode(FakeWebPPrepared(image: image), quality: 50, icc: nil, exif: nil, xmp: nil) }
        #expect(throws: PrimitiveError.self) { try webp.prepare(Synthetic.image(.noise, width: 16_384, height: 8)) }
    }

    // MARK: JXL

    @Test func jxlTranscodeIsByteExact() throws {
        var jpegs: [(String, Data)] = try [TestFixtureFiles.gradientSRGB, TestFixtureFiles.rampsP3, TestFixtureFiles.orientation6,
                                           TestFixtureFiles.holdMyByteOutput, TestFixtureFiles.mosaicSource].map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        }
        jpegs.append(("jpegli-synthetic", try jpeg.encode(Synthetic.image(.blocks, width: 333, height: 201), distance: 1,
                                                          subsampling: .s420, markers: Self.markers(icc: nil))))
        for url in LocalData.samplePhotos { jpegs.append((url.lastPathComponent, try Data(contentsOf: url, options: .alwaysMapped))) }
        for (name, source) in jpegs {
            let archived = try jxl.transcodeLossless(jpeg: source, effort: 7)
            #expect(archived.count < source.count, "\(name)")
            let rebuilt = try jxl.reconstructJPEG(jxl: archived)
            #expect(Measure.sha256(rebuilt) == Measure.sha256(source), "\(name): reconstruction must be byte-identical")
        }
    }

    @Test func jxlUnusualSourcesFailCleanlyOrStayExact() throws {
        for url in [TestFixtureFiles.cmyk, TestFixtureFiles.arithmetic] {
            let source = try Data(contentsOf: url)
            do {
                let rebuilt = try jxl.reconstructJPEG(jxl: try jxl.transcodeLossless(jpeg: source, effort: 7))
                #expect(rebuilt == source, "\(url.lastPathComponent)")
            } catch let error as PrimitiveError {
                #expect(!error.message.isEmpty)
            }
        }
        #expect(throws: PrimitiveError.self) { try jxl.transcodeLossless(jpeg: Data("garbage, not a JPEG".utf8), effort: 7) }
        #expect(throws: PrimitiveError.self) { try jxl.transcodeLossless(jpeg: Data(count: 2), effort: 7) }
        #expect(throws: PrimitiveError.self) { try jxl.transcodeLossless(jpeg: try Data(contentsOf: TestFixtureFiles.gradientSRGB), effort: 0) }
        #expect(throws: PrimitiveError.self) { try jxl.reconstructJPEG(jxl: Data("not a jxl file".utf8)) }
        let archived = try jxl.transcodeLossless(jpeg: try Data(contentsOf: TestFixtureFiles.gradientSRGB), effort: 7)
        #expect(throws: PrimitiveError.self) { try jxl.reconstructJPEG(jxl: archived.prefix(archived.count / 2)) }
    }

    @Test func jxlTranscodeIsDeterministic() throws {
        let source = try Data(contentsOf: TestFixtureFiles.mosaicSource)
        #expect(try jxl.transcodeLossless(jpeg: source, effort: 7) == jxl.transcodeLossless(jpeg: source, effort: 7))
    }

    @Test func codecVersionsNameThePins() {
        #expect(EnginePrimitives.codecVersions == "libjxl 0.11.2 · jpegli (libjxl 0.11.2) · libwebp 1.6.0")
    }

    @Test func livePrimitivesAreTheRealOnes() throws {
        let live = try EnginePrimitives.live()
        #expect(live.jpeg is JpegliEncoder && live.webp is LibWebPEncoder && live.jxl is LibJXLTranscoder)
        #expect(live.decoder is ImageIODecoder && live.processing is VImageProcessing && live.metric is MetalSSIMULACRA2)
    }

    // MARK: Memory

    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    @Test func fiftyEncodesDoNotLeak() throws {
        let image = Synthetic.image(.waves, width: 512, height: 384)
        let source = try Data(contentsOf: TestFixtureFiles.gradientSRGB)
        let markers = Self.markers(icc: nil)
        func round() throws {
            _ = try jpeg.encode(image, distance: 1.5, subsampling: .s420, markers: markers)
            let prepared = try webp.prepare(image)
            _ = try webp.encode(prepared, quality: 70, icc: Data([1, 2, 3]), exif: nil, xmp: Data("<x/>".utf8))
            _ = try jxl.reconstructJPEG(jxl: try jxl.transcodeLossless(jpeg: source, effort: 7))
            _ = try? jpeg.encode(image, distance: 1, subsampling: .s420, markers: [JPEGMarker(code: 0xE1, payload: Data(count: 70_000))])
            _ = try? jxl.reconstructJPEG(jxl: Data("broken".utf8))
        }
        for _ in 0..<5 { try round() }          // warm caches and lazily created library state
        // The heap is process-wide and other suites (decoding 45 MP photos) run in parallel, so the 50 rounds are
        // measured as ten windows of five and the smallest window is scaled up: a leak grows the heap in every
        // window, a neighbour's allocation only in some. Run alone (`swift test --filter fiftyEncodesDoNotLeak`)
        // every window is exact (measured: ≤ 3 KB per 50 rounds of each codec).
        var windows: [Int] = []
        for _ in 0..<10 {
            let before = Self.heapInUse()
            for _ in 0..<5 { try round() }
            windows.append(Self.heapInUse() - before)
        }
        let delta = max(0, windows.min()!) * 10
        print("[memory] heap delta per 5 rounds: \(windows); bound for 50 rounds: \(delta) bytes")
        #expect(delta < 5 << 20)
    }
}
