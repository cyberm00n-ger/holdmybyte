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

    /// 50 rounds of all three codecs (success and error paths, through the Swift wrappers) must not grow the heap by
    /// 5 MB or more.
    ///
    /// The heap is process-wide and other suites decode 45 MP photos in parallel, so an in-process before/after is
    /// meaningless inside `swift test`: a neighbour's free of one decoded photo (180 MB) hides any leak, and its
    /// allocations fail the bound for nothing. The rounds therefore run in a forked child: one thread executing only
    /// code the parent has just run (warm: no lazy library or runtime state is created in the child), so nothing but
    /// the rounds touches the heap between the two `malloc_zone_statistics` readings. The child reports the delta
    /// through a pipe and leaves with `_exit`; it never prints, and it is killed if it does not answer in 120 s.
    @Test func fiftyEncodesDoNotLeak() throws {
        let image = Synthetic.image(.waves, width: 512, height: 384)
        let source = try Data(contentsOf: TestFixtureFiles.gradientSRGB)
        let markers = Self.markers(icc: nil)
        let oversized = [JPEGMarker(code: 0xE1, payload: Data(count: 70_000))]
        let icc = Data([1, 2, 3]), xmp = Data("<x/>".utf8), broken = Data("broken".utf8)
        let (jpeg, webp, jxl) = (self.jpeg, self.webp, self.jxl)
        /// One round; false if a call that must succeed failed or a call that must fail succeeded.
        func round() -> Bool {
            guard (try? jpeg.encode(image, distance: 1.5, subsampling: .s420, markers: markers)) != nil,
                  let prepared = try? webp.prepare(image),
                  (try? webp.encode(prepared, quality: 70, icc: icc, exif: nil, xmp: xmp)) != nil,
                  let archived = try? jxl.transcodeLossless(jpeg: source, effort: 7),
                  (try? jxl.reconstructJPEG(jxl: archived)) != nil else { return false }
            return (try? jpeg.encode(image, distance: 1, subsampling: .s420, markers: oversized)) == nil
                && (try? jxl.reconstructJPEG(jxl: broken)) == nil
        }
        for _ in 0..<5 { #expect(round()) }      // warm: lazily created library and runtime state

        // `fork` is unavailable to Swift by declaration only; the child runs nothing but `round()` and syscalls.
        typealias Fork = @convention(c) () -> pid_t
        let fork = unsafeBitCast(try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork")), to: Fork.self)
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        let (readEnd, writeEnd) = (fds[0], fds[1])
        let pid = fork()
        if pid == 0 {
            close(readEnd)
            let before = Self.heapInUse()
            var ok = true
            for _ in 0..<50 where !round() { ok = false }
            var delta = ok ? Int64(Self.heapInUse() - before) : Int64.min
            _ = withUnsafeBytes(of: &delta) { write(writeEnd, $0.baseAddress, 8) }
            _exit(0)
        }
        close(writeEnd)
        defer { close(readEnd) }
        try #require(pid > 0, "fork failed: errno \(errno)")
        var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        var delta = Int64.max
        if poll(&poller, 1, 120_000) == 1 {
            _ = withUnsafeMutableBytes(of: &delta) { read(readEnd, $0.baseAddress, 8) }
        } else {
            kill(pid, SIGKILL)
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        print("[memory] heap delta over 50 rounds in an isolated child: \(delta) bytes")
        #expect(delta != Int64.max, "the child did not report (hung or crashed)")
        #expect(delta != Int64.min, "a codec call misbehaved in the child")
        #expect(delta < 5 << 20)
    }
}
