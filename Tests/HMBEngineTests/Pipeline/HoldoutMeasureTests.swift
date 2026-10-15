// Opt-in measurement (not a gate): dense live curves for the 19 holdout photos, written as JSON for the search
// A/B replays in Docs/ENGINE.md §3.4 and for the G1 re-baseline (Docs/DECISIONS.md). Numbers only, no pixels.
//
//   HMB_CURVES_OUT=/path/curves.json swift test -c release -Xswiftc -enable-testing --filter HoldoutMeasureTests
//
// Per photo: features and Balanced target; full-resolution jpegli probes (Couple's Package markers, exactly the
// bytes the pipeline would write) on a dense ln d grid at 4:2:0 and a coarser one at 4:4:4; the grid mosaic's
// proxy scores and bytes on a wider grid; the old engine's output (HMB_HOLDOUT/../old-holdout) re-scored with v2's
// decoder and metric.
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

struct MeasuredHoldout: Codable, Sendable {
    struct Point: Codable, Sendable { var d: Double; var bytes: Int; var score: Double }
    struct Photo: Codable, Sendable {
        var name: String
        var width: Int, height: Int
        var sourceBytes: Int
        var textureP50: Double, chromaEnergy: Double
        var target: Double
        var markerBytes: Int
        var mosaicPixels: Int
        var full420: [Point], full444: [Point]
        var mosaic420: [Point], mosaic444: [Point]
        var oldBytes: Int?, oldV2Score: Double?, oldSubsampling: String?
    }
    var machine: String
    var photos: [Photo]
}

enum HoldoutMeasure {
    static var outPath: String? { ProcessInfo.processInfo.environment["HMB_CURVES_OUT"] }
    static var enabled: Bool { outPath != nil && LiveGate.holdoutReady }

    /// "4:2:0" / "4:4:4" / other from the SOF component sampling factors.
    static func subsampling(_ data: Data) -> String? {
        let b = [UInt8](data)
        var i = 2
        while i + 4 < b.count {
            guard b[i] == 0xFF else { return nil }
            let m = b[i + 1]
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(m), m != 0xC4, m != 0xC8, m != 0xCC {
                let n = Int(b[i + 9])
                guard n == 3 else { return "\(n) components" }
                let y = b[i + 11], cb = b[i + 14]
                if y == 0x22, cb == 0x11 { return "4:2:0" }
                if y == 0x11, cb == 0x11 { return "4:4:4" }
                return String(format: "Y %02x Cb %02x", y, cb)
            }
            i += 2 + len
        }
        return nil
    }

    static func grid(_ lo: Double, _ hi: Double, step: Double) -> [Double] {
        var out: [Double] = []
        var x = log(lo)
        while x <= log(hi) + 1e-9 { out.append((exp(x) * 10_000).rounded() / 10_000); x += step }
        return out
    }
}

@Suite(.serialized) struct HoldoutMeasureTests {
    @Test(.enabled(if: HoldoutMeasure.enabled)) func measureDenseCurves() throws {
        let p = LiveGate.primitives!
        let holdout = LiveGate.holdout!
        let oldFolder = holdout.deletingLastPathComponent().appending(path: "old-holdout")
        let files = LocalData.jpegs(in: holdout.path)
        #expect(files.count == 19)
        let couple = DeliveryPreset.builtIns[0]
        let full420 = HoldoutMeasure.grid(1.0, 3.6, step: 0.025)
        let full444 = HoldoutMeasure.grid(1.0, 3.6, step: 0.05)
        let mosaicGrid = HoldoutMeasure.grid(0.5, 6.0, step: 0.025)
        let before = LiveGate.uptime()
        let start = monotonicSeconds()
        let results = Locked([MeasuredHoldout.Photo?](repeating: nil, count: files.count))
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            gate.wait(); defer { gate.signal() }
            do {
                let url = files[i]
                let info = try p.decoder.inspect(url)
                let source = try p.decoder.decode(info)
                let features = p.processing.features(source)
                let target = Targets.balanced(textureP50: features.textureP50)
                let meta = MetadataEditor.output(for: info, policy: couple.metadata, colour: couple.colour)
                let markers = MetadataEditor.jpegMarkers(meta)
                let markerBytes = markers.reduce(0) { $0 + $1.payload.count + 4 }
                let ref = try p.metric.prepareReference(source)
                defer { p.metric.release(ref) }
                func fullCurve(_ ds: [Double], _ chroma: ChromaSubsampling) throws -> [MeasuredHoldout.Point] {
                    try ds.map { d in
                        let data = try p.jpeg.encode(source, distance: d, subsampling: chroma, markers: markers)
                        return .init(d: d, bytes: data.count, score: try p.metric.score(try p.decoder.decode(encoded: data), against: ref))
                    }
                }
                let mosaic = p.processing.mosaic(source)!
                let mref = try p.metric.prepareReference(mosaic)
                defer { p.metric.release(mref) }
                func mosaicCurve(_ chroma: ChromaSubsampling) throws -> [MeasuredHoldout.Point] {
                    try mosaicGrid.map { d in
                        let data = try p.jpeg.encode(mosaic, distance: d, subsampling: chroma, markers: [])
                        return .init(d: d, bytes: data.count, score: try p.metric.score(try p.decoder.decode(encoded: data), against: mref))
                    }
                }
                var oldBytes: Int?, oldScore: Double?, oldSub: String?
                let oldURL = oldFolder.appending(path: url.lastPathComponent)
                if let old = try? Data(contentsOf: oldURL) {
                    oldBytes = old.count
                    oldSub = HoldoutMeasure.subsampling(old)
                    oldScore = try p.metric.score(try p.decoder.decode(encoded: old), against: ref)
                }
                let photo = MeasuredHoldout.Photo(
                    name: url.lastPathComponent, width: source.width, height: source.height, sourceBytes: info.fileBytes.count,
                    textureP50: features.textureP50, chromaEnergy: features.chromaEnergy, target: target,
                    markerBytes: markerBytes, mosaicPixels: mosaic.pixelCount,
                    full420: try fullCurve(full420, .s420), full444: try fullCurve(full444, .s444),
                    mosaic420: try mosaicCurve(.s420), mosaic444: try mosaicCurve(.s444),
                    oldBytes: oldBytes, oldV2Score: oldScore, oldSubsampling: oldSub)
                results.withLock { $0[i] = photo }
                print("measured \(url.lastPathComponent) (\(LiveGate.uptime()))")
            } catch {
                Issue.record("\(files[i].lastPathComponent): \(error)")
            }
        }
        let machine = String(format: "%.0f s wall; before %@, after %@", monotonicSeconds() - start, before, LiveGate.uptime())
        let measured = MeasuredHoldout(machine: machine, photos: results.snapshot.compactMap { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(measured).write(to: URL(fileURLWithPath: HoldoutMeasure.outPath!))
        print("HOLDOUT CURVES: \(machine)")
    }
}

/// Resized deliveries (Website: WebP 2560 ≥ 70; Social: JPEG 1440 ≥ 85), sRGB, with each preset's markers.
struct MeasuredResized: Codable, Sendable {
    struct Point: Codable, Sendable { var p: Double; var bytes: Int; var score: Double }
    struct Photo: Codable, Sendable {
        var name: String
        var webp2560: [Point]       // p = q
        var jpeg1440: [Point]       // p = d, 4:2:0
        var webpPriorBytes: Int     // the estimator's single probe (bytes) at the prior
        var jpegPriorBytes: Int
    }
    var machine: String
    var photos: [Photo]
}

extension HoldoutMeasureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HMB_RESIZED_OUT"] != nil && LiveGate.holdoutReady))
    func measureResizedCurves() throws {
        let p = LiveGate.primitives!
        let files = LocalData.jpegs(in: LiveGate.holdout!.path)
        let website = DeliveryPreset.builtIns[1], social = DeliveryPreset.builtIns[2]
        let qs = stride(from: 40.0, through: 98.0, by: 2.0).map { $0 }
        let ds = HoldoutMeasure.grid(0.4, 2.0, step: 0.04)
        let before = LiveGate.uptime()
        let start = monotonicSeconds()
        let results = Locked([MeasuredResized.Photo?](repeating: nil, count: files.count))
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            gate.wait(); defer { gate.signal() }
            do {
                let info = try p.decoder.inspect(files[i])
                let srgb = p.processing.convertedToSRGB(try p.decoder.decode(info))
                let w = p.processing.resized(srgb, longEdge: 2560), s = p.processing.resized(srgb, longEdge: 1440)
                let wm = MetadataEditor.output(for: info, policy: website.metadata, colour: website.colour)
                let sm = MetadataEditor.jpegMarkers(MetadataEditor.output(for: info, policy: social.metadata, colour: social.colour))
                let wref = try p.metric.prepareReference(w), sref = try p.metric.prepareReference(s)
                defer { p.metric.release(wref); p.metric.release(sref) }
                let prepared = try p.webp.prepare(w)
                let web = try qs.map { q -> MeasuredResized.Point in
                    let data = try p.webp.encode(prepared, quality: Float(q), icc: wm.icc, exif: wm.exif, xmp: wm.xmp)
                    return .init(p: q, bytes: data.count, score: try p.metric.score(try p.decoder.decode(encoded: data), against: wref))
                }
                let jpg = try ds.map { d -> MeasuredResized.Point in
                    let data = try p.jpeg.encode(s, distance: d, subsampling: .s420, markers: sm)
                    return .init(p: d, bytes: data.count, score: try p.metric.score(try p.decoder.decode(encoded: data), against: sref))
                }
                let wp = try p.webp.encode(prepared, quality: Float(Targets.webpPrior(70)), icc: wm.icc, exif: wm.exif, xmp: wm.xmp).count
                let jp = try p.jpeg.encode(s, distance: Targets.jpegPrior(85), subsampling: .s420, markers: sm).count
                results.withLock { $0[i] = .init(name: files[i].lastPathComponent, webp2560: web, jpeg1440: jpg,
                                                 webpPriorBytes: wp, jpegPriorBytes: jp) }
            } catch {
                Issue.record("\(files[i].lastPathComponent): \(error)")
            }
        }
        let machine = String(format: "%.0f s wall; before %@, after %@", monotonicSeconds() - start, before, LiveGate.uptime())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(MeasuredResized(machine: machine, photos: results.snapshot.compactMap { $0 }))
            .write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["HMB_RESIZED_OUT"]!))
        print("RESIZED CURVES: \(machine)")
    }
}
