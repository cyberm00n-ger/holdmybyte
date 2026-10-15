// Swift side of the CHMBCodecs C bridge: error buffers and ownership transfer of `hmb_buffer`s.
import CHMBCodecs
import Foundation

enum CodecBridge {
    /// Size of the error message buffer handed to every `hmb_*` call (the header requires ≥ 256).
    static let errorCapacity = 512

    /// Calls a bridge function that fills an `hmb_buffer`; returns the bytes as `Data` that owns the malloc'ed
    /// memory (no copy), or throws the bridge's message prefixed with `operation`.
    static func call(_ operation: String,
                     _ body: (UnsafeMutablePointer<hmb_buffer>, UnsafeMutablePointer<CChar>, Int) -> Int32) throws -> Data {
        var buffer = hmb_buffer(data: nil, size: 0)
        var message = [CChar](repeating: 0, count: errorCapacity)
        let status = message.withUnsafeMutableBufferPointer { body(&buffer, $0.baseAddress!, $0.count) }
        guard status == 0 else {
            hmb_buffer_free(&buffer)
            throw PrimitiveError("\(operation): \(errorString(message))")
        }
        guard let data = buffer.data, buffer.size > 0 else {
            hmb_buffer_free(&buffer)
            throw PrimitiveError("\(operation): empty output")
        }
        return Data(bytesNoCopy: data, count: buffer.size, deallocator: .free)
    }

    static func errorString(_ message: [CChar]) -> String {
        let text = message.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return text.isEmpty ? "unknown error" : text
    }

    /// Runs `body` with a borrowed `hmb_bytes` view of `data` (empty → NULL/0).
    static func withBytes<R>(_ data: Data?, _ body: (hmb_bytes) throws -> R) rethrows -> R {
        guard let data, !data.isEmpty else { return try body(hmb_bytes(data: nil, size: 0)) }
        return try data.withUnsafeBytes { raw in
            try body(hmb_bytes(data: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count))
        }
    }
}

extension PixelImage {
    /// Read-only byte pointer to the first pixel.
    var bytes: UnsafePointer<UInt8> { UnsafePointer(pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
}
