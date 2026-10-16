// The live engine primitives (WP1): ImageIO, vImage, jpegli, libwebp, libjxl and the Metal SSIMULACRA2.
import Foundation

extension EnginePrimitives {
    /// Throws only when the GPU metric cannot be created (no Metal device, shader compile failure). The CPU oracle is
    /// deliberately not a silent fallback: at ~6 s per 45 MP score it would make every job 15× slower; callers that
    /// want it can compose `EnginePrimitives(…, metric: CPUSSIMULACRA2())` themselves.
    /// `webpTuning`: the Website encoder settings (`WebPTuning.default`; `.spec` for A/B runs).
    public static func live(webpTuning: WebPTuning = .default) throws -> EnginePrimitives {
        guard let metric = MetalSSIMULACRA2.shared else {
            _ = try MetalSSIMULACRA2()          // rethrows the real reason
            throw PrimitiveError("Metal SSIMULACRA2 is unavailable")
        }
        return EnginePrimitives(decoder: ImageIODecoder(), processing: VImageProcessing(), jpeg: JpegliEncoder(),
                                webp: LibWebPEncoder(tuning: webpTuning), jxl: LibJXLTranscoder(), metric: metric,
                                viewerDecoder: { try IslowDecoder.decode($0, width: $1, height: $2, colorSpace: $3) })
    }
}
