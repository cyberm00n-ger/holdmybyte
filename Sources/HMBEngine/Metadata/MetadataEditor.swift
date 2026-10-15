// Metadata policy (§3.7). Builds the exact metadata of every delivered file before the search starts, so the
// probes are encoded with their final markers and the delivered bytes are the scored bytes (E3).
//
// | Policy         | EXIF                                           | XMP                                   | IPTC     |
// | keepAll        | verbatim                                       | verbatim                              | verbatim |
// | removeLocation | drop GPS IFD, BodySerial, LensSerial, MakerNote| drop exif:GPS*, aux:(Lens)SerialNumber,| verbatim |
// |                |                                                | exifEX:BodySerialNumber               |          |
// | removeAll      | new: Orientation, Artist, Copyright            | only dc:rights, dc:creator            | dropped  |
// ICC: the source profile verbatim, or sRGB when converted. Orientation is preserved under every policy.
import CoreGraphics
import Foundation
import HMBModel
import ImageIO

enum MetadataEditor {
    static let commentText = "holdmybyte 2.0"

    /// The metadata of one output, independent of the container.
    struct Output: Sendable, Equatable {
        var exif: Data?          // TIFF structure, no "Exif\0\0" prefix
        var xmp: Data?
        var xmpExtension: [Data] // extended XMP APP1 payloads (keepAll only), with their prefix
        var iptc: [Data]         // APP13 payloads, verbatim
        var icc: Data?
    }

    static let srgbICC: Data = (CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() as Data?) ?? Data()

    static func output(for info: SourceInfo, policy: MetadataPolicy, colour: ColourHandling) -> Output {
        let icc: Data? = colour == .convertToSRGB ? srgbICC : info.iccProfile
        let iptc = info.markers.filter { $0.code == 0xED }.map(\.payload)
        let xmpExtension = info.markers.filter { $0.code == 0xE1 && $0.payload.starts(with: JPEGContainer.xmpExtensionPrefix) }
            .map(\.payload)
        switch policy {
        case .keepAll:
            return Output(exif: ensureOrientation(info.exif, orientation: info.orientation), xmp: info.xmp,
                          xmpExtension: xmpExtension, iptc: iptc, icc: icc)
        case .removeLocation:
            return Output(exif: exifRemovingLocation(info.exif, orientation: info.orientation),
                          xmp: info.xmp.flatMap(xmpRemovingLocation), xmpExtension: [], iptc: iptc, icc: icc)
        case .removeAll:
            return Output(exif: minimalEXIF(from: info.exif, orientation: info.orientation),
                          xmp: info.xmp.flatMap(xmpKeepingRights), xmpExtension: [], iptc: [], icc: icc)
        }
    }

    /// JPEG marker order: APP1 Exif, APP1 XMP (+ extension), APP2 ICC chain, APP13, COM "holdmybyte 2.0".
    static func jpegMarkers(_ m: Output) -> [JPEGMarker] {
        var markers: [JPEGMarker] = []
        if let exif = m.exif.flatMap(exifFittingOneSegment) {
            markers.append(JPEGMarker(code: 0xE1, payload: JPEGContainer.exifPrefix + exif))
        }
        if let xmp = m.xmp, xmp.count + JPEGContainer.xmpPrefix.count <= JPEGContainer.maxPayload {
            markers.append(JPEGMarker(code: 0xE1, payload: JPEGContainer.xmpPrefix + xmp))
            markers += m.xmpExtension.filter { $0.count <= JPEGContainer.maxPayload }.map { JPEGMarker(code: 0xE1, payload: $0) }
        }
        if let icc = m.icc, !icc.isEmpty {
            markers += JPEGContainer.iccSegments(icc).map { JPEGMarker(code: $0.code, payload: $0.payload) }
        }
        markers += m.iptc.filter { $0.count <= JPEGContainer.maxPayload }.map { JPEGMarker(code: 0xED, payload: $0) }
        markers.append(JPEGMarker(code: 0xFE, payload: Data(commentText.utf8)))
        return markers
    }

    /// Keep-original copy under a policy (§3.7): verbatim for keepAll; otherwise the segments are replaced, the
    /// entropy-coded data is copied byte for byte, and embedded preview images after EOI (MPF), which carry their
    /// own unfiltered EXIF, are dropped.
    static func keptOriginal(_ info: SourceInfo, policy: MetadataPolicy) throws -> Data {
        guard policy != .keepAll else { return info.fileBytes }
        let markers = jpegMarkers(output(for: info, policy: policy, colour: .keepProfile))
            .filter { $0.code != 0xFE }                 // a kept original is not a holdmybyte encode
        return try JPEGContainer.rewrite(info.fileBytes, markers: markers.map { .init(code: $0.code, payload: $0.payload) },
                                         keepTrailingData: false)
    }

    // MARK: EXIF

    /// EXIF that fits one APP1 segment. Oversized EXIF (usually a huge MakerNote) loses the MakerNote, then the
    /// thumbnail, then everything but Orientation/Artist/Copyright, so the orientation always survives (§3.7).
    static func exifFittingOneSegment(_ exif: Data) -> Data? {
        let limit = JPEGContainer.maxPayload - JPEGContainer.exifPrefix.count
        if exif.count <= limit { return exif }
        guard var doc = try? TIFFDocument(parsing: exif) else { return nil }
        doc.exif?.removeAll { $0.tag == TIFFDocument.Tag.makerNote }
        var data = doc.serialized()
        if data.count <= limit { return data }
        doc.ifd1 = nil
        doc.thumbnail = nil
        data = doc.serialized()
        if data.count <= limit { return data }
        let orientation = doc.entry(TIFFDocument.Tag.orientation).flatMap { TIFFDocument.integer($0, big: doc.bigEndian) } ?? 1
        data = minimalEXIF(from: exif, orientation: orientation)
        return data.count <= limit ? data : orientationOnly(orientation)
    }

    static func ensureOrientation(_ exif: Data?, orientation: Int) -> Data? {
        guard let exif else { return orientation == 1 ? nil : orientationOnly(orientation) }
        guard let doc = try? TIFFDocument(parsing: exif) else { return exif }
        let stored = doc.entry(TIFFDocument.Tag.orientation).flatMap { TIFFDocument.integer($0, big: doc.bigEndian) } ?? 1
        guard stored != orientation else { return exif }
        var edited = doc
        edited.setOrientation(orientation)
        return edited.serialized()
    }

    static func exifRemovingLocation(_ exif: Data?, orientation: Int) -> Data? {
        guard let exif else { return orientation == 1 ? nil : orientationOnly(orientation) }
        guard var doc = try? TIFFDocument(parsing: exif) else { return minimalEXIF(from: nil, orientation: orientation) }
        doc.gps = nil
        doc.ifd0.removeAll { $0.tag == TIFFDocument.Tag.gpsPointer || $0.tag == TIFFDocument.Tag.subIFDs }
        let dropped: Set<UInt16> = [TIFFDocument.Tag.bodySerial, TIFFDocument.Tag.lensSerial, TIFFDocument.Tag.makerNote]
        doc.exif?.removeAll { dropped.contains($0.tag) }
        doc.setOrientation(orientation)
        return doc.serialized()
    }

    static func minimalEXIF(from exif: Data?, orientation: Int) -> Data {
        let source = exif.flatMap { try? TIFFDocument(parsing: $0) }
        var doc = TIFFDocument(bigEndian: source?.bigEndian ?? true, ifd0: [])
        doc.setOrientation(orientation)
        for tag in [TIFFDocument.Tag.artist, TIFFDocument.Tag.copyright] {
            if let e = source?.entry(tag) { doc.ifd0.append(e) }
        }
        return doc.serialized()
    }

    static func orientationOnly(_ orientation: Int) -> Data { minimalEXIF(from: nil, orientation: orientation) }

    // MARK: XMP

    static let nsExif = "http://ns.adobe.com/exif/1.0/"
    static let nsAux = "http://ns.adobe.com/exif/1.0/aux/"
    static let nsExifEX = "http://cipa.jp/exif/1.0/"

    static func xmpRemovingLocation(_ xmp: Data) -> Data? {
        guard let source = CGImageMetadataCreateFromXMPData(xmp as CFData),
              let mutable = CGImageMetadataCreateMutableCopy(source) else { return nil }
        var doomed: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(source, nil, nil) { path, tag in
            let ns = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            let drop = (ns == nsExif && name.hasPrefix("GPS"))
                || (ns == nsAux && (name == "SerialNumber" || name == "LensSerialNumber"))
                || (ns == nsExifEX && name == "BodySerialNumber")
            if drop { doomed.append(path as String) }
            return true
        }
        guard !doomed.isEmpty else { return xmp }               // nothing to remove: keep the bytes verbatim
        for path in doomed { CGImageMetadataRemoveTagWithPath(mutable, nil, path as CFString) }
        return CGImageMetadataCreateXMPData(mutable, nil) as Data?
    }

    static func xmpKeepingRights(_ xmp: Data) -> Data? {
        guard let source = CGImageMetadataCreateFromXMPData(xmp as CFData) else { return nil }
        let out = CGImageMetadataCreateMutable()
        var any = false
        for path in ["dc:rights", "dc:creator"] {
            if let tag = CGImageMetadataCopyTagWithPath(source, nil, path as CFString) {
                any = CGImageMetadataSetTagWithPath(out, nil, path as CFString, tag) || any
            }
        }
        return any ? CGImageMetadataCreateXMPData(out, nil) as Data? : nil
    }
}
