// Acceptance §5.2.7: metadata policies (parsed back with ImageIO), orientation, lossless rewrite of kept originals.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBFixtures
import HMBModel
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct MetadataTests {
    static let xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
    <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
    xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" xmlns:exifEX="http://cipa.jp/exif/1.0/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \
    exif:GPSLatitude="52,31.2N" exif:GPSLongitude="13,24.6E" aux:SerialNumber="123456" aux:LensSerialNumber="LENS999" \
    exifEX:BodySerialNumber="123456" xmp:CreatorTool="Lightroom Classic">\
    <dc:creator><rdf:Seq><rdf:li>Sebastian Haas</rdf:li></rdf:Seq></dc:creator>\
    <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© Sebastian Haas</rdf:li></rdf:Alt></dc:rights>\
    </rdf:Description></rdf:RDF></x:xmpmeta>
    """

    /// A real JPEG with EXIF (incl. serials), GPS, IPTC, orientation 6 and an XMP packet.
    static func richJPEG(in dir: TempDir) throws -> URL {
        let plain = dir.url.appending(path: "plain.jpg")
        Synth.jpeg(at: plain, width: 160, height: 96, seed: 3, date: "2026:07:12 15:30:00", model: "X1", extra: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Sebastian Haas",
                                             kCGImagePropertyTIFFCopyright: "© Sebastian Haas"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "123456",
                                             kCGImagePropertyExifLensSerialNumber: "LENS999",
                                             kCGImagePropertyExifISOSpeedRatings: [400]],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.52, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 13.41, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Berlin"],
        ])
        // Insert the XMP packet as an APP1 segment right after the existing APPn segments.
        let data = try Data(contentsOf: plain)
        let parsed = try JPEGContainer.parse(data)
        var out = Data([0xFF, 0xD8])
        var inserted = false
        // ImageIO writes an XMP mirror of the IPTC/EXIF properties; replace it with the Lightroom-like packet.
        for s in parsed.segments where !(s.code == 0xE1 && s.payload.starts(with: JPEGContainer.xmpPrefix)) {
            if !inserted, !(0xE0...0xEF).contains(s.code) {
                try JPEGContainer.append(.init(code: 0xE1, payload: JPEGContainer.xmpPrefix + Data(xmp.utf8)), to: &out)
                inserted = true
            }
            try JPEGContainer.append(s, to: &out)
        }
        out.append(data.subdata(in: parsed.scanOffset..<data.count))
        let url = dir.url.appending(path: "rich.jpg")
        try out.write(to: url)
        return url
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    static func xmpTags(_ data: Data) throws -> Set<String> {
        guard let segment = try JPEGContainer.parse(data).segments.first(where: {
            $0.code == 0xE1 && $0.payload.starts(with: JPEGContainer.xmpPrefix)
        }) else { return [] }
        let metadata = try #require(CGImageMetadataCreateFromXMPData(segment.payload.dropFirst(JPEGContainer.xmpPrefix.count) as CFData))
        var tags = Set<String>()
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in tags.insert(path as String); return true }
        return tags.filter { !$0.hasPrefix("iio:") }      // ImageIO's own bookkeeping tag
    }

    static func pixels(_ data: Data) -> [UInt8] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    @Test func sourceFixtureCarriesEverything() throws {
        let dir = TempDir("meta")
        let data = try Data(contentsOf: try Self.richJPEG(in: dir))
        let p = Self.properties(data)
        #expect(p[kCGImagePropertyGPSDictionary] != nil)
        #expect(p[kCGImagePropertyIPTCDictionary] != nil)
        #expect((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifBodySerialNumber] != nil)
        #expect(try JPEGContainer.parse(data).segments.filter { $0.code == 0xE1 && $0.payload.starts(with: JPEGContainer.xmpPrefix) }.count == 1)
        let tags = try Self.xmpTags(data)
        #expect(tags.contains("aux:SerialNumber") && tags.contains("exif:GPSLatitude") && tags.contains("dc:rights"))
    }

    @Test func keepAllIsVerbatim() throws {
        let dir = TempDir("meta")
        let url = try Self.richJPEG(in: dir)
        let info = try FakeDecoder().inspect(url)
        #expect(try MetadataEditor.keptOriginal(info, policy: .keepAll) == Data(contentsOf: url))
    }

    @Test func removeLocationDropsExactlyLocationAndSerials() throws {
        let dir = TempDir("meta")
        let url = try Self.richJPEG(in: dir)
        let source = try Data(contentsOf: url)
        let info = try FakeDecoder().inspect(url)
        let out = try MetadataEditor.keptOriginal(info, policy: .removeLocation)
        let p = Self.properties(out)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        let exif = try #require(p[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifBodySerialNumber] == nil)
        #expect(exif[kCGImagePropertyExifLensSerialNumber] == nil)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:07:12 15:30:00")
        #expect(exif[kCGImagePropertyExifISOSpeedRatings] != nil)
        let tiff = try #require(p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(tiff[kCGImagePropertyTIFFModel] as? String == "X1")
        #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "Sebastian Haas")
        #expect(p[kCGImagePropertyOrientation] as? Int == 6)
        #expect((p[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCity] as? String == "Berlin")
        let tags = try Self.xmpTags(out)
        #expect(!tags.contains { $0.hasPrefix("exif:GPS") })
        #expect(!tags.contains("aux:SerialNumber") && !tags.contains("aux:LensSerialNumber"))
        #expect(!tags.contains("exifEX:BodySerialNumber"))
        #expect(tags.contains("dc:creator") && tags.contains("dc:rights") && tags.contains("xmp:CreatorTool"))
        #expect(Self.pixels(out) == Self.pixels(source))
        #expect(try JPEGContainer.parse(out).segments.contains { $0.code == 0xDB })        // tables kept
    }

    @Test func removeAllKeepsOnlyOrientationArtistCopyrightAndRights() throws {
        let dir = TempDir("meta")
        let url = try Self.richJPEG(in: dir)
        let source = try Data(contentsOf: url)
        let info = try FakeDecoder().inspect(url)
        let out = try MetadataEditor.keptOriginal(info, policy: .removeAll)
        let p = Self.properties(out)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect(try !JPEGContainer.parse(out).segments.contains { $0.code == 0xED })   // IPTC dropped
        #expect((p[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCity] == nil)
        #expect(p[kCGImagePropertyOrientation] as? Int == 6)
        let tiff = try #require(p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(tiff[kCGImagePropertyTIFFModel] == nil)
        #expect(tiff[kCGImagePropertyTIFFArtist] as? String == "Sebastian Haas")
        #expect(tiff[kCGImagePropertyTIFFCopyright] as? String == "© Sebastian Haas")
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(exif[kCGImagePropertyExifBodySerialNumber] == nil)
        // The rebuilt EXIF holds exactly these three IFD0 tags.
        let exifPayload = try #require(info.exif)
        let rebuilt = try TIFFDocument(parsing: MetadataEditor.minimalEXIF(from: exifPayload, orientation: 6))
        #expect(Set(rebuilt.ifd0.map(\.tag)) == [0x0112, 0x013B, 0x8298])
        #expect(rebuilt.exif == nil && rebuilt.gps == nil && rebuilt.ifd1 == nil)
        #expect(try Self.xmpTags(out) == ["dc:creator", "dc:rights"])
        #expect(Self.pixels(out) == Self.pixels(source))
    }

    @Test func markerOrderAndICC() throws {
        let dir = TempDir("meta")
        let url = try Self.richJPEG(in: dir)
        let info = try FakeDecoder().inspect(url)
        let output = MetadataEditor.output(for: info, policy: .removeLocation, colour: .convertToSRGB)
        #expect(output.icc == MetadataEditor.srgbICC)
        let markers = MetadataEditor.jpegMarkers(output)
        #expect(markers.map(\.code) == [0xE1, 0xE1] + Array(repeating: 0xE2, count: markers.count - 4) + [0xED, 0xFE])
        #expect(markers[0].payload.starts(with: JPEGContainer.exifPrefix))
        #expect(markers[1].payload.starts(with: JPEGContainer.xmpPrefix))
        #expect(markers.last?.payload == Data("holdmybyte 2.0".utf8))
        // The P3 fixture keeps its own profile under keepProfile.
        let p3 = try FakeDecoder().inspect(HMBFixturesFiles.rampsP3)
        let kept = MetadataEditor.output(for: p3, policy: .keepAll, colour: .keepProfile)
        #expect(kept.icc == p3.iccProfile && kept.icc != nil)
    }

    @Test func orientationIsPreservedUnderEveryPolicy() throws {
        let fixture = try FakeDecoder().inspect(HMBFixturesFiles.orientation6)
        #expect(fixture.orientation == 6)
        for policy in [MetadataPolicy.keepAll, .removeLocation, .removeAll] {
            let out = try MetadataEditor.keptOriginal(fixture, policy: policy)
            #expect(Self.properties(out)[kCGImagePropertyOrientation] as? Int == 6, "\(policy)")
            let exif = try #require(MetadataEditor.output(for: fixture, policy: policy, colour: .convertToSRGB).exif)
            let doc = try TIFFDocument(parsing: exif)
            #expect(doc.entry(0x0112).flatMap { TIFFDocument.integer($0, big: doc.bigEndian) } == 6)
        }
        // A source without EXIF but with an orientation gets a minimal EXIF carrying it.
        var bare = fixture
        bare.exif = nil
        bare.orientation = 8
        let synthesized = try #require(MetadataEditor.output(for: bare, policy: .keepAll, colour: .keepProfile).exif)
        let doc = try TIFFDocument(parsing: synthesized)
        #expect(doc.entry(0x0112).flatMap { TIFFDocument.integer($0, big: doc.bigEndian) } == 8)
    }

    @Test func tiffEditorDropsMakerNoteAndThumbnail() throws {
        // Little-endian TIFF: IFD0 (Model, ExifIFD, GPS) → ExifIFD (MakerNote, BodySerial, ISO) → GPS → IFD1 + thumbnail.
        var doc = TIFFDocument(bigEndian: false, ifd0: [
            TIFFEntry(tag: 0x0110, type: 2, count: 8, value: Data("Camera1\0".utf8)),
        ])
        doc.exif = [
            TIFFEntry(tag: 0x8827, type: 3, count: 1, value: Data([0x90, 0x01])),
            TIFFEntry(tag: 0x927C, type: 7, count: 12, value: Data("MAKERNOTE...".utf8)),
            TIFFEntry(tag: 0xA431, type: 2, count: 7, value: Data("123456\0".utf8)),
        ]
        doc.gps = [TIFFEntry(tag: 0x0001, type: 2, count: 2, value: Data("N\0".utf8))]
        doc.ifd1 = [TIFFEntry(tag: 0x0103, type: 3, count: 1, value: Data([6, 0]))]
        doc.thumbnail = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let bytes = doc.serialized()
        let parsed = try TIFFDocument(parsing: bytes)
        #expect(parsed.exif?.map(\.tag).sorted() == [0x8827, 0x927C, 0xA431])
        #expect(parsed.gps?.first?.value == Data("N\0".utf8))
        #expect(parsed.thumbnail == doc.thumbnail)
        let edited = try TIFFDocument(parsing: try #require(MetadataEditor.exifRemovingLocation(bytes, orientation: 1)))
        #expect(edited.gps == nil)
        #expect(edited.exif?.map(\.tag) == [0x8827])
        #expect(edited.thumbnail == nil && edited.ifd1 == nil)                     // D-ENG-8: no embedded preview
        #expect(try TIFFDocument(parsing: try #require(MetadataEditor.ensureOrientation(bytes, orientation: 1))).thumbnail
                == doc.thumbnail)                                                  // keepAll keeps it
        #expect(edited.entry(0x0110)?.value == Data("Camera1\0".utf8))
        // ImageIO can read what we write.
        let probe = try #require(CGImageSourceCreateWithData(Self.wrapEXIF(MetadataEditor.exifRemovingLocation(bytes, orientation: 3)!) as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(probe, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyOrientation] as? Int == 3)
    }

    @Test func removeLocationDropsPhotoshopThumbnailsAndKeepsIPTC() throws {
        func resource(_ id: UInt16, name: [UInt8] = [], _ body: [UInt8]) -> Data {
            var r = Data("8BIM".utf8) + Data([UInt8(id >> 8), UInt8(id & 0xFF), UInt8(name.count)] + name)
            if (1 + name.count) % 2 == 1 { r.append(0) }
            r += Data([0, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body)
            if body.count % 2 == 1 { r.append(0) }
            return r
        }
        let iptc = resource(0x0404, [0x1C, 0x02, 0x5A, 0x00, 0x06] + Array("Berlin".utf8))
        let resolution = resource(0x03ED, name: Array("r".utf8), [0, 72, 0, 0, 0, 1, 0, 1, 0, 72, 0, 0, 0, 1, 0, 1])
        let payload = MetadataEditor.irbPrefix + resolution + resource(0x040C, Array(repeating: 0xAB, count: 301)) + iptc
            + resource(0x0409, [1, 2, 3])
        #expect(MetadataEditor.irbRemovingThumbnails(payload) == MetadataEditor.irbPrefix + resolution + iptc)
        #expect(MetadataEditor.irbRemovingThumbnails(MetadataEditor.irbPrefix + iptc) == MetadataEditor.irbPrefix + iptc)
        #expect(MetadataEditor.irbRemovingThumbnails(MetadataEditor.irbPrefix + resource(0x040C, [9])) == nil)
        let garbage = MetadataEditor.irbPrefix + Data("8BIM\u{4}".utf8)
        #expect(MetadataEditor.irbRemovingThumbnails(garbage) == garbage)                  // unparseable: verbatim
    }

    /// A tiny JPEG whose APP1 Exif is `tiff`.
    static func wrapEXIF(_ tiff: Data) throws -> Data {
        let dir = TempDir("wrap")
        let url = dir.url.appending(path: "w.jpg")
        Synth.jpeg(at: url, width: 16, height: 16)
        let info = try FakeDecoder().inspect(url)
        return try JPEGContainer.rewrite(info.fileBytes, markers: [.init(code: 0xE1, payload: JPEGContainer.exifPrefix + tiff)])
    }
}

typealias HMBFixturesFiles = TestFixtureFiles
