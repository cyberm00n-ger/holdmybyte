// `JXLTranscoding` via libjxl (`hmb_jxl_*`): lossless JPEG → JPEG XL transcode with reconstruction data, and the
// byte-exact reconstruction used to verify every archive file (§3.6).
import CHMBCodecs
import Foundation

public struct LibJXLTranscoder: JXLTranscoding {
    public init() {}

    public func transcodeLossless(jpeg: Data, effort: Int) throws -> Data {
        guard (1...10).contains(effort) else { throw PrimitiveError("jxl transcode: invalid effort \(effort)") }
        return try jpeg.withUnsafeBytes { raw in
            try CodecBridge.call("jxl transcode") { out, err, errLen in
                hmb_jxl_transcode_jpeg(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, Int32(effort), out, err, errLen)
            }
        }
    }

    public func reconstructJPEG(jxl: Data) throws -> Data {
        try jxl.withUnsafeBytes { raw in
            try CodecBridge.call("jxl reconstruct") { out, err, errLen in
                hmb_jxl_reconstruct_jpeg(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, out, err, errLen)
            }
        }
    }
}
