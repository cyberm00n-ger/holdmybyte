// WP1 acceptance 3: the Metal port agrees with the CPU oracle, is monotone, and matches the old engine's scale.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite(.serialized) struct MetricAgreementTests {
    let metal: MetalSSIMULACRA2
    init() throws { metal = try MetalSSIMULACRA2() }
    let jpeg = JpegliEncoder()
    let decoder = ImageIODecoder()

    /// 10 pairs: 4 synthetic kinds × encodes at several distances and both subsamplings, plus odd sizes.
    @Test func gpuMatchesCPUOnTenPairs() throws {
        var pairs: [(PixelImage, PixelImage, String)] = []
        let cases: [(Synthetic.Kind, Int, Int, Double, ChromaSubsampling)] = [
            (.gradient, 320, 240, 1.0, .s420), (.noise, 320, 240, 2.0, .s420), (.blocks, 333, 201, 1.5, .s444),
            (.waves, 512, 384, 3.0, .s420), (.gradient, 97, 61, 4.0, .s444), (.noise, 640, 480, 0.6, .s420),
            (.blocks, 512, 512, 6.0, .s420), (.waves, 257, 129, 1.0, .s444), (.waves, 1031, 517, 2.2, .s420),
        ]
        for (kind, w, h, d, s) in cases {
            let reference = Synthetic.image(kind, width: w, height: h)
            let candidate = try decoder.decode(encoded: try jpeg.encode(reference, distance: d, subsampling: s, markers: []))
            pairs.append((reference, candidate, "\(kind) \(w)×\(h) d\(d) \(s.rawValue)"))
        }
        let identical = Synthetic.image(.waves, width: 300, height: 200)
        pairs.append((identical, identical, "identical"))
        #expect(pairs.count == 10)
        for (reference, candidate, label) in pairs {
            let cpu = try SSIMULACRA2.score(reference: reference, distorted: candidate)
            let session = try metal.prepareReference(reference)
            let gpu = try metal.score(candidate, against: session)
            metal.release(session)
            print(String(format: "[metric] %@: GPU %.6f CPU %.6f Δ %.2e", label, gpu, cpu, gpu - cpu))
            #expect(abs(gpu - cpu) <= 0.02, "\(label): GPU \(gpu) vs CPU \(cpu)")
        }
    }

    /// Real photo content (HMB_TEST_PHOTOS): two samples at 1280 px, GPU vs CPU.
    @Test(.enabled(if: LocalData.hasSamples)) func gpuMatchesCPUOnSamplePhotos() throws {
        let processing = VImageProcessing()
        for url in LocalData.samplePhotos.prefix(2) {
            let reference = processing.resized(try decoder.decode(try decoder.inspect(url)), longEdge: 1280)
            for distance in [1.0, 2.5] {
                let candidate = try decoder.decode(encoded: try jpeg.encode(reference, distance: distance, subsampling: .s420, markers: []))
                let cpu = try SSIMULACRA2.score(reference: reference, distorted: candidate)
                let session = try metal.prepareReference(reference)
                let gpu = try metal.score(candidate, against: session)
                metal.release(session)
                print(String(format: "[metric] %@ 1280 d%.1f: GPU %.6f CPU %.6f Δ %.2e", url.lastPathComponent, distance, gpu, cpu, gpu - cpu))
                #expect(abs(gpu - cpu) <= 0.02)
            }
        }
    }

    @Test func monotoneOnAJPEGQualityLadder() throws {
        for kind in [Synthetic.Kind.waves, .gradient] {
            let reference = Synthetic.image(kind, width: 640, height: 480)
            let session = try metal.prepareReference(reference)
            defer { metal.release(session) }
            var last = 101.0
            for distance in [0.3, 0.5, 0.8, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 9.0, 13.0] {
                let candidate = try decoder.decode(encoded: try jpeg.encode(reference, distance: distance, subsampling: .s420, markers: []))
                let score = try metal.score(candidate, against: session)
                #expect(score < last, "\(kind) d\(distance): \(score) after \(last)")
                last = score
            }
        }
    }

    @Test func scoresAreDeterministicAndThreadSafe() throws {
        let reference = Synthetic.image(.waves, width: 700, height: 500)
        let candidate = try decoder.decode(encoded: try jpeg.encode(reference, distance: 2, subsampling: .s420, markers: []))
        let session = try metal.prepareReference(reference)
        defer { metal.release(session) }
        let expected = try metal.score(candidate, against: session)
        let results = ScoreBox()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.append((try? metal.score(candidate, against: session)) ?? -1)
        }
        #expect(results.values.count == 8 && results.values.allSatisfy { $0 == expected })
        // A second reference of the same geometry gives the same score (pooled buffers are fully overwritten).
        let again = try metal.prepareReference(reference)
        #expect(try metal.score(candidate, against: again) == expected)
        metal.release(again)
    }

    @Test func misuseThrows() throws {
        let reference = Synthetic.image(.waves, width: 64, height: 48)
        let session = try metal.prepareReference(reference)
        #expect(throws: PrimitiveError.self) { try metal.score(Synthetic.image(.waves, width: 48, height: 64), against: session) }
        #expect(throws: PrimitiveError.self) { try metal.score(reference, against: CPUSSIMULACRA2.Reference(image: reference)) }
        metal.release(session)
        metal.release(session)                                   // idempotent
        #expect(throws: PrimitiveError.self) { try metal.score(reference, against: session) }
        #expect(throws: PrimitiveError.self) { try metal.prepareReference(Synthetic.image(.waves, width: 7, height: 100)) }
        // 8×8 is the smallest legal input; identical images score 100.
        let tiny = Synthetic.image(.noise, width: 8, height: 8)
        let tinySession = try metal.prepareReference(tiny)
        #expect(try metal.score(tiny, against: tinySession) == 100)
        #expect(try SSIMULACRA2.score(reference: tiny, distorted: tiny) == 100)
        metal.release(tinySession)
    }
}

final class ScoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}
