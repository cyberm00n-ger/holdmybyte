// SSIMULACRA 2, CPU implementation: the test oracle for the Metal port (Docs/METRIC.md).
//
// Ported from jpegos/Sources/SqueezeCore/Metrics/SSIMULACRA2.swift and GaussianBlur.swift (themselves a port of
// libjxl tools/ssimulacra2.cc, BSD-3-Clause, the JPEG XL Project Authors: the algorithm, its constants and the
// 108 weights are theirs). Kept bit-for-bit in semantics: the 8-bit samples are read as sRGB-encoded whatever the
// image's colour space, the blur is the truncated FIR Gaussian (sigma 1.5, radius 6) instead of libjxl's IIR
// approximation, and the scale loop checks the size of the previous level before downsampling (so a level under
// 8 px can still be measured, as in the reference). Alpha is ignored: `PixelImage` is always opaque.
//
// About 6 s for a 45 MP pair: never on the hot path.
import Accelerate
import Foundation

public enum SSIMULACRA2 {
    static let kC2: Float = 0.0009
    static let numScales = 6
    /// FIR Gaussian shared with the Metal port: sigma 1.5, radius 6, normalised, built in Float.
    static let blurKernel: [Float] = {
        let sigma: Float = 1.5
        let radius = Int((sigma * 4).rounded(.up))
        var weights = [Float](repeating: 0, count: radius * 2 + 1)
        let denominator = 2 * sigma * sigma
        var total: Float = 0
        for offset in -radius...radius {
            let value = exp(-Float(offset * offset) / denominator)
            weights[offset + radius] = value
            total += value
        }
        for index in weights.indices { weights[index] /= total }
        return weights
    }()
    static var blurRadius: Int { blurKernel.count / 2 }

    /// sRGB transfer function, tabulated because the input is always 8-bit (shared with the Metal port).
    static let linearTable: [Float] = (0..<256).map { value in
        let normalized = Float(value) / 255
        return normalized <= 0.04045 ? normalized / 12.92 : pow((normalized + 0.055) / 1.055, 2.4)
    }

    // Opsin absorbance matrix and bias, frozen by the JPEG XL specification.
    static let m00: Float = 0.30, m01: Float = 0.622, m02: Float = 0.078
    static let m10: Float = 0.23, m11: Float = 0.692, m12: Float = 0.078
    static let m20: Float = 0.24342268924547819, m21: Float = 0.20476744424496821, m22: Float = 0.5518098702595336
    static let opsinBias: Float = 0.0037930732552754493

    /// Scale pyramid sizes exactly as the scale loop visits them (the previous level is tested before shrinking).
    static func pyramidSizes(width: Int, height: Int) -> [(width: Int, height: Int)] {
        var sizes: [(width: Int, height: Int)] = []
        var w = width, h = height
        for scale in 0..<numScales {
            if w < 8 || h < 8 { break }
            if scale > 0 { w = (w + 1) / 2; h = (h + 1) / 2 }
            sizes.append((w, h))
        }
        return sizes
    }

    /// Scores `distorted` against `reference` on the CPU.
    public static func score(reference: PixelImage, distorted: PixelImage) throws -> Double {
        guard reference.width == distorted.width, reference.height == distorted.height else {
            throw PrimitiveError("SSIMULACRA2: both images must have identical dimensions")
        }
        guard reference.width >= 8, reference.height >= 8 else {
            throw PrimitiveError("SSIMULACRA2: images must be at least 8×8 pixels")
        }
        var linearReference = linearRGB(from: reference)
        var linearDistorted = linearRGB(from: distorted)
        var scales: [ScaleMeasurements] = []

        for scale in 0..<numScales {
            if linearReference.width < 8 || linearReference.height < 8 { break }
            if scale > 0 {
                linearReference = downsampleByTwo(linearReference)
                linearDistorted = downsampleByTwo(linearDistorted)
            }
            let img1 = positiveXYB(from: linearReference)
            let img2 = positiveXYB(from: linearDistorted)
            let width = img1.width, height = img1.height
            var mu1 = PlanarImage(width: width, height: height)
            var mu2 = PlanarImage(width: width, height: height)
            var sigma11 = PlanarImage(width: width, height: height)
            var sigma22 = PlanarImage(width: width, height: height)
            var sigma12 = PlanarImage(width: width, height: height)
            for channel in 0..<3 {
                mu1.planes[channel] = blur(img1.planes[channel], width: width, height: height)
                mu2.planes[channel] = blur(img2.planes[channel], width: width, height: height)
                sigma11.planes[channel] = blur(multiply(img1.planes[channel], img1.planes[channel]), width: width, height: height)
                sigma22.planes[channel] = blur(multiply(img2.planes[channel], img2.planes[channel]), width: width, height: height)
                sigma12.planes[channel] = blur(multiply(img1.planes[channel], img2.planes[channel]), width: width, height: height)
            }
            var measurements = ScaleMeasurements()
            measurements.ssim = ssimMap(mu1: mu1, mu2: mu2, sigma11: sigma11, sigma22: sigma22, sigma12: sigma12)
            measurements.edgeDiff = edgeDiffMap(img1: img1, mu1: mu1, img2: img2, mu2: mu2)
            scales.append(measurements)
        }
        return combine(scales)
    }

    // MARK: - Per-scale measurements

    /// Shared with the Metal port, which feeds its reductions into the same weighting stage.
    struct ScaleMeasurements {
        /// 1-norm and 4-norm of the SSIM error map, per channel.
        var ssim = [Double](repeating: 0, count: 6)
        /// 1-norm and 4-norm of the ringing (artifact) and blurring (detail lost) maps, per channel.
        var edgeDiff = [Double](repeating: 0, count: 12)
    }

    struct PlanarImage {
        let width: Int, height: Int
        var planes: [[Float]]
        init(width: Int, height: Int) {
            self.width = width; self.height = height
            planes = Array(repeating: [Float](repeating: 0, count: width * height), count: 3)
        }
        init(width: Int, height: Int, planes: [[Float]]) { self.width = width; self.height = height; self.planes = planes }
    }

    // MARK: - Colour handling

    static func linearRGB(from image: PixelImage) -> PlanarImage {
        var result = PlanarImage(width: image.width, height: image.height)
        let base = image.bytes
        linearTable.withUnsafeBufferPointer { table in
            for channel in 0..<3 {
                result.planes[channel].withUnsafeMutableBufferPointer { plane in
                    for y in 0..<image.height {
                        let row = base + y * image.bytesPerRow
                        let out = y * image.width
                        for x in 0..<image.width { plane[out + x] = table[Int(row[x * 4 + channel])] }
                    }
                }
            }
        }
        return result
    }

    /// Linear RGB to XYB, then rescaled so all three channels sit in roughly 0…1.
    static func positiveXYB(from linear: PlanarImage) -> PlanarImage {
        let count = linear.width * linear.height
        var mixed0 = [Float](repeating: 0, count: count)
        var mixed1 = [Float](repeating: 0, count: count)
        var mixed2 = [Float](repeating: 0, count: count)
        mix(linear, m00, m01, m02, into: &mixed0)
        mix(linear, m10, m11, m12, into: &mixed1)
        mix(linear, m20, m21, m22, into: &mixed2)
        let biasCubeRoot = cbrtf(opsinBias)
        cubeRootShift(&mixed0, subtracting: biasCubeRoot)
        cubeRootShift(&mixed1, subtracting: biasCubeRoot)
        cubeRootShift(&mixed2, subtracting: biasCubeRoot)
        var planeX = [Float](repeating: 0, count: count)
        var planeY = [Float](repeating: 0, count: count)
        var planeB = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let xValue = 0.5 * (mixed0[index] - mixed1[index])
            let yValue = 0.5 * (mixed0[index] + mixed1[index])
            // B is derived from the pre-offset Y, so it must be computed before Y is shifted.
            planeB[index] = (mixed2[index] - yValue) + 0.55
            planeX[index] = xValue * 14 + 0.42
            planeY[index] = yValue + 0.01
        }
        return PlanarImage(width: linear.width, height: linear.height, planes: [planeX, planeY, planeB])
    }

    /// out = c0·R + c1·G + c2·B + bias, clamped at zero (wide-gamut inputs can push it negative).
    static func mix(_ linear: PlanarImage, _ c0: Float, _ c1: Float, _ c2: Float, into out: inout [Float]) {
        let r = linear.planes[0], g = linear.planes[1], b = linear.planes[2]
        for index in out.indices {
            let value = c0 * r[index] + c1 * g[index] + c2 * b[index] + opsinBias
            out[index] = value < 0 ? 0 : value
        }
    }

    static func cubeRootShift(_ values: inout [Float], subtracting offset: Float) {
        var count = Int32(values.count)
        let source = values
        source.withUnsafeBufferPointer { input in
            values.withUnsafeMutableBufferPointer { output in vvcbrtf(output.baseAddress!, input.baseAddress!, &count) }
        }
        for index in values.indices { values[index] -= offset }
    }

    static func multiply(_ lhs: [Float], _ rhs: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: lhs.count)
        vDSP_vmul(lhs, 1, rhs, 1, &result, 1, vDSP_Length(lhs.count))
        return result
    }

    /// Box-filtered 2:1 downscale in linear light, rounding dimensions up (odd sizes reuse the last row/column).
    static func downsampleByTwo(_ image: PlanarImage) -> PlanarImage {
        let outWidth = (image.width + 1) / 2, outHeight = (image.height + 1) / 2
        var result = PlanarImage(width: outWidth, height: outHeight)
        for channel in 0..<3 {
            let source = image.planes[channel]
            result.planes[channel].withUnsafeMutableBufferPointer { dest in
                for outY in 0..<outHeight {
                    for outX in 0..<outWidth {
                        var sum: Float = 0
                        for dy in 0..<2 {
                            let y = min(outY * 2 + dy, image.height - 1)
                            for dx in 0..<2 {
                                let x = min(outX * 2 + dx, image.width - 1)
                                sum += source[y * image.width + x]
                            }
                        }
                        dest[outY * outWidth + outX] = sum * 0.25
                    }
                }
            }
        }
        return result
    }

    /// Separable FIR Gaussian with edge extension (vImage), horizontal then vertical.
    static func blur(_ plane: [Float], width: Int, height: Int) -> [Float] {
        var source = plane
        var intermediate = [Float](repeating: 0, count: width * height)
        var result = [Float](repeating: 0, count: width * height)
        let rowBytes = width * MemoryLayout<Float>.stride
        let taps = UInt32(blurKernel.count)
        let flags = vImage_Flags(kvImageEdgeExtend)
        source.withUnsafeMutableBufferPointer { sourceBuffer in
            intermediate.withUnsafeMutableBufferPointer { midBuffer in
                result.withUnsafeMutableBufferPointer { resultBuffer in
                    var sourceImage = vImage_Buffer(data: sourceBuffer.baseAddress, height: vImagePixelCount(height),
                                                    width: vImagePixelCount(width), rowBytes: rowBytes)
                    var midImage = vImage_Buffer(data: midBuffer.baseAddress, height: vImagePixelCount(height),
                                                 width: vImagePixelCount(width), rowBytes: rowBytes)
                    var resultImage = vImage_Buffer(data: resultBuffer.baseAddress, height: vImagePixelCount(height),
                                                    width: vImagePixelCount(width), rowBytes: rowBytes)
                    vImageConvolve_PlanarF(&sourceImage, &midImage, nil, 0, 0, blurKernel, 1, taps, 0, flags)
                    vImageConvolve_PlanarF(&midImage, &resultImage, nil, 0, 0, blurKernel, taps, 1, 0, flags)
                }
            }
        }
        return result
    }

    // MARK: - Error maps

    static func quartic(_ value: Double) -> Double { let squared = value * value; return squared * squared }

    /// SSIM without the gamma-correction denominator, expressed as an error (1 − SSIM) so a 4-norm is meaningful.
    static func ssimMap(mu1: PlanarImage, mu2: PlanarImage, sigma11: PlanarImage, sigma22: PlanarImage,
                        sigma12: PlanarImage) -> [Double] {
        let count = mu1.width * mu1.height
        let perPixel = 1.0 / Double(count)
        var averages = [Double](repeating: 0, count: 6)
        for channel in 0..<3 {
            let m1 = mu1.planes[channel], m2 = mu2.planes[channel]
            let s11 = sigma11.planes[channel], s22 = sigma22.planes[channel], s12 = sigma12.planes[channel]
            var sumLinear = 0.0, sumQuartic = 0.0
            for index in 0..<count {
                let mean1 = m1[index], mean2 = m2[index]
                let mean11 = mean1 * mean1, mean22 = mean2 * mean2, mean12 = mean1 * mean2
                let numeratorMean = 1.0 - (mean1 - mean2) * (mean1 - mean2)
                let numeratorSigma = 2 * (s12[index] - mean12) + kC2
                let denominatorSigma = (s11[index] - mean11) + (s22[index] - mean22) + kC2
                var error = 1.0 - Double(numeratorMean * numeratorSigma / denominatorSigma)
                error = max(error, 0)
                sumLinear += error
                sumQuartic += quartic(error)
            }
            averages[channel * 2] = perPixel * sumLinear
            averages[channel * 2 + 1] = (perPixel * sumQuartic).squareRoot().squareRoot()
        }
        return averages
    }

    /// Ringing/blockiness (structure the original lacks) and smoothing (structure lost), per channel.
    static func edgeDiffMap(img1: PlanarImage, mu1: PlanarImage, img2: PlanarImage, mu2: PlanarImage) -> [Double] {
        let count = img1.width * img1.height
        let perPixel = 1.0 / Double(count)
        var averages = [Double](repeating: 0, count: 12)
        for channel in 0..<3 {
            let i1 = img1.planes[channel], i2 = img2.planes[channel], m1 = mu1.planes[channel], m2 = mu2.planes[channel]
            var artifactSum = 0.0, artifactQuartic = 0.0, detailSum = 0.0, detailQuartic = 0.0
            for index in 0..<count {
                let originalEdge = 1.0 + abs(Double(i1[index] - m1[index]))
                let distortedEdge = 1.0 + abs(Double(i2[index] - m2[index]))
                let ratio = distortedEdge / originalEdge - 1.0
                let artifact = max(ratio, 0)
                artifactSum += artifact
                artifactQuartic += quartic(artifact)
                let detailLost = max(-ratio, 0)
                detailSum += detailLost
                detailQuartic += quartic(detailLost)
            }
            averages[channel * 4] = perPixel * artifactSum
            averages[channel * 4 + 1] = (perPixel * artifactQuartic).squareRoot().squareRoot()
            averages[channel * 4 + 2] = perPixel * detailSum
            averages[channel * 4 + 3] = (perPixel * detailQuartic).squareRoot().squareRoot()
        }
        return averages
    }

    // MARK: - Scoring

    /// Weights from the reference authors (Nelder-Mead against CID22, TID2013, Kadid10k and KonFiG-IQA). Order matters.
    static let weights: [Double] = [
        0.0, 0.0007376606707406586, 0.0, 0.0, 0.0007793481682867309, 0.0,
        0.0, 0.0004371155730107379, 0.0, 1.1041726426657346, 0.00066284834129271,
        0.00015231632783718752, 0.0, 0.0016406437456599754, 0.0, 1.8422455520539298,
        11.441172603757666, 0.0, 0.0007989109436015163, 0.000176816438078653, 0.0,
        1.8787594979546387, 10.94906990605142, 0.0, 0.0007289346991508072,
        0.9677937080626833, 0.0, 0.00014003424285435884, 0.9981766977854967,
        0.00031949755934435053, 0.0004550992113792063, 0.0, 0.0, 0.0013648766163243398,
        0.0, 0.0, 0.0, 0.0, 0.0, 7.466890328078848, 0.0, 17.445833984131262,
        0.0006235601634041466, 0.0, 0.0, 6.683678146179332, 0.00037724407979611296,
        1.027889937768264, 225.20515300849274, 0.0, 0.0, 19.213238186143016,
        0.0011401524586618361, 0.001237755635509985, 176.39317598450694, 0.0, 0.0,
        24.43300999870476, 0.28520802612117757, 0.0004485436923833408, 0.0, 0.0, 0.0,
        34.77906344483772, 44.835625328877896, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0008680556573291698, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0005313191874358747, 0.0,
        0.00016533814161379112, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0004179171803251336,
        0.0017290828234722833, 0.0, 0.0020827005846636437, 0.0, 0.0, 8.826982764996862,
        23.19243343998926, 0.0, 95.1080498811086, 0.9863978034400682, 0.9834382792465353,
        0.0012286405048278493, 171.2667255897307, 0.9807858872435379, 0.0, 0.0, 0.0,
        0.0005130064588990679, 0.0, 0.00010854057858411537,
    ]

    static func combine(_ scales: [ScaleMeasurements]) -> Double {
        var accumulated = 0.0
        var weightIndex = 0
        for channel in 0..<3 {
            for scale in scales.indices {
                for norm in 0..<2 {
                    accumulated += weights[weightIndex] * abs(scales[scale].ssim[channel * 2 + norm])
                    weightIndex += 1
                    accumulated += weights[weightIndex] * abs(scales[scale].edgeDiff[channel * 4 + norm])
                    weightIndex += 1
                    accumulated += weights[weightIndex] * abs(scales[scale].edgeDiff[channel * 4 + norm + 2])
                    weightIndex += 1
                }
            }
        }
        // Polynomial fit mapping the raw weighted error onto the published 0…100 scale.
        var score = accumulated * 0.9562382616834844
        score = 2.326765642916932 * score - 0.020884521182843837 * score * score
            + 6.248496625763138e-05 * score * score * score
        guard score > 0 else { return 100 }
        return 100.0 - 10.0 * pow(score, 0.6276336467831387)
    }
}

/// `PerceptualMetric` on the CPU oracle (tests, and the fallback when Metal is unavailable: about 6 s per 45 MP).
public struct CPUSSIMULACRA2: PerceptualMetric {
    public final class Reference: MetricReference, @unchecked Sendable {
        public let image: PixelImage
        public var width: Int { image.width }
        public var height: Int { image.height }
        init(image: PixelImage) { self.image = image }
    }

    public init() {}
    public func prepareReference(_ image: PixelImage) throws -> any MetricReference { Reference(image: image) }
    public func score(_ candidate: PixelImage, against reference: any MetricReference) throws -> Double {
        guard let reference = reference as? Reference else { throw PrimitiveError("SSIMULACRA2: foreign reference") }
        return try SSIMULACRA2.score(reference: reference.image, distorted: candidate)
    }
    public func release(_ reference: any MetricReference) {}
}
