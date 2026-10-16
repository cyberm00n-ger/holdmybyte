// `WebPEncoding` via libwebp (`hmb_webp_*`): sharp-YUV conversion once per prepared image, then lossy encodes
// (WEBP_PRESET_PHOTO, single-threaded; method and loop filter per `WebPTuning`) with ICC/EXIF/XMP chunks assembled by
// libwebpmux.
import CHMBCodecs
import Foundation

/// A prepared (sharp-YUV converted) WebP input; owns the C picture and frees it in deinit.
public final class LibWebPPrepared: WebPPrepared, @unchecked Sendable {
    let handle: OpaquePointer
    public let width: Int, height: Int
    init(handle: OpaquePointer, width: Int, height: Int) {
        self.handle = handle
        self.width = width
        self.height = height
        super.init()
    }
    deinit { hmb_webp_release(handle) }
}

/// libwebp settings on top of WEBP_PRESET_PHOTO (sns 80, filter strength 30, sharpness 3, 4 segments). The loop
/// filter's strength and sharpness are decoder-side header fields: they change the decoded image (and so the score
/// the search verifies), not the encoder's bit allocation.
public struct WebPTuning: Sendable, Hashable, CustomStringConvertible {
    public var method: Int32
    public var filterStrength: Int32 = -1        // −1: the preset's
    public var filterSharpness: Int32 = -1
    public init(method: Int32, filterStrength: Int32 = -1, filterSharpness: Int32 = -1) {
        self.method = method; self.filterStrength = filterStrength; self.filterSharpness = filterSharpness
    }
    /// §3.5 as specified: method 4, preset filter.
    public static let spec = WebPTuning(method: 4)
    /// Variant "postpass" (Docs/variants/postpass.md): method 6, filter strength 40, sharpness 7.
    public static let postpass = WebPTuning(method: 6, filterStrength: 40, filterSharpness: 7)
    /// The live default (Docs/DECISIONS.md D-ENG-11).
    public static let `default` = postpass
    var c: hmb_webp_tuning {
        hmb_webp_tuning(method: method, sns_strength: -1, filter_strength: filterStrength, filter_sharpness: filterSharpness,
                        filter_type: -1, autofilter: -1, segments: -1, partition_limit: -1, pass: -1)
    }
    public var description: String { "m\(method) f\(filterStrength) sharp\(filterSharpness)" }
}

public struct LibWebPEncoder: WebPEncoding {
    public var tuning: WebPTuning

    public init(tuning: WebPTuning = .default) { self.tuning = tuning }

    public func prepare(_ image: PixelImage) throws -> WebPPrepared {
        var handle: OpaquePointer?
        var message = [CChar](repeating: 0, count: CodecBridge.errorCapacity)
        let status = message.withUnsafeMutableBufferPointer { err in
            hmb_webp_prepare(image.bytes, UInt32(image.width), UInt32(image.height), image.bytesPerRow,
                             &handle, err.baseAddress, err.count)
        }
        guard status == 0, let handle else {
            throw PrimitiveError("webp prepare: \(CodecBridge.errorString(message))")
        }
        return LibWebPPrepared(handle: handle, width: image.width, height: image.height)
    }

    public func encode(_ prepared: WebPPrepared, quality: Float, icc: Data?, exif: Data?, xmp: Data?) throws -> Data {
        guard let prepared = prepared as? LibWebPPrepared else { throw PrimitiveError("webp encode: not a LibWebPPrepared") }
        guard quality.isFinite, (0...100).contains(quality) else { throw PrimitiveError("webp encode: invalid quality \(quality)") }
        return try CodecBridge.withBytes(icc) { iccBytes in
            try CodecBridge.withBytes(exif) { exifBytes in
                try CodecBridge.withBytes(xmp) { xmpBytes in
                    try CodecBridge.call("webp encode") { out, err, errLen in
                        hmb_webp_encode_tuned(prepared.handle, quality, tuning.c, iccBytes, exifBytes, xmpBytes, out, err, errLen)
                    }
                }
            }
        }
    }
}
