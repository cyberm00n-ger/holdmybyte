// `JPEGEncoding` via the in-process jpegli encoder (`hmb_jpegli_encode`): progressive level 2 (or an explicit
// per-component AC script, variant "postpass"), adaptive quantisation on, optimised Huffman tables; the output
// carries exactly the given APPn/COM markers, in order.
import CHMBCodecs
import Foundation
import HMBModel

public struct JpegliEncoder: JPEGEncoding {
    /// Progressive level of every delivered and probed JPEG (§3.0 E3). Exposed for the equivalence test.
    public var progressiveLevel: Int32 = 2

    public init() {}

    public func encode(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling,
                       markers: [JPEGMarker]) throws -> Data {
        try encode(image, distance: distance, subsampling: subsampling, markers: markers, scans: nil)
    }

    public func chooseScans(_ encoded: Data) throws -> JPEGScanChoice? { try JPEGPostPass.chooseScans(encoded) }

    public func encode(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling,
                       markers: [JPEGMarker], scans: JPEGScanChoice?) throws -> Data {
        guard distance.isFinite, (0...25).contains(distance) else { throw PrimitiveError("jpegli: invalid distance \(distance)") }
        // All payloads in one contiguous array, so a single pointer stays valid for the whole C call.
        var storage = [UInt8]()
        storage.reserveCapacity(markers.reduce(0) { $0 + $1.payload.count })
        var ranges: [(offset: Int, count: Int)] = []
        for marker in markers {
            ranges.append((storage.count, marker.payload.count))
            storage.append(contentsOf: marker.payload)
        }
        return try storage.withUnsafeBufferPointer { all in
            let cMarkers = zip(markers, ranges).map { marker, range in
                hmb_marker(code: marker.code,
                           payload: hmb_bytes(data: range.count > 0 ? all.baseAddress! + range.offset : nil, size: range.count))
            }
            return try cMarkers.withUnsafeBufferPointer { cMarkers in
                let choice: [Int32]? = scans.map { [Int32($0.y), Int32($0.cb), Int32($0.cr)] }
                return try CodecBridge.call("jpegli encode") { out, err, errLen in
                    if let choice {
                        return choice.withUnsafeBufferPointer { c in
                            hmb_jpegli_encode_scans(image.bytes, UInt32(image.width), UInt32(image.height), image.bytesPerRow,
                                                    Float(distance), subsampling == .s444 ? 1 : 0, progressiveLevel, c.baseAddress,
                                                    cMarkers.baseAddress, cMarkers.count, out, err, errLen)
                        }
                    }
                    return hmb_jpegli_encode(image.bytes, UInt32(image.width), UInt32(image.height), image.bytesPerRow,
                                             Float(distance), subsampling == .s444 ? 1 : 0, progressiveLevel,
                                             cMarkers.baseAddress, cMarkers.count, out, err, errLen)
                }
            }
        }
    }
}
