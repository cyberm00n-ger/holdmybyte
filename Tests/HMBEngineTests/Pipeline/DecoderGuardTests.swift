// Decoder guard (Docs/DECISIONS.md D-ENG-12): the rule itself (fakes) and the guarantee on real photos (live).
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite struct DecoderGuardTests {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Runs the guard with a second reading of `second` and counts the second decodes.
    static func run(_ mode: DecoderGuard, imageIO: Double, second: Double?, chroma: ChromaSubsampling?,
                    target: Double = 85) throws -> (score: Double, decodes: Int) {
        var decodes = 0
        let score = try mode.score(imageIO, target: target, chroma: chroma, data: Data(), width: 8, height: 8, colorSpace: sRGB,
                                   decode: { _ in
                                       decodes += 1
                                       return second == nil ? nil : PixelImage(width: 8, height: 8, colorSpace: sRGB)
                                   },
                                   score: { _ in second! })
        return (score, decodes)
    }

    @Test func lowerReadingCountsOnlyForPassingCandidatesItAppliesTo() throws {
        // 4:4:4 passing under ImageIO, lower under libjpeg-turbo: the lower score, one extra decode.
        #expect(try Self.run(.chroma444, imageIO: 85.02, second: 84.9, chroma: .s444) == (84.9, 1))
        // The second reading is higher: ImageIO's stays.
        #expect(try Self.run(.chroma444, imageIO: 85.02, second: 85.3, chroma: .s444) == (85.02, 1))
        // Failing under ImageIO: no second decode (the minimum cannot pass either).
        #expect(try Self.run(.chroma444, imageIO: 84.99, second: 80, chroma: .s444) == (84.99, 0))
        // 4:2:0 and WebP are not guarded by default; `.all` guards every JPEG, `.off` nothing.
        #expect(try Self.run(.chroma444, imageIO: 85.02, second: 84.9, chroma: .s420) == (85.02, 0))
        #expect(try Self.run(.chroma444, imageIO: 85.02, second: 84.9, chroma: nil) == (85.02, 0))
        #expect(try Self.run(.all, imageIO: 85.02, second: 84.9, chroma: .s420) == (84.9, 1))
        #expect(try Self.run(.all, imageIO: 85.02, second: 84.9, chroma: nil) == (85.02, 0))
        #expect(try Self.run(.off, imageIO: 85.02, second: 84.9, chroma: .s444) == (85.02, 0))
        // A layout the second decoder declines keeps ImageIO's score.
        #expect(try Self.run(.chroma444, imageIO: 85.02, second: nil, chroma: .s444) == (85.02, 1))
        // Exactly at the target counts as passing.
        #expect(try Self.run(.chroma444, imageIO: 85, second: 84.99, chroma: .s444) == (84.99, 1))
    }

    @Test func defaultGuardsEveryJPEG() {
        #expect(SearchConstants().decoderGuard == .all)
    }

    /// The guarantee on real photos: every Social file (4:4:4 since D-ENG-11) reaches 85 under ImageIO *and* under
    /// libjpeg-turbo's pixels, and the journaled score is the lower of the two.
    @Test(.enabled(if: LiveGate.samplesReady)) func socialMeetsTheFloorUnderBothDecoders() async throws {
        let dir = TempDir("live-guard")
        let engine = LiveGate.engine(dir)
        let scan = try await LiveGate.scan(engine, LiveGate.samples!)
        let social = try #require(DeliveryPreset.builtIns.first { $0.id == .social })
        let output = dir.sub("out").appending(path: "S \u{2013} Deliveries")
        let log = await collect(engine.run(makeRequest(name: "S", photos: scan.photos, roots: scan.sourceRoots, output: output,
                                                       deliveries: [social]), resume: false))
        #expect(log.terminal == .finished)
        let p = LiveGate.primitives!
        #expect(log.results.count == scan.photos.count)
        for r in log.results {
            let photo = scan.photos[r.photo.index]
            let reference = p.processing.resized(p.processing.convertedToSRGB(try p.decoder.decode(p.decoder.inspect(photo.url))),
                                                 longEdge: 1440)
            let file = try #require(r.outRelativePath.map { output.appending(path: $0) })
            let data = try Data(contentsOf: file)
            let imageIO = try p.decoder.decode(encoded: data)
            let turbo = try #require(try IslowDecoder.decode(data, width: imageIO.width, height: imageIO.height,
                                                             colorSpace: imageIO.colorSpace))
            let session = try p.metric.prepareReference(reference)
            defer { p.metric.release(session) }
            let s1 = try p.metric.score(imageIO, against: session), s2 = try p.metric.score(turbo, against: session)
            let target = try #require(r.target), score = try #require(r.score)
            #expect(r.chroma == .s444)
            #expect(s1 >= target && s2 >= target, "\(file.lastPathComponent): ImageIO \(s1), libjpeg-turbo \(s2), target \(target)")
            #expect(abs(score - min(s1, s2)) < 1e-6, "\(file.lastPathComponent): journaled \(score) vs min(\(s1), \(s2))")
        }
    }
}
