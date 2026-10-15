// A minimal TIFF (EXIF) reader and writer (§3.7): enough to drop tags and rebuild the IFD chain. Values are
// copied as raw bytes in the source byte order; only the IFD pointers and the IFD1 thumbnail offset are
// relocated. MakerNote (which carries internal offsets) is only ever kept verbatim or dropped.
import Foundation

struct TIFFEntry: Sendable, Equatable {
    var tag: UInt16
    var type: UInt16
    var count: UInt32
    var value: Data          // count × size(type) bytes, in the file's byte order
}

struct TIFFDocument: Sendable, Equatable {
    var bigEndian: Bool
    var ifd0: [TIFFEntry]
    var exif: [TIFFEntry]?
    var gps: [TIFFEntry]?
    var interop: [TIFFEntry]?
    var ifd1: [TIFFEntry]?
    var thumbnail: Data?

    enum Tag {
        static let orientation: UInt16 = 0x0112
        static let artist: UInt16 = 0x013B
        static let copyright: UInt16 = 0x8298
        static let exifPointer: UInt16 = 0x8769
        static let gpsPointer: UInt16 = 0x8825
        static let interopPointer: UInt16 = 0xA005
        static let subIFDs: UInt16 = 0x014A
        static let thumbnailOffset: UInt16 = 0x0201
        static let thumbnailLength: UInt16 = 0x0202
        static let makerNote: UInt16 = 0x927C
        static let bodySerial: UInt16 = 0xA431
        static let lensSerial: UInt16 = 0xA435
        static let pointers: Set<UInt16> = [exifPointer, gpsPointer, interopPointer, subIFDs]
    }

    struct FormatError: Error, CustomStringConvertible {
        var description: String
    }

    static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: 0
        }
    }

    // MARK: Reading

    init(bigEndian: Bool, ifd0: [TIFFEntry]) {
        self.bigEndian = bigEndian; self.ifd0 = ifd0
    }

    init(parsing data: Data) throws {
        let d = [UInt8](data)
        guard d.count >= 8 else { throw FormatError(description: "TIFF header too short") }
        let big: Bool
        switch (d[0], d[1]) {
        case (0x4D, 0x4D): big = true
        case (0x49, 0x49): big = false
        default: throw FormatError(description: "bad TIFF byte order")
        }
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= d.count else { throw FormatError(description: "offset \(o) out of range") }
            return big ? Int(d[o]) << 8 | Int(d[o + 1]) : Int(d[o + 1]) << 8 | Int(d[o])
        }
        func u32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= d.count else { throw FormatError(description: "offset \(o) out of range") }
            let b = (Int(d[o]), Int(d[o + 1]), Int(d[o + 2]), Int(d[o + 3]))
            return big ? b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3 : b.3 << 24 | b.2 << 16 | b.1 << 8 | b.0
        }
        guard try u16(2) == 42 else { throw FormatError(description: "bad TIFF magic") }
        var visited = Set<Int>()
        func readIFD(_ offset: Int) throws -> (entries: [TIFFEntry], next: Int) {
            guard visited.insert(offset).inserted else { throw FormatError(description: "IFD loop") }
            let n = try u16(offset)
            guard n < 1000 else { throw FormatError(description: "implausible IFD size") }
            var entries: [TIFFEntry] = []
            for k in 0..<n {
                let e = offset + 2 + 12 * k
                let tag = UInt16(try u16(e)), type = UInt16(try u16(e + 2)), count = try u32(e + 4)
                let size = Self.typeSize(type) * count
                guard Self.typeSize(type) > 0, count < 1 << 26 else { continue }    // unknown type: drop the entry
                let start = size <= 4 ? e + 8 : try u32(e + 8)
                guard start >= 0, start + size <= d.count else { continue }           // dangling value: drop
                entries.append(TIFFEntry(tag: tag, type: type, count: UInt32(count), value: Data(d[start..<(start + size)])))
            }
            let nextOffset = offset + 2 + 12 * n
            return (entries, nextOffset + 4 <= d.count ? try u32(nextOffset) : 0)
        }
        func pointer(_ entries: [TIFFEntry], _ tag: UInt16) -> Int? {
            guard let e = entries.first(where: { $0.tag == tag }), e.value.count >= 4, e.count == 1 else { return nil }
            let b = [UInt8](e.value)
            return big ? Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                       : Int(b[3]) << 24 | Int(b[2]) << 16 | Int(b[1]) << 8 | Int(b[0])
        }
        let first = try readIFD(try u32(4))
        bigEndian = big
        ifd0 = first.entries
        if let o = pointer(ifd0, Tag.exifPointer) { exif = try? readIFD(o).entries }
        if let o = pointer(ifd0, Tag.gpsPointer) { gps = try? readIFD(o).entries }
        if let exif, let o = pointer(exif, Tag.interopPointer) { interop = try? readIFD(o).entries }
        if first.next > 0, let second = try? readIFD(first.next) {
            ifd1 = second.entries
            if let o = pointer(second.entries, Tag.thumbnailOffset),
               let n = second.entries.first(where: { $0.tag == Tag.thumbnailLength }).flatMap({ Self.integer($0, big: big) }),
               o > 0, n > 0, o + n <= d.count {
                thumbnail = Data(d[o..<(o + n)])
            }
        }
    }

    static func integer(_ e: TIFFEntry, big: Bool) -> Int? {
        let b = [UInt8](e.value)
        switch e.type {
        case 3 where b.count >= 2: return big ? Int(b[0]) << 8 | Int(b[1]) : Int(b[1]) << 8 | Int(b[0])
        case 4 where b.count >= 4:
            return big ? Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                       : Int(b[3]) << 24 | Int(b[2]) << 16 | Int(b[1]) << 8 | Int(b[0])
        default: return nil
        }
    }

    func entry(_ tag: UInt16) -> TIFFEntry? { ifd0.first { $0.tag == tag } }

    // MARK: Building

    static func shortEntry(_ tag: UInt16, _ value: UInt16, bigEndian: Bool) -> TIFFEntry {
        let v = bigEndian ? value.bigEndian : value.littleEndian
        return TIFFEntry(tag: tag, type: 3, count: 1, value: withUnsafeBytes(of: v) { Data($0) })
    }

    mutating func setOrientation(_ orientation: Int) {
        ifd0.removeAll { $0.tag == Tag.orientation }
        ifd0.append(Self.shortEntry(Tag.orientation, UInt16(orientation), bigEndian: bigEndian))
    }

    // MARK: Writing

    /// Serialises IFD0 → Exif → Interop → GPS → IFD1 (+ thumbnail), relocating pointers and out-of-line values.
    func serialized() -> Data {
        var out = Data(bigEndian ? [0x4D, 0x4D, 0x00, 0x2A] : [0x49, 0x49, 0x2A, 0x00])
        func put32(_ v: Int, at o: Int? = nil) {
            let u = UInt32(truncatingIfNeeded: v)
            let bytes = withUnsafeBytes(of: bigEndian ? u.bigEndian : u.littleEndian) { Data($0) }
            if let o { out.replaceSubrange(o..<(o + 4), with: bytes) } else { out.append(bytes) }
        }
        func put16(_ v: Int) {
            let u = UInt16(truncatingIfNeeded: v)
            out.append(withUnsafeBytes(of: bigEndian ? u.bigEndian : u.littleEndian) { Data($0) })
        }
        put32(8)
        var patches: [(slot: Int, ifd: String)] = []        // pointer value slots to patch later
        var ifdOffsets: [String: Int] = [:]
        var thumbnailSlot: Int?
        var nextSlotIFD0: Int?

        func writeIFD(_ name: String, _ raw: [TIFFEntry], children: [UInt16: String]) {
            if out.count % 2 == 1 { out.append(0) }
            ifdOffsets[name] = out.count
            let entries = raw.filter { !Tag.pointers.contains($0.tag) || children[$0.tag] != nil }
                .sorted { $0.tag < $1.tag }
            put16(entries.count)
            let tableStart = out.count
            out.append(Data(count: 12 * entries.count + 4))
            if name == "ifd0" { nextSlotIFD0 = tableStart + 12 * entries.count }
            for (k, e) in entries.enumerated() {
                let slot = tableStart + 12 * k
                var head = Data()
                let tag = bigEndian ? e.tag.bigEndian : e.tag.littleEndian
                let type = bigEndian ? e.type.bigEndian : e.type.littleEndian
                let count = bigEndian ? e.count.bigEndian : e.count.littleEndian
                head.append(withUnsafeBytes(of: tag) { Data($0) })
                head.append(withUnsafeBytes(of: type) { Data($0) })
                head.append(withUnsafeBytes(of: count) { Data($0) })
                out.replaceSubrange(slot..<(slot + 8), with: head)
                if let child = children[e.tag] {
                    patches.append((slot + 8, child))
                } else if e.tag == Tag.thumbnailOffset && name == "ifd1" {
                    thumbnailSlot = slot + 8
                } else if e.value.count <= 4 {
                    var v = e.value
                    v.append(Data(count: 4 - v.count))
                    out.replaceSubrange((slot + 8)..<(slot + 12), with: v)
                } else {
                    if out.count % 2 == 1 { out.append(0) }
                    put32(out.count, at: slot + 8)
                    out.append(e.value)
                }
            }
        }

        var ifd0Children: [UInt16: String] = [:]
        if exif != nil { ifd0Children[Tag.exifPointer] = "exif" }
        if gps != nil { ifd0Children[Tag.gpsPointer] = "gps" }
        var ifd0Entries = ifd0.filter { !Tag.pointers.contains($0.tag) }
        if exif != nil { ifd0Entries.append(TIFFEntry(tag: Tag.exifPointer, type: 4, count: 1, value: Data(count: 4))) }
        if gps != nil { ifd0Entries.append(TIFFEntry(tag: Tag.gpsPointer, type: 4, count: 1, value: Data(count: 4))) }
        writeIFD("ifd0", ifd0Entries, children: ifd0Children)
        if var exifEntries = exif?.filter({ !Tag.pointers.contains($0.tag) }) {
            var children: [UInt16: String] = [:]
            if interop != nil {
                children[Tag.interopPointer] = "interop"
                exifEntries.append(TIFFEntry(tag: Tag.interopPointer, type: 4, count: 1, value: Data(count: 4)))
            }
            writeIFD("exif", exifEntries, children: children)
        }
        if let interop { writeIFD("interop", interop.filter { !Tag.pointers.contains($0.tag) }, children: [:]) }
        if let gps { writeIFD("gps", gps.filter { !Tag.pointers.contains($0.tag) }, children: [:]) }
        if let ifd1, let thumbnail {
            var entries = ifd1.filter { $0.tag != Tag.thumbnailOffset && $0.tag != Tag.thumbnailLength && !Tag.pointers.contains($0.tag) }
            entries.append(TIFFEntry(tag: Tag.thumbnailOffset, type: 4, count: 1, value: Data(count: 4)))
            let n = UInt32(thumbnail.count)
            entries.append(TIFFEntry(tag: Tag.thumbnailLength, type: 4, count: 1,
                                     value: withUnsafeBytes(of: bigEndian ? n.bigEndian : n.littleEndian) { Data($0) }))
            writeIFD("ifd1", entries, children: [:])
            if out.count % 2 == 1 { out.append(0) }
            if let thumbnailSlot { put32(out.count, at: thumbnailSlot) }
            out.append(thumbnail)
            if let nextSlotIFD0, let o = ifdOffsets["ifd1"] { put32(o, at: nextSlotIFD0) }
        }
        for patch in patches { if let o = ifdOffsets[patch.ifd] { put32(o, at: patch.slot) } }
        return out
    }
}
