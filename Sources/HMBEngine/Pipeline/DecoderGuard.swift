// Decoder guard (Docs/DECISIONS.md D-ENG-12). The engine scores candidates as ImageIO decodes them (SPEC E6), and
// browsers decode JPEG with libjpeg-turbo. The two disagree by up to ±0.5 points on the same file, in both directions:
// on the wedding (535 photos, eng-v3 outputs) libjpeg-turbo read 3 Couple files (4:2:0) and 59 Social files (4:4:4)
// below the floor ImageIO had certified (by up to 0.015 and 0.153). With the guard, a JPEG candidate that passes under
// ImageIO is decoded a second time the way libjpeg-turbo does it (`IslowDecoder`, identical pixels to djpeg) and
// scored against the same reference; the lower score is the candidate's score everywhere (search, post-pass,
// journal, receipt). WebP needs no guard: ImageIO's WebP pixels are libwebp's.
import CoreGraphics
import Foundation
import HMBModel

public enum DecoderGuard: String, Sendable, Hashable, CaseIterable {
    /// ImageIO only (eng-v3 and earlier).
    case off
    /// Second decode for 4:4:4 JPEG candidates only (Social, 4:4:4 fail-open, fallbacks), where most of the
    /// disagreement is (holdout 2/19, wedding 59/535 below); leaves 4:2:0 (wedding 3/535 below) unguarded.
    case chroma444
    /// Second decode for every JPEG candidate. Default.
    case all

    func applies(to chroma: ChromaSubsampling?) -> Bool {
        switch self {
        case .off: false
        case .chroma444: chroma == .s444
        case .all: chroma != nil
        }
    }

    /// The candidate's score under the guard: `imageIO` (its ImageIO score) unless it reaches `target`, the guard
    /// applies to `chroma`, a `viewer` decoder exists (`EnginePrimitives.viewerDecoder`) and its decode reads lower.
    /// `decode` wraps the second decode (slots, spans); `score` scores it against the candidate's reference.
    func score(_ imageIO: Double, target: Double, chroma: ChromaSubsampling?, data: Data, width: Int, height: Int,
               colorSpace: CGColorSpace, viewer: EnginePrimitives.ViewerJPEGDecode?,
               decode: (() throws -> PixelImage?) throws -> PixelImage?,
               score: (PixelImage) throws -> Double) throws -> Double {
        guard imageIO >= target, applies(to: chroma), let viewer,
              let second = try decode({ try viewer(data, width, height, colorSpace) })
        else { return imageIO }
        return min(imageIO, try score(second))
    }
}
