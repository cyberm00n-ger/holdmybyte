// `JXLTranscoding` via libjxl (`hmb_jxl_*`): lossless JPEG → JPEG XL transcode with reconstruction data, and the
// byte-exact reconstruction used to verify every archive file (§3.6).
import CHMBCodecs
import Foundation

public struct LibJXLTranscoder: JXLTranscoding {
    /// Threads per transcode / reconstruction (libjxl's output is identical for any count; Docs/variants/speed.md).
    public var threads: Int

    public init(threads: Int = LibJXLTranscoder.defaultThreads) { self.threads = max(1, threads) }

    /// 4 (HMB_JXL_THREADS overrides it for tuning runs): a 45 MP transcode scales to ~1.7× and its verification to
    /// ~2× on 4 threads at the same CPU time, which fills the cores the lossy workers leave idle (GPU lane, slots) and
    /// shortens the archive tail of a job.
    public static let defaultThreads: Int = {
        if let value = ProcessInfo.processInfo.environment["HMB_JXL_THREADS"].flatMap(Int.init), value > 0 { return min(16, value) }
        return 4
    }()

    public func transcodeLossless(jpeg: Data, effort: Int) throws -> Data {
        guard (1...10).contains(effort) else { throw PrimitiveError("jxl transcode: invalid effort \(effort)") }
        return try jpeg.withUnsafeBytes { raw in
            try CodecBridge.call("jxl transcode") { out, err, errLen in
                hmb_jxl_transcode_jpeg_threads(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, Int32(effort),
                                               Int32(threads), out, err, errLen)
            }
        }
    }

    public func reconstructJPEG(jxl: Data) throws -> Data {
        try jxl.withUnsafeBytes { raw in
            try CodecBridge.call("jxl reconstruct") { out, err, errLen in
                hmb_jxl_reconstruct_jpeg_threads(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, Int32(threads),
                                                 out, err, errLen)
            }
        }
    }
}
