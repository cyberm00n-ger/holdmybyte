// JPEG segment surgery (§3.7): reading the header segments and rewriting them losslessly. The entropy-coded
// data (SOS to EOI) is copied byte for byte. Data after EOI (MPF/CIPA preview images, which carry their own EXIF
// and possibly GPS) is kept only on request: a metadata policy that removes data drops it, with the MPF index.
import Foundation

enum JPEGContainer {
    struct Segment: Sendable, Equatable {
        var code: UInt8
        var payload: Data
    }

    struct Parsed: Sendable {
        /// Every segment between SOI and the first SOS, in file order (APPn, COM, DQT, SOF, DHT, DRI, …).
        var segments: [Segment]
        /// Offset of the SOS marker (0xFF 0xDA); everything from here on is copied verbatim.
        var scanOffset: Int
    }

    enum ContainerError: Error, CustomStringConvertible {
        case notJPEG, truncated(Int), corrupt(Int), segmentTooLarge(UInt8, Int)
        var description: String {
            switch self {
            case .notJPEG: "not a JPEG file"
            case .truncated(let at): "truncated JPEG header at byte \(at)"
            case .corrupt(let at): "corrupt JPEG marker at byte \(at)"
            case .segmentTooLarge(let code, let size): String(format: "segment 0x%02X too large (%d bytes)", code, size)
            }
        }
    }

    static let exifPrefix = Data("Exif\u{0}\u{0}".utf8)
    static let xmpPrefix = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
    static let xmpExtensionPrefix = Data("http://ns.adobe.com/xmp/extension/\u{0}".utf8)
    static let iccPrefix = Data("ICC_PROFILE\u{0}".utf8)
    static let photoshopPrefix = Data("Photoshop 3.0\u{0}".utf8)
    static let mpfPrefix = Data("MPF\u{0}".utf8)
    /// Largest payload of one segment (the 2-byte length counts itself).
    static let maxPayload = 65_533

    static func parse(_ data: Data) throws -> Parsed {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Parsed in
            let d = raw.bindMemory(to: UInt8.self)
            guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else { throw ContainerError.notJPEG }
            var segments: [Segment] = []
            var i = 2
            while true {
                guard i + 2 <= d.count else { throw ContainerError.truncated(i) }
                guard d[i] == 0xFF else { throw ContainerError.corrupt(i) }
                let code = d[i + 1]
                if code == 0xFF { i += 1; continue }                       // fill byte
                if code == 0xDA { return Parsed(segments: segments, scanOffset: i) }
                if code == 0xD8 || code == 0x01 || (0xD0...0xD7).contains(code) { i += 2; continue }
                if code == 0xD9 { throw ContainerError.truncated(i) }       // EOI before any scan
                guard i + 4 <= d.count else { throw ContainerError.truncated(i) }
                let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
                guard length >= 2, i + 2 + length <= d.count else { throw ContainerError.truncated(i) }
                let start = data.startIndex + i + 4
                segments.append(Segment(code: code, payload: data.subdata(in: start..<(start + length - 2))))
                i += 2 + length
            }
        }
    }

    /// Reads only the header of a file (up to `limit` bytes) — enough for markers, DQT and SOF.
    static func readHeader(of url: URL, limit: Int = 512 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }

    /// Lenient walk over a possibly truncated header: returns the segments found before SOS or the end of data.
    static func headerSegments(_ data: Data) -> [Segment] {
        var segments: [Segment] = []
        let d = [UInt8](data)
        guard d.count >= 4, d[0] == 0xFF, d[1] == 0xD8 else { return [] }
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF {
            let code = d[i + 1]
            if code == 0xFF { i += 1; continue }
            if code == 0xDA || code == 0xD9 { break }
            if code == 0xD8 || code == 0x01 || (0xD0...0xD7).contains(code) { i += 2; continue }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            guard length >= 2, i + 2 + length <= d.count else { break }
            segments.append(Segment(code: code, payload: Data(d[(i + 4)..<(i + 2 + length)])))
            i += 2 + length
        }
        return segments
    }

    /// True for the segments the metadata policy owns (and therefore replaces): APP1 Exif / XMP / extended XMP,
    /// APP2 ICC, APP13 and COM.
    static func isPolicyOwned(_ s: Segment) -> Bool {
        switch s.code {
        case 0xE1: s.payload.starts(with: exifPrefix) || s.payload.starts(with: xmpPrefix)
            || s.payload.starts(with: xmpExtensionPrefix)
        case 0xE2: s.payload.starts(with: iccPrefix)
        case 0xED, 0xFE: true
        default: false
        }
    }

    /// Rewrites the metadata of `source` losslessly: SOI, the APP0 JFIF segment if present, then `markers`
    /// (already in output order), then every remaining non-policy segment in its original order, then the scan
    /// data verbatim. Without `keepTrailingData`, everything after EOI and the APP2 MPF index that points into it
    /// are dropped (if no EOI is found, the rest of the file is kept as it is).
    static func rewrite(_ source: Data, markers: [Segment], keepTrailingData: Bool = true) throws -> Data {
        let parsed = try parse(source)
        let end = keepTrailingData ? nil : endOfImage(source, scanOffset: parsed.scanOffset)
        var out = Data([0xFF, 0xD8])
        let app0 = parsed.segments.prefix { $0.code == 0xE0 }
        for s in app0 { try append(s, to: &out) }
        for s in markers { try append(s, to: &out) }
        for s in parsed.segments.dropFirst(app0.count) where !isPolicyOwned(s) {
            if end != nil, s.code == 0xE2, s.payload.starts(with: mpfPrefix) { continue }
            try append(s, to: &out)
        }
        out.append(source.subdata(in: (source.startIndex + parsed.scanOffset)..<(source.startIndex + (end ?? source.count))))
        return out
    }

    /// Offset just past the EOI marker of the primary image, walking the scans from the first SOS: entropy-coded
    /// bytes (with 0xFF00 stuffing and RSTn), and the segments between progressive scans by their lengths.
    static func endOfImage(_ data: Data, scanOffset: Int) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let d = raw.bindMemory(to: UInt8.self)
            var i = scanOffset
            while i + 1 < d.count {
                guard d[i] == 0xFF else { i += 1; continue }
                let code = d[i + 1]
                switch code {
                case 0x00, 0xD0...0xD7: i += 2                         // stuffed byte, restart marker
                case 0xFF: i += 1                                      // fill byte
                case 0xD9: return i + 2
                default:                                               // SOS, DHT, DQT, DRI, DNL, APPn, COM
                    guard i + 4 <= d.count else { return nil }
                    let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
                    guard length >= 2 else { return nil }
                    i += 2 + length
                }
            }
            return nil
        }
    }

    static func append(_ s: Segment, to out: inout Data) throws {
        guard s.payload.count <= maxPayload else { throw ContainerError.segmentTooLarge(s.code, s.payload.count) }
        let length = s.payload.count + 2
        out.append(contentsOf: [0xFF, s.code, UInt8(length >> 8), UInt8(length & 0xFF)])
        out.append(s.payload)
    }

    /// APP2 ICC_PROFILE chain (sequence numbers from 1).
    static func iccSegments(_ icc: Data) -> [Segment] {
        let chunk = maxPayload - iccPrefix.count - 2
        let count = (icc.count + chunk - 1) / chunk
        guard count > 0, count <= 255 else { return [] }
        return (0..<count).map { i in
            var payload = iccPrefix
            payload.append(UInt8(i + 1)); payload.append(UInt8(count))
            let start = icc.startIndex + i * chunk
            payload.append(icc.subdata(in: start..<min(icc.endIndex, start + chunk)))
            return Segment(code: 0xE2, payload: payload)
        }
    }
}
