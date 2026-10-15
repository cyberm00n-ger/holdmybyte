// Deterministic CPU fakes for the §3.2 primitives (WP0, frozen). WP2 develops against these until WP1 lands.
//
// - Fake JPEG/WebP "encoders" store the RGB samples quantised by a step (JPEG: round(distance × 4);
//   WebP: round((100 − q) / 8); at least 1), bit-packed behind a small header. The output size is a deterministic,
//   non-increasing function of the step (and of the image size, the metadata and, for JPEG, the subsampling:
//   4:4:4 adds width × height / 16 bytes).
// - The fake metric is 100 − 2.5 × RMSE over R, G and B (0…255 scale).
// - The fake JXL transcoder is the identity behind a 4-byte magic ("HMBX").
// - The decoder parses JPEG markers itself, reads orientation with ImageIO, decodes fake containers itself and
//   everything else with ImageIO.
import CoreGraphics
import Foundation
import HMBModel
import ImageIO

extension EnginePrimitives {
    public static func fakes() -> EnginePrimitives {
        EnginePrimitives(decoder: FakeDecoder(), processing: FakeProcessing(), jpeg: FakeJPEGEncoder(),
                         webp: FakeWebPEncoder(), jxl: FakeJXLTranscoder(), metric: FakeMetric())
    }
}

// MARK: - Fake container

/// The byte format shared by the fake JPEG and WebP encoders.
public enum FakeCodecContainer {
    public static let jpegMagic = Data("HMBFJPG\u{0}".utf8)
    public static let webpMagic = Data("HMBFWBP\u{0}".utf8)

    public struct Decoded: Sendable {
        public var width: Int, height: Int, step: Int
        public var is444: Bool
        public var metadata: [(code: UInt8, payload: Data)]
        public var image: PixelImage
    }

    public static func isFake(_ data: Data) -> Bool {
        data.count >= 8 && (data.prefix(8) == jpegMagic || data.prefix(8) == webpMagic)
    }

    /// Quantisation of one 8-bit sample with `step`; `levels` = 255 / step + 1.
    @inline(__always) static func quantise(_ v: UInt8, step: Int) -> Int { min(255 / step, (Int(v) + step / 2) / step) }
    @inline(__always) static func dequantise(_ q: Int, step: Int) -> UInt8 { UInt8(min(255, q * step)) }
    static func bitsPerSample(step: Int) -> Int {
        let maxIndex = 255 / step
        return max(1, Int.bitWidth - maxIndex.leadingZeroBitCount)
    }

    static func encode(_ image: PixelImage, magic: Data, step: Int, is444: Bool,
                       metadata: [(code: UInt8, payload: Data)]) -> Data {
        var out = Data()
        out.append(magic)
        out.appendLE(UInt32(image.width)); out.appendLE(UInt32(image.height))
        out.appendLE(UInt16(step)); out.append(is444 ? 1 : 0); out.append(0)
        out.appendLE(UInt32(metadata.count))
        for entry in metadata {
            out.append(entry.code); out.appendLE(UInt32(entry.payload.count)); out.append(entry.payload)
        }
        let bits = bitsPerSample(step: step)
        out.append(UInt8(bits))
        var writer = BitWriter(expectedBytes: (image.pixelCount * 3 * bits + 7) / 8)
        let base = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            let row = base + y * image.bytesPerRow
            for x in 0..<image.width {
                let p = row + x * 4
                writer.write(quantise(p[0], step: step), bits: bits)
                writer.write(quantise(p[1], step: step), bits: bits)
                writer.write(quantise(p[2], step: step), bits: bits)
            }
        }
        out.append(writer.finish())
        if is444 { out.append(Data(count: image.pixelCount / 16)) }
        return out
    }

    public static func decode(_ data: Data, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> Decoded {
        guard isFake(data) else { throw PrimitiveError("not a fake codec container") }
        var reader = ByteReader(data: data, offset: 8)
        let width = Int(try reader.u32()), height = Int(try reader.u32())
        let step = Int(try reader.u16()), flags = try reader.u8()
        _ = try reader.u8()
        guard width > 0, height > 0, step > 0, width <= 65_535, height <= 65_535 else {
            throw PrimitiveError("corrupt fake container header")
        }
        var metadata: [(code: UInt8, payload: Data)] = []
        for _ in 0..<Int(try reader.u32()) {
            let code = try reader.u8()
            let length = Int(try reader.u32())
            metadata.append((code, try reader.bytes(length)))
        }
        let bits = Int(try reader.u8())
        guard bits == bitsPerSample(step: step) else { throw PrimitiveError("corrupt fake container sample size") }
        let packed = try reader.bytes((width * height * 3 * bits + 7) / 8)
        let image = PixelImage(width: width, height: height, colorSpace: colorSpace)
        var bitReader = BitReader(data: packed)
        let base = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = base + y * image.bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                p[0] = dequantise(bitReader.read(bits: bits), step: step)
                p[1] = dequantise(bitReader.read(bits: bits), step: step)
                p[2] = dequantise(bitReader.read(bits: bits), step: step)
                p[3] = 255
            }
        }
        return Decoded(width: width, height: height, step: step, is444: flags & 1 == 1, metadata: metadata, image: image)
    }
}

// MARK: - Encoders

public struct FakeJPEGEncoder: JPEGEncoding {
    public init() {}
    public static func step(distance: Double) -> Int { max(1, Int((distance * 4).rounded())) }
    public func encode(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling,
                       markers: [JPEGMarker]) throws -> Data {
        guard distance.isFinite, distance >= 0 else { throw PrimitiveError("invalid distance \(distance)") }
        return FakeCodecContainer.encode(image, magic: FakeCodecContainer.jpegMagic, step: Self.step(distance: distance),
                                         is444: subsampling == .s444, metadata: markers.map { ($0.code, $0.payload) })
    }
}

public final class FakeWebPPrepared: WebPPrepared, @unchecked Sendable {
    public let image: PixelImage
    public init(image: PixelImage) { self.image = image; super.init() }
}

public struct FakeWebPEncoder: WebPEncoding {
    public static let iccCode: UInt8 = 1, exifCode: UInt8 = 2, xmpCode: UInt8 = 3
    public init() {}
    public static func step(quality: Float) -> Int { max(1, Int(((100 - Double(quality)) / 8).rounded())) }
    public func prepare(_ image: PixelImage) throws -> WebPPrepared { FakeWebPPrepared(image: image) }
    public func encode(_ prepared: WebPPrepared, quality: Float, icc: Data?, exif: Data?, xmp: Data?) throws -> Data {
        guard let prepared = prepared as? FakeWebPPrepared else { throw PrimitiveError("not a FakeWebPPrepared") }
        guard quality.isFinite, (0...100).contains(quality) else { throw PrimitiveError("invalid quality \(quality)") }
        var metadata: [(code: UInt8, payload: Data)] = []
        if let icc { metadata.append((Self.iccCode, icc)) }
        if let exif { metadata.append((Self.exifCode, exif)) }
        if let xmp { metadata.append((Self.xmpCode, xmp)) }
        return FakeCodecContainer.encode(prepared.image, magic: FakeCodecContainer.webpMagic,
                                         step: Self.step(quality: quality), is444: false, metadata: metadata)
    }
}

public struct FakeJXLTranscoder: JXLTranscoding {
    public static let magic = Data("HMBX".utf8)
    public init() {}
    public func transcodeLossless(jpeg: Data, effort: Int) throws -> Data {
        guard (1...10).contains(effort) else { throw PrimitiveError("invalid effort \(effort)") }
        return Self.magic + jpeg
    }
    public func reconstructJPEG(jxl: Data) throws -> Data {
        guard jxl.count >= 4, jxl.prefix(4) == Self.magic else { throw PrimitiveError("not a fake JXL file") }
        return Data(jxl.dropFirst(4))
    }
}

// MARK: - Metric

public final class FakeMetricReference: MetricReference {
    public let image: PixelImage
    public var width: Int { image.width }
    public var height: Int { image.height }
    public init(image: PixelImage) { self.image = image }
}

public struct FakeMetric: PerceptualMetric {
    public init() {}
    public func prepareReference(_ image: PixelImage) throws -> any MetricReference { FakeMetricReference(image: image) }
    public func score(_ candidate: PixelImage, against reference: any MetricReference) throws -> Double {
        guard let reference = reference as? FakeMetricReference else { throw PrimitiveError("not a FakeMetricReference") }
        let a = reference.image, b = candidate
        guard a.width == b.width, a.height == b.height else {
            throw PrimitiveError("size mismatch: \(a.width)×\(a.height) vs \(b.width)×\(b.height)")
        }
        return 100 - 2.5 * Self.rmse(a, b)
    }
    public func release(_ reference: any MetricReference) {}

    /// RMSE over R, G and B on the 0…255 scale.
    public static func rmse(_ a: PixelImage, _ b: PixelImage) -> Double {
        let pa = a.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let pb = b.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var sum: UInt64 = 0
        for y in 0..<a.height {
            let ra = pa + y * a.bytesPerRow, rb = pb + y * b.bytesPerRow
            for i in 0..<(a.width * 4) where i & 3 != 3 {
                let d = Int(ra[i]) - Int(rb[i])
                sum &+= UInt64(d * d)
            }
        }
        return (Double(sum) / Double(a.pixelCount * 3)).squareRoot()
    }
}

// MARK: - Processing

public struct FakeProcessing: ImageProcessing {
    public init() {}

    /// textureP50: median over 16×16 blocks of the mean absolute horizontal luma difference (0…1).
    /// chromaEnergy: mean of (|R − G| + |B − G|) / 2 over all pixels (0…1).
    public func features(_ image: PixelImage) -> ImageFeatures {
        let base = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        @inline(__always) func luma(_ p: UnsafePointer<UInt8>) -> Double {
            0.299 * Double(p[0]) + 0.587 * Double(p[1]) + 0.114 * Double(p[2])
        }
        var blocks: [Double] = []
        var chroma = 0.0
        for by in stride(from: 0, to: image.height, by: 16) {
            for bx in stride(from: 0, to: image.width, by: 16) {
                var sum = 0.0, n = 0
                for y in by..<min(by + 16, image.height) {
                    let row = UnsafePointer(base + y * image.bytesPerRow)
                    for x in bx..<min(bx + 16, image.width) {
                        let p = row + x * 4
                        chroma += (abs(Double(p[0]) - Double(p[1])) + abs(Double(p[2]) - Double(p[1]))) / 2
                        if x + 1 < image.width { sum += abs(luma(p + 4) - luma(p)); n += 1 }
                    }
                }
                blocks.append(n > 0 ? sum / Double(n) / 255 : 0)
            }
        }
        blocks.sort()
        return ImageFeatures(textureP50: blocks.isEmpty ? 0 : blocks[blocks.count / 2],
                             chromaEnergy: chroma / Double(image.pixelCount) / 255)
    }

    /// Area-average downscale; returns `image` itself when it is already small enough (never upscales).
    public func resized(_ image: PixelImage, longEdge: Int) -> PixelImage {
        let edge = max(image.width, image.height)
        guard longEdge > 0, longEdge < edge else { return image }
        let scale = Double(longEdge) / Double(edge)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let out = PixelImage(width: w, height: h, colorSpace: image.colorSpace)
        let src = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let dst = out.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let y0 = y * image.height / h, y1 = max(y0 + 1, (y + 1) * image.height / h)
            for x in 0..<w {
                let x0 = x * image.width / w, x1 = max(x0 + 1, (x + 1) * image.width / w)
                var r = 0, g = 0, b = 0
                for sy in y0..<y1 {
                    let row = src + sy * image.bytesPerRow
                    for sx in x0..<x1 { let p = row + sx * 4; r += Int(p[0]); g += Int(p[1]); b += Int(p[2]) }
                }
                let n = (y1 - y0) * (x1 - x0)
                let q = dst + y * out.bytesPerRow + x * 4
                q[0] = UInt8((r + n / 2) / n); q[1] = UInt8((g + n / 2) / n); q[2] = UInt8((b + n / 2) / n); q[3] = 255
            }
        }
        return out
    }

    /// Fake: relabels the pixels as sRGB without converting them (the identity for sRGB input).
    public func convertedToSRGB(_ image: PixelImage) -> PixelImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if image.colorSpace.name == CGColorSpace.sRGB { return image }
        let out = PixelImage(width: image.width, height: image.height, colorSpace: srgb)
        out.pixels.copyMemory(from: UnsafeRawBufferPointer(image.pixels))
        return out
    }

    /// 8×4 grid of 256² tiles spread evenly over the image (2048×1024); nil if the image is smaller than 2048×1024.
    public func mosaic(_ image: PixelImage) -> PixelImage? {
        guard image.width >= 2048, image.height >= 1024 else { return nil }
        let tile = 256
        let out = PixelImage(width: 8 * tile, height: 4 * tile, colorSpace: image.colorSpace)
        let src = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let dst = out.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for j in 0..<4 {
            for i in 0..<8 {
                let sx = (image.width - tile) * i / 7, sy = (image.height - tile) * j / 3
                for y in 0..<tile {
                    (dst + (j * tile + y) * out.bytesPerRow + i * tile * 4)
                        .update(from: src + (sy + y) * image.bytesPerRow + sx * 4, count: tile * 4)
                }
            }
        }
        return out
    }
}

// MARK: - Decoder

public struct FakeDecoder: ImageDecoding {
    public init() {}

    public func inspect(_ url: URL) throws -> SourceInfo {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try Self.inspect(data: data, pathExtension: url.pathExtension)
    }

    public func decode(_ info: SourceInfo) throws -> PixelImage { try decode(encoded: info.fileBytes) }

    public func decode(encoded: Data) throws -> PixelImage {
        if FakeCodecContainer.isFake(encoded) { return try FakeCodecContainer.decode(encoded).image }
        return try Self.decodeWithImageIO(encoded)
    }

    public static func inspect(data: Data, pathExtension: String) throws -> SourceInfo {
        let kind: SourceKind
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8]) || FakeCodecContainer.isFake(data) { kind = .jpeg }
        else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { kind = .png }
        else if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { kind = .tiff }
        else if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { kind = .heic }
        else {
            switch pathExtension.lowercased() {
            case "jpg", "jpeg": kind = .jpeg
            case "png": kind = .png
            case "tif", "tiff": kind = .tiff
            case "heic", "heif": kind = .heic
            default: throw PrimitiveError("unsupported file type")
            }
        }
        var info = SourceInfo(kind: kind, fileBytes: data, markers: [], iccProfile: nil, exif: nil, xmp: nil,
                              orientation: 1, estimatedJPEGQuality: nil, isCMYK: false, isHoldMyByteOutput: false,
                              isArithmeticCoded: false)
        if kind == .jpeg, !FakeCodecContainer.isFake(data) { try JPEGMarkerScan.apply(to: &info) }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = props[kCGImagePropertyOrientation] as? Int, (1...8).contains(orientation) {
            info.orientation = orientation
        }
        return info
    }

    static func decodeWithImageIO(_ data: Data) throws -> PixelImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw PrimitiveError("ImageIO could not decode the data")
        }
        let space = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let image = PixelImage(width: cg.width, height: cg.height, colorSpace: space)
        guard let context = CGContext(data: image.pixels.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PrimitiveError("could not create a bitmap context")
        }
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let base = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            let row = base + y * image.bytesPerRow
            for x in 0..<image.width { row[x * 4 + 3] = 255 }
        }
        return image
    }
}

/// Minimal JPEG marker walk (SOI … SOS) used by `FakeDecoder.inspect`.
enum JPEGMarkerScan {
    static let standardLuma: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]

    static func apply(to info: inout SourceInfo) throws {
        let d = [UInt8](info.fileBytes.prefix(4 << 20))   // markers live at the start; cap the copy
        guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else { throw PrimitiveError("not a JPEG") }
        var i = 2
        var iccChunks: [(Int, Data)] = []
        while i + 4 <= d.count {
            guard d[i] == 0xFF else { throw PrimitiveError("corrupt JPEG marker at \(i)") }
            let code = d[i + 1]
            if code == 0xFF { i += 1; continue }
            if code == 0xD8 || (0xD0...0xD7).contains(code) || code == 0x01 { i += 2; continue }
            if code == 0xD9 || code == 0xDA { break }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            guard length >= 2, i + 2 + length <= d.count else { throw PrimitiveError("truncated JPEG segment") }
            let payload = Data(d[(i + 4)..<(i + 2 + length)])
            switch code {
            case 0xE0...0xEF, 0xFE:
                info.markers.append(JPEGMarker(code: code, payload: payload))
                if code == 0xE1, payload.starts(with: Array("Exif\u{0}\u{0}".utf8)) {
                    info.exif = Data(payload.dropFirst(6))
                } else if code == 0xE1, payload.starts(with: Array("http://ns.adobe.com/xap/1.0/\u{0}".utf8)) {
                    info.xmp = Data(payload.dropFirst(29))
                } else if code == 0xE2, payload.starts(with: Array("ICC_PROFILE\u{0}".utf8)), payload.count > 14 {
                    iccChunks.append((Int(payload[payload.startIndex + 12]), Data(payload.dropFirst(14))))
                } else if code == 0xFE, String(decoding: payload, as: UTF8.self).contains("holdmybyte") {
                    info.isHoldMyByteOutput = true
                }
            case 0xDB:
                if info.estimatedJPEGQuality == nil { info.estimatedJPEGQuality = estimateQuality(dqt: payload) }
            case 0xC0...0xCF where code != 0xC4 && code != 0xC8 && code != 0xCC:
                if payload.count >= 6 { info.isCMYK = payload[payload.startIndex + 5] == 4 }
                info.isArithmeticCoded = code >= 0xC9
            default:
                break
            }
            i += 2 + length
        }
        if !iccChunks.isEmpty {
            info.iccProfile = iccChunks.sorted { $0.0 < $1.0 }.reduce(into: Data()) { $0.append($1.1) }
        }
    }

    /// IJG inverse of the first (luma) table: quality from the mean scale factor against the standard table.
    static func estimateQuality(dqt: Data) -> Int? {
        let b = [UInt8](dqt)
        guard let pq = b.first.map({ Int($0) >> 4 }), b.count >= 1 + 64 * (pq == 0 ? 1 : 2) else { return nil }
        // Compare sums, which do not depend on the (zig-zag) storage order.
        var sumQ = 0
        for k in 0..<64 { sumQ += pq == 0 ? Int(b[1 + k]) : (Int(b[1 + 2 * k]) << 8 | Int(b[2 + 2 * k])) }
        let scale = Double(sumQ) * 100 / Double(standardLuma.reduce(0, +))
        let quality = scale <= 100 ? (200 - scale) / 2 : 5000 / scale
        return min(100, max(1, Int(quality.rounded())))
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

struct ByteReader {
    let data: Data
    var offset: Int
    init(data: Data, offset: Int) { self.data = data; self.offset = data.startIndex + offset }
    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.endIndex else { throw PrimitiveError("truncated fake container") }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }
    mutating func u8() throws -> UInt8 { try bytes(1).first! }
    mutating func u16() throws -> UInt16 { try bytes(2).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) } }
    mutating func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
}

struct BitWriter {
    private var bytes: [UInt8]
    private var accumulator: UInt64 = 0
    private var count = 0
    init(expectedBytes: Int) { bytes = []; bytes.reserveCapacity(expectedBytes) }
    mutating func write(_ value: Int, bits: Int) {
        accumulator = accumulator << UInt64(bits) | UInt64(value)
        count += bits
        while count >= 8 {
            count -= 8
            bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt64(count)))
        }
    }
    mutating func finish() -> Data {
        if count > 0 { bytes.append(UInt8(truncatingIfNeeded: accumulator << UInt64(8 - count))); count = 0 }
        return Data(bytes)
    }
}

struct BitReader {
    private let bytes: [UInt8]
    private var index = 0
    private var accumulator: UInt64 = 0
    private var count = 0
    init(data: Data) { bytes = [UInt8](data) }
    mutating func read(bits: Int) -> Int {
        while count < bits {
            accumulator = accumulator << 8 | UInt64(index < bytes.count ? bytes[index] : 0)
            index += 1
            count += 8
        }
        count -= bits
        return Int((accumulator >> UInt64(count)) & ((1 << UInt64(bits)) - 1))
    }
}
