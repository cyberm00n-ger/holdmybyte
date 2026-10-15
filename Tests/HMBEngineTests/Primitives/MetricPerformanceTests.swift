// WP1 acceptance 4: 45 MP candidate score ≤ 0.40 s (median of 10) against a cached reference, reference preparation
// ≤ 0.20 s. Timing needs a quiet machine, so it is opt-in: HMB_METRIC_BENCH=1 plus HMB_TEST_PHOTOS. Results (with
// the load average) are printed as "[metric-bench]" lines and copied into Docs/METRIC.md.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite(.serialized) struct MetricPerformanceTests {
    @Test(.enabled(if: LocalData.benchEnabled && LocalData.hasSamples))
    func fullResolutionScoreBudget() throws {
        let metal = try MetalSSIMULACRA2()
        let decoder = ImageIODecoder()
        let url = LocalData.samplePhotos[0]
        let source = try decoder.decode(try decoder.inspect(url))
        let candidate = try decoder.decode(encoded: try JpegliEncoder().encode(source, distance: 2.0, subsampling: .s420, markers: []))
        print("[metric-bench] \(url.lastPathComponent) \(source.width)×\(source.height) \(LocalData.loadAverage())")

        // Warm-up: shader pipelines, pools, page faults.
        var reference = try metal.prepareReference(source)
        _ = try metal.score(candidate, against: reference)
        metal.release(reference)

        var prepare: [Double] = [], prepareGPU: [Double] = []
        for _ in 0..<5 {
            var made: (any MetricReference)?
            prepare.append(try Measure.seconds { made = try metal.prepareReference(source) })
            prepareGPU.append(metal.lastGPUSeconds)
            metal.release(made!)
        }
        // Cold: no pooled buffers (fresh allocations and page faults), for the pool-retention trade-off.
        var cold: [Double] = [], coldScore: [Double] = []
        for _ in 0..<3 {
            metal.drainPools()
            var made: (any MetricReference)?
            cold.append(try Measure.seconds { made = try metal.prepareReference(source) })
            metal.drainPools()
            coldScore.append(try Measure.seconds { _ = try metal.score(candidate, against: made!) })
            metal.release(made!)
        }
        print(String(format: "[metric-bench] cold (pools drained): prepare median %.3f s, score median %.3f s",
                     Measure.median(cold), Measure.median(coldScore)))
        reference = try metal.prepareReference(source)
        var wall: [Double] = [], gpu: [Double] = [], scores: [Double] = []
        for _ in 0..<10 {
            var value = 0.0
            wall.append(try Measure.seconds { value = try metal.score(candidate, against: reference) })
            gpu.append(metal.lastGPUSeconds)
            scores.append(value)
        }
        metal.release(reference)
        print("[metric-bench] candidate wrapped without copy: \(metal.lastUploadWasWrapped)")
        print(String(format: "[metric-bench] prepare median %.3f s (GPU %.3f s); score median %.3f s (GPU %.3f s), min %.3f, max %.3f; score %.4f; %@",
                     Measure.median(prepare), Measure.median(prepareGPU), Measure.median(wall), Measure.median(gpu),
                     wall.min()!, wall.max()!, scores[0], LocalData.loadAverage()))
        #expect(Set(scores).count == 1, "repeated scores must be identical")
        #expect(Measure.median(wall) <= 0.40)
        #expect(Measure.median(prepare) <= 0.20)
    }

    /// GPU vs CPU oracle on a full 45 MP pair (opt-in: the CPU oracle takes ~6 s in release, minutes in debug).
    @Test(.enabled(if: LocalData.benchEnabled && LocalData.hasSamples))
    func fullResolutionAgreement() throws {
        let metal = try MetalSSIMULACRA2()
        let decoder = ImageIODecoder()
        let url = LocalData.samplePhotos[0]
        let source = try decoder.decode(try decoder.inspect(url))
        let candidate = try decoder.decode(encoded: try JpegliEncoder().encode(source, distance: 2.0, subsampling: .s420, markers: []))
        let session = try metal.prepareReference(source)
        let gpu = try metal.score(candidate, against: session)
        metal.release(session)
        var cpu = 0.0
        let seconds = try Measure.seconds { cpu = try SSIMULACRA2.score(reference: source, distorted: candidate) }
        print(String(format: "[metric-bench] 45 MP agreement %@: GPU %.6f CPU %.6f Δ %.2e (CPU %.1f s, %@)",
                     url.lastPathComponent, gpu, cpu, gpu - cpu, seconds, LocalData.loadAverage()))
        #expect(abs(gpu - cpu) <= 0.02)
    }

    /// Timings of the other primitives on one 45 MP sample (median of 3), for Docs/METRIC.md and WP2's budget.
    @Test(.enabled(if: LocalData.benchEnabled && LocalData.hasSamples))
    func primitiveTimings() throws {
        let decoder = ImageIODecoder(), processing = VImageProcessing()
        let jpeg = JpegliEncoder(), webp = LibWebPEncoder(), jxl = LibJXLTranscoder()
        let url = LocalData.samplePhotos[0]
        func median(_ label: String, runs: Int = 3, _ body: () throws -> Void) rethrows {
            var times: [Double] = []
            for _ in 0..<runs { times.append(try Measure.seconds(body)) }
            print(String(format: "[primitive-bench] %@: %.3f s (%@)", label, Measure.median(times), LocalData.loadAverage()))
        }
        var info: SourceInfo!
        try median("inspect (header only)") { info = try decoder.inspect(url) }
        var source: PixelImage!
        try median("ImageIO decode 45 MP source") { source = try decoder.decode(info) }
        median("features") { _ = processing.features(source) }
        median("resize to 2560") { _ = processing.resized(source, longEdge: 2560) }
        median("resize to 1440") { _ = processing.resized(source, longEdge: 1440) }
        median("mosaic") { _ = processing.mosaic(source) }
        let p3 = PixelImage(width: source.width, height: source.height, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        p3.pixels.copyMemory(from: UnsafeRawBufferPointer(source.pixels))
        median("sRGB conversion (Display P3 → sRGB) 45 MP") { _ = processing.convertedToSRGB(p3) }
        var encoded = Data()
        try median("jpegli encode 45 MP d2.0 4:2:0 p2") { encoded = try jpeg.encode(source, distance: 2, subsampling: .s420, markers: []) }
        try median("jpegli encode 45 MP d2.0 4:4:4 p2") { _ = try jpeg.encode(source, distance: 2, subsampling: .s444, markers: []) }
        try median("ImageIO decode 45 MP candidate") { _ = try decoder.decode(encoded: encoded) }
        let web = processing.resized(source, longEdge: 2560)
        var prepared: WebPPrepared!
        try median("WebP prepare (sharp YUV) 2560") { prepared = try webp.prepare(web) }
        try median("WebP encode 2560 q75 m4") { _ = try webp.encode(prepared, quality: 75, icc: nil, exif: nil, xmp: nil) }
        let original = info.fileBytes
        var archived = Data()
        try median("JXL transcode 45 MP e7", runs: 1) { archived = try jxl.transcodeLossless(jpeg: original, effort: 7) }
        try median("JXL reconstruct 45 MP", runs: 1) { _ = try jxl.reconstructJPEG(jxl: archived) }
        print(String(format: "[primitive-bench] JXL %d → %d bytes (%.1f %%)", original.count, archived.count,
                     (Double(archived.count) / Double(original.count) - 1) * 100))
    }
}
