// Texture features, ported verbatim (same sampling, same arithmetic, same order) from
// jpegos/Sources/SqueezeCore/GrainEstimator.swift: `statistics(of:).p50` and `chromaEnergy(of:)`. The only change is
// row addressing through `bytesPerRow` (the old buffer was packed); the values are identical.
import Foundation

enum GrainFeatures {
    /// Median of the per-block mean absolute 4-neighbour high-pass response on luma (16×16 blocks, sampled).
    /// Drives the Balanced target (§3.3): `textureP50 < 4.5 ? 74 : clamp(88 − 0.62 · p50, 75…87)`.
    static func textureP50(_ image: PixelImage) -> Double {
        var scores = blockScores(image)
        guard !scores.isEmpty else { return 0 }
        scores.sort()
        return scores[scores.count / 2]
    }

    static func blockScores(_ image: PixelImage) -> [Double] {
        let width = image.width, height = image.height
        let block = 16
        guard width > block + 16, height > block + 16 else { return [] }
        let step = max(block, min(width, height) / 40)
        let stride = image.bytesPerRow
        let pixels = image.bytes
        var scores: [Double] = []

        func luma(_ x: Int, _ y: Int) -> Double {
            let p = pixels + y * stride + x * 4
            return 0.299 * Double(p[0]) + 0.587 * Double(p[1]) + 0.114 * Double(p[2])
        }
        var y = 8
        while y + block < height - 8 {
            var x = 8
            while x + block < width - 8 {
                var sum = 0.0
                for blockY in 0..<block {
                    for blockX in 0..<block {
                        let px = x + blockX, py = y + blockY
                        let center = luma(px, py)
                        let neighbours = (luma(px - 1, py) + luma(px + 1, py) + luma(px, py - 1) + luma(px, py + 1)) * 0.25
                        sum += abs(center - neighbours)
                    }
                }
                scores.append(sum / Double(block * block))
                x += step
            }
            y += step
        }
        return scores
    }

    /// Mean absolute horizontal gradient of the opponent-colour channels (R−G, (R+G)/2−B), sparsely sampled.
    /// High values mark chroma-critical images (§3.0 E2 gate).
    static func chromaEnergy(_ image: PixelImage) -> Double {
        let width = image.width, height = image.height
        guard width > 32, height > 32 else { return 0 }
        let step = max(4, min(width, height) / 512)
        let stride = image.bytesPerRow
        let pixels = image.bytes
        var sum = 0.0
        var count = 0
        func opponents(_ x: Int, _ y: Int) -> (Double, Double) {
            let p = pixels + y * stride + x * 4
            let r = Double(p[0]), g = Double(p[1]), b = Double(p[2])
            return (r - g, (r + g) * 0.5 - b)
        }
        var y = 1
        while y < height - 1 {
            var x = 1
            while x < width - 2 {
                let (c1a, c2a) = opponents(x, y)
                let (c1b, c2b) = opponents(x + 1, y)
                sum += abs(c1b - c1a) + abs(c2b - c2a)
                count += 1
                x += step
            }
            y += step
        }
        return count > 0 ? sum / Double(count) : 0
    }
}
