// Decoder guard (Docs/DECISIONS.md D-ENG-12): the pixels libjpeg-turbo's default decompressor (djpeg; Chrome, Firefox,
// Edge) shows for a JPEG, decoded in process by `hmb_jpeg_decode_islow` (jpegli reads the coefficients; ISLOW IDCT,
// fancy upsampling and libjpeg's colour tables are reimplemented in the bridge). Test: `IslowDecodeTests` (= djpeg).
import CHMBCodecs
import CoreGraphics
import Foundation

public enum IslowDecoder {
    /// `jpeg` decoded like libjpeg-turbo into `width` × `height` RGBX in `colorSpace` (the caller knows the size from
    /// its own decode); nil when the layout is not 8-bit YCbCr 4:4:4 or 4:2:0 (every jpegli output is).
    public static func decode(_ jpeg: Data, width: Int, height: Int, colorSpace: CGColorSpace) throws -> PixelImage? {
        let image = PixelImage(width: width, height: height, colorSpace: colorSpace)
        var message = [CChar](repeating: 0, count: CodecBridge.errorCapacity)
        let status = jpeg.withUnsafeBytes { raw in
            message.withUnsafeMutableBufferPointer { err in
                hmb_jpeg_decode_islow(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                      image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(width),
                                      UInt32(height), image.bytesPerRow, err.baseAddress, err.count)
            }
        }
        if status == 1 { return nil }
        guard status == 0 else { throw PrimitiveError("islow decode: \(CodecBridge.errorString(message))") }
        return image
    }
}
