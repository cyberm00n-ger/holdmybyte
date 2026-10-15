// `WebPEncoding` via libwebp (`hmb_webp_*`): sharp-YUV conversion once per prepared image, then lossy encodes
// (WEBP_PRESET_PHOTO, method 4, single-threaded) with ICC/EXIF/XMP chunks assembled by libwebpmux.
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

public struct LibWebPEncoder: WebPEncoding {
    /// libwebp `method` (§3.5: 4).
    public var method: Int32 = 4

    public init() {}

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
                        hmb_webp_encode(prepared.handle, quality, method, iccBytes, exifBytes, xmpBytes, out, err, errLen)
                    }
                }
            }
        }
    }
}
