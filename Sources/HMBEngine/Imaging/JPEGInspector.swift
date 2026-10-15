// JPEG header walk (SOI … SOS) without a pixel decode: APPn/COM markers in file order, the ICC chain, EXIF, XMP,
// the DQT quality estimate, the frame type (arithmetic coding) and the colour model (CMYK / YCCK).
import Foundation

struct JPEGHeader {
    var markers: [JPEGMarker] = []
    var iccProfile: Data?
    var exif: Data?
    var xmp: Data?
    var estimatedQuality: Int?
    var isCMYK = false
    var isArithmeticCoded = false
    var isHoldMyByteOutput = false
    var frameMarker: UInt8?
    var width = 0, height = 0, components = 0
    var adobeTransform: Int?
}

enum JPEGInspector {
    static let exifPrefix = Data("Exif\u{0}\u{0}".utf8)
    static let xmpPrefix = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
    static let iccPrefix = Data("ICC_PROFILE\u{0}".utf8)
    static let adobePrefix = Data("Adobe".utf8)

    /// IJG standard luminance table (natural order; the quality estimate only uses its sum).
    static let standardLuma: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]

    static func isJPEG(_ data: Data) -> Bool { data.count >= 3 && data.starts(with: [0xFF, 0xD8, 0xFF]) }

    /// Walks the header segments. Throws on a malformed header before the first scan.
    static func scan(_ data: Data) throws -> JPEGHeader {
        try data.withUnsafeBytes { raw -> JPEGHeader in
            let d = raw.bindMemory(to: UInt8.self)
            guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else { throw PrimitiveError("not a JPEG (no SOI)") }
            var header = JPEGHeader()
            var iccChunks: [(sequence: Int, payload: Data)] = []
            var i = 2
            while i + 1 < d.count {
                guard d[i] == 0xFF else { throw PrimitiveError("corrupt JPEG: expected a marker at byte \(i)") }
                let code = d[i + 1]
                if code == 0xFF { i += 1; continue }                       // fill byte
                if code == 0x01 || (0xD0...0xD7).contains(code) { i += 2; continue }   // TEM, RSTn: no length
                if code == 0xD9 || code == 0xDA { break }                  // EOI, SOS
                guard i + 3 < d.count else { throw PrimitiveError("truncated JPEG segment header") }
                let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
                guard length >= 2, i + 2 + length <= d.count else { throw PrimitiveError("truncated JPEG segment 0x\(String(code, radix: 16))") }
                let start = i + 4, end = i + 2 + length
                let payload = Data(UnsafeBufferPointer(rebasing: d[start..<end]))
                switch code {
                case 0xE0...0xEF, 0xFE:
                    header.markers.append(JPEGMarker(code: code, payload: payload))
                    if code == 0xE1, header.exif == nil, payload.starts(with: exifPrefix) {
                        header.exif = payload.subdata(in: payload.startIndex + exifPrefix.count..<payload.endIndex)
                    } else if code == 0xE1, header.xmp == nil, payload.starts(with: xmpPrefix) {
                        header.xmp = payload.subdata(in: payload.startIndex + xmpPrefix.count..<payload.endIndex)
                    } else if code == 0xE2, payload.starts(with: iccPrefix), payload.count > iccPrefix.count + 2 {
                        let sequence = Int(payload[payload.startIndex + iccPrefix.count])
                        iccChunks.append((sequence, payload.subdata(in: payload.startIndex + iccPrefix.count + 2..<payload.endIndex)))
                    } else if code == 0xEE, payload.starts(with: adobePrefix), payload.count >= 12 {
                        header.adobeTransform = Int(payload[payload.startIndex + 11])
                    } else if code == 0xFE, payload.range(of: Data("holdmybyte".utf8)) != nil {
                        header.isHoldMyByteOutput = true
                    }
                case 0xDB:
                    if header.estimatedQuality == nil { header.estimatedQuality = estimateQuality(dqt: payload) }
                case 0xC0...0xCF where code != 0xC4 && code != 0xC8 && code != 0xCC:
                    if header.frameMarker == nil, payload.count >= 6 {
                        header.frameMarker = code
                        header.height = Int(payload[payload.startIndex + 1]) << 8 | Int(payload[payload.startIndex + 2])
                        header.width = Int(payload[payload.startIndex + 3]) << 8 | Int(payload[payload.startIndex + 4])
                        header.components = Int(payload[payload.startIndex + 5])
                        // SOF9…SOF11, SOF13…SOF15: arithmetic entropy coding.
                        header.isArithmeticCoded = code >= 0xC9
                    }
                case 0xCC:
                    header.isArithmeticCoded = true                         // DAC: arithmetic conditioning
                default:
                    break
                }
                i = end
            }
            guard header.frameMarker != nil else { throw PrimitiveError("corrupt JPEG: no frame header before the first scan") }
            header.isCMYK = header.components == 4
            if !iccChunks.isEmpty {
                header.iccProfile = iccChunks.sorted { $0.sequence < $1.sequence }.reduce(into: Data()) { $0.append($1.payload) }
            }
            return header
        }
    }

    /// IJG inverse on the luma table (Tq = 0, else the first table): quality from the mean scale factor against
    /// the standard table, i.e. the `-quality` libjpeg would have needed for tables of this strength.
    static func estimateQuality(dqt: Data) -> Int? {
        let b = [UInt8](dqt)
        var i = 0
        var chosen: Int?
        while i < b.count {
            let precision = Int(b[i]) >> 4, id = Int(b[i]) & 15
            let size = 64 * (precision == 0 ? 1 : 2)
            guard i + 1 + size <= b.count else { break }
            var sum = 0
            for k in 0..<64 { sum += precision == 0 ? Int(b[i + 1 + k]) : (Int(b[i + 1 + 2 * k]) << 8 | Int(b[i + 2 + 2 * k])) }
            if id == 0 || chosen == nil { chosen = sum }
            if id == 0 { break }
            i += 1 + size
        }
        guard let sum = chosen else { return nil }
        let scale = Double(sum) * 100 / Double(standardLuma.reduce(0, +))
        let quality = scale <= 100 ? (200 - scale) / 2 : 5000 / scale
        return min(100, max(1, Int(quality.rounded())))
    }
}
