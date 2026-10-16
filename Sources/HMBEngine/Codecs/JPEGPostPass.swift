// Lossless JPEG post-pass (variant "postpass", Docs/variants/postpass.md): after the search has fixed a JPEG's
// coefficients, the progressive scan script is re-chosen per component (`hmb_jpeg_optimize_scans`). The rewrite keeps
// every quantised coefficient, table and APPn/COM segment, so the decoded pixels — and therefore the score the search
// verified — are unchanged; only the entropy-coded bytes shrink.
import CHMBCodecs
import Foundation

public enum JPEGPostPass {
    /// The smaller rewrite of `jpeg`, or nil when the input is not a progressive 3-component JPEG with its APPn/COM
    /// segments in front, or when the rewrite would not be smaller.
    public static func optimizeScans(_ jpeg: Data) throws -> Data? {
        var buffer = hmb_buffer(data: nil, size: 0)
        var message = [CChar](repeating: 0, count: CodecBridge.errorCapacity)
        let status = jpeg.withUnsafeBytes { raw in
            message.withUnsafeMutableBufferPointer { err in
                hmb_jpeg_optimize_scans(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &buffer, err.baseAddress, err.count)
            }
        }
        guard status == 0 else {
            hmb_buffer_free(&buffer)
            throw PrimitiveError("jpeg post-pass: \(CodecBridge.errorString(message))")
        }
        guard let data = buffer.data, buffer.size > 0 else { return nil }
        return Data(bytesNoCopy: data, count: buffer.size, deallocator: .free)
    }

    /// The per-component AC script the post-pass would choose for `jpeg` (level 2 for every component when the
    /// input is not eligible).
    public static func chooseScans(_ jpeg: Data) throws -> JPEGScanChoice {
        var choice: [Int32] = [0, 0, 0]
        var message = [CChar](repeating: 0, count: CodecBridge.errorCapacity)
        let status = jpeg.withUnsafeBytes { raw in
            message.withUnsafeMutableBufferPointer { err in
                choice.withUnsafeMutableBufferPointer { c in
                    hmb_jpeg_choose_scans(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, c.baseAddress, err.baseAddress, err.count)
                }
            }
        }
        guard status == 0 else { throw PrimitiveError("jpeg scan choice: \(CodecBridge.errorString(message))") }
        return JPEGScanChoice(y: Int(choice[0]), cb: Int(choice[1]), cr: Int(choice[2]))
    }

    /// Zeroes isolated ±1 AC coefficients (lossy: the caller re-scores) and/or chooses the scan script; returns the
    /// rewrite whether or not it is smaller, nil when the input is not a progressive 3-component JPEG with its APPn/COM
    /// segments in front. `minK` 0 disables zeroing; `componentMask` bit c selects component c (1 = Y only, 7 = all).
    public static func rewrite(_ jpeg: Data, minK: Int, minRun: Int, componentMask: Int, optimizeScans: Bool,
                               force: JPEGScanChoice? = nil) throws -> Data? {
        let packed = force.map { Int32($0.y) + 4 * Int32($0.cb) + 16 * Int32($0.cr) } ?? -1
        let options = hmb_jpeg_rewrite_options(zero_min_k: Int32(minK), zero_min_run: Int32(minRun),
                                               component_mask: Int32(componentMask), optimize_scans: optimizeScans ? 1 : 0,
                                               force_choice: packed)
        var buffer = hmb_buffer(data: nil, size: 0)
        var message = [CChar](repeating: 0, count: CodecBridge.errorCapacity)
        let status = jpeg.withUnsafeBytes { raw in
            message.withUnsafeMutableBufferPointer { err in
                hmb_jpeg_rewrite(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, options, &buffer, err.baseAddress, err.count)
            }
        }
        guard status == 0 else {
            hmb_buffer_free(&buffer)
            throw PrimitiveError("jpeg rewrite: \(CodecBridge.errorString(message))")
        }
        guard let data = buffer.data, buffer.size > 0 else { return nil }
        return Data(bytesNoCopy: data, count: buffer.size, deallocator: .free)
    }
}

extension LibWebPEncoder {
    /// WEBP_PRESET_PHOTO with overrides (negative = preset value), same input and metadata as `encode`.
    public func encodeTuned(_ prepared: WebPPrepared, quality: Float, tuning: hmb_webp_tuning, icc: Data?, exif: Data?,
                            xmp: Data?) throws -> Data {
        guard let prepared = prepared as? LibWebPPrepared else { throw PrimitiveError("webp encode: not a LibWebPPrepared") }
        return try CodecBridge.withBytes(icc) { iccBytes in
            try CodecBridge.withBytes(exif) { exifBytes in
                try CodecBridge.withBytes(xmp) { xmpBytes in
                    try CodecBridge.call("webp encode") { out, err, errLen in
                        hmb_webp_encode_tuned(prepared.handle, quality, tuning, iccBytes, exifBytes, xmpBytes, out, err, errLen)
                    }
                }
            }
        }
    }
}

enum ImageCompare {
    /// Same size and the same R, G, B bytes in every pixel (the ignored X byte is not compared).
    static func identical(_ a: PixelImage, _ b: PixelImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let rowBytes = a.width * 4
        for y in 0..<a.height {
            let ra = a.bytes + y * a.bytesPerRow, rb = b.bytes + y * b.bytesPerRow
            if memcmp(ra, rb, rowBytes) == 0 { continue }
            for x in 0..<rowBytes where x % 4 != 3 && ra[x] != rb[x] { return false }
        }
        return true
    }
}
