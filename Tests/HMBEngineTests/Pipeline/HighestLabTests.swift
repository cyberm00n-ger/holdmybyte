// Opt-in measurements for the high-target JPEG mode (Docs/variants/highest.md); not gates.
//
// 1. Frontier survey at a fixed floor: for each holdout photo and each knob setting, the largest distance whose
//    full-resolution output (Highest markers = keepAll, ImageIO decode, Metal SSIMULACRA2) reaches T, the bytes there,
//    the libjpeg-turbo reading of that file (reference and candidate both decoded by `djpeg`), and the mosaic score at
//    the same distance (for the full − mosaic bias).
//
//   HMB_HIGH_KNOBS='444,std,aq0;444,std,aq0,p0;420,c0.65,t1.6,dc0.8' HMB_HIGH_OUT=/path/high.jsonl \
//       [HMB_HIGH_TARGET=90] swift test -c release -Xswiftc -enable-testing --filter HighestLabTests/frontier
//
//    Knob tokens (comma-separated): 420|422|444, std (Annex K tables), aq0 (adaptive quantisation off), p0 (sequential),
//    c<chroma ratio>, t<luma tilt>, dc<dc ratio>.
//
// 2. Decoder check of delivered files: HMB_TURBO_PAIRS is a TSV of "source<TAB>candidate" paths; every pair is scored
//    with ImageIO on both sides and with libjpeg-turbo (`djpeg`, HMB_DJPEG or PATH) on both sides; one JSON line per
//    pair to HMB_TURBO_OUT.
//
//   HMB_TURBO_PAIRS=/path/pairs.tsv HMB_TURBO_OUT=/path/turbo.jsonl swift test -c release -Xswiftc -enable-testing \
//       --filter HighestLabTests/turboPairs
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

/// libjpeg-turbo decode through `djpeg -ppm` (test-only tool), into the engine's RGBX layout.
enum TurboDecode {
    static let djpeg = MetricHoldoutTests.djpeg

    static func decode(file: URL) throws -> PixelImage {
        let process = Process()
        process.executableURL = djpeg
        // HMB_DJPEG_ARGS: extra djpeg options (e.g. "-dct float" for libjpeg-turbo's floating-point IDCT).
        process.arguments = (ProcessInfo.processInfo.environment["HMB_DJPEG_ARGS"]?.split(separator: " ").map(String.init) ?? [])
            + ["-ppm", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PrimitiveError("djpeg failed on \(file.lastPathComponent)") }
        return try ppm(data)
    }

    static func decode(data: Data) throws -> PixelImage {
        let url = FileManager.default.temporaryDirectory.appending(path: "hmb-turbo-\(UUID().uuidString).jpg")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try decode(file: url)
    }

    /// Binary PPM (P6, maxval 255) → PixelImage (sRGB tag; the metric reads the bytes, as for an untagged decode).
    static func ppm(_ data: Data) throws -> PixelImage {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> PixelImage in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            func token() -> Int? {
                while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
                var v = 0, n = 0
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { v = v * 10 + Int(b[i] - 0x30); i += 1; n += 1 }
                return n > 0 ? v : nil
            }
            guard b.count > 2, b[0] == 0x50, b[1] == 0x36 else { throw PrimitiveError("not a P6 PPM") }
            i = 2
            guard let w = token(), let h = token(), let maxval = token(), maxval == 255 else { throw PrimitiveError("bad PPM header") }
            i += 1
            guard b.count - i >= w * h * 3 else { throw PrimitiveError("short PPM") }
            let image = PixelImage(width: w, height: h, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let dst = image.pixels.bindMemory(to: UInt8.self)
            for y in 0..<h {
                var s = i + y * w * 3, d = y * image.bytesPerRow
                for _ in 0..<w {
                    dst[d] = b[s]; dst[d + 1] = b[s + 1]; dst[d + 2] = b[s + 2]; dst[d + 3] = 255
                    s += 3; d += 4
                }
            }
            return image
        }
    }
}

enum HighestLab {
    static let env = ProcessInfo.processInfo.environment

    struct Knob: Sendable {
        var name: String
        var knobs: @Sendable (Double) -> JPEGKnobs
    }

    static func parse(_ text: String) -> [Knob] {
        text.split(separator: ";").map { item in
            var sampling = JPEGKnobs.Sampling.s420
            var std = false, aq = true, seq = false
            var ratio = 1.0, tilt = 0.0, dc = 1.0
            for token in item.split(separator: ",").map(String.init) {
                switch token {
                case "420": sampling = .s420
                case "422": sampling = .s422
                case "444": sampling = .s444
                case "std": std = true
                case "aq0": aq = false
                case "p0": seq = true
                default:
                    if token.hasPrefix("dc") { dc = Double(token.dropFirst(2)) ?? 1 }
                    else if token.hasPrefix("c") { ratio = Double(token.dropFirst()) ?? 1 }
                    else if token.hasPrefix("t") { tilt = Double(token.dropFirst()) ?? 0 }
                }
            }
            let (s, st, a, q, r, t, d0) = (sampling, std, aq, seq, ratio, tilt, dc)
            return Knob(name: String(item)) { d in
                var k = JPEGKnobs(distance: d, chromaDistance: r == 1 ? nil : min(25, d * r), sampling: s, adaptiveQuantization: a)
                k.standardTables = st
                k.sequential = q
                k.lumaTilt = t
                k.dcRatio = d0
                return k
            }
        }
    }

    static func append(_ line: String, to path: String) {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
    }
}

@Suite(.serialized) struct HighestLabTests {
    @Test(.enabled(if: HighestLab.env["HMB_HIGH_KNOBS"] != nil && HighestLab.env["HMB_HIGH_OUT"] != nil && LiveGate.holdoutReady))
    func frontier() throws {
        let env = HighestLab.env
        let knobs = HighestLab.parse(env["HMB_HIGH_KNOBS"]!)
        let out = env["HMB_HIGH_OUT"]!
        let target = Double(env["HMB_HIGH_TARGET"] ?? "") ?? 90
        let width = Double(env["HMB_HIGH_WIDTH"] ?? "") ?? 0.004
        let startD = Double(env["HMB_HIGH_START"] ?? "") ?? Targets.jpegPrior(target)
        let only = env["HMB_HIGH_PHOTOS"].map { Set($0.split(separator: ",").map(String.init)) }
        let p = LiveGate.primitives!
        let jpegli = JpegliEncoder()
        let files = LocalData.jpegs(in: LiveGate.holdout!.path).filter { only == nil || only!.contains(where: $0.lastPathComponent.contains) }
        let preset = DeliveryPreset(id: DeliveryID(rawValue: "highest-full"), name: "Highest", symbol: "star", format: .jpeg,
                                    size: .full, quality: .highest, colour: .keepProfile, metadata: .keepAll, folderName: "Highest")
        let before = LiveGate.uptime()
        let start = monotonicSeconds()
        let gate = DispatchSemaphore(value: Int(env["HMB_HIGH_PAR"] ?? "") ?? 3)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            gate.wait(); defer { gate.signal() }
            do {
                let info = try p.decoder.inspect(files[i])
                let source = try p.decoder.decode(info)
                let markers = MetadataEditor.jpegMarkers(MetadataEditor.output(for: info, policy: preset.metadata, colour: preset.colour))
                let ref = try p.metric.prepareReference(source)
                defer { p.metric.release(ref) }
                let turboRef = try TurboDecode.decode(file: files[i])
                let tref = try p.metric.prepareReference(turboRef)
                defer { p.metric.release(tref) }
                let mosaic = p.processing.mosaic(source)!
                let mref = try p.metric.prepareReference(mosaic)
                defer { p.metric.release(mref) }
                for knob in knobs {
                    var data: [Double: Data] = [:]
                    let t0 = monotonicSeconds()
                    let points = try KnobSurvey.frontier(start: log(startD), goal: target, width: width) { d in
                        let encoded = try jpegli.encode(source, knobs: knob.knobs(d), markers: markers)
                        data[d] = encoded
                        return .init(d: d, bytes: encoded.count, score: try p.metric.score(try p.decoder.decode(encoded: encoded), against: ref))
                    }
                    let seconds = monotonicSeconds() - t0
                    guard let best = points.filter({ $0.score >= target }).min(by: { $0.bytes < $1.bytes }) else {
                        Issue.record("\(files[i].lastPathComponent) \(knob.name): no passing point"); continue
                    }
                    let turbo = try p.metric.score(try TurboDecode.decode(data: data[best.d]!), against: tref)
                    var mk = knob.knobs(best.d)
                    mk.scoringOnly = true
                    let mdata = try jpegli.encode(mosaic, knobs: mk, markers: [])
                    let m = try p.metric.score(try p.decoder.decode(encoded: mdata), against: mref)
                    struct Line: Codable {
                        var photo: String; var knob: String; var target: Double; var d: Double; var bytes: Int
                        var imageio: Double; var turbo: Double; var mosaic: Double; var mosaicBytes: Int; var evals: Int; var seconds: Double
                        var points: [KnobSurvey.Point]
                    }
                    let line = Line(photo: files[i].lastPathComponent, knob: knob.name, target: target, d: best.d, bytes: best.bytes,
                                    imageio: best.score, turbo: turbo, mosaic: m, mosaicBytes: mdata.count, evals: points.count, seconds: seconds, points: points)
                    HighestLab.append(String(decoding: try JSONEncoder().encode(line), as: UTF8.self), to: out)
                }
            } catch {
                Issue.record("\(files[i].lastPathComponent): \(error)")
            }
        }
        print(String(format: "HIGHEST LAB: %.0f s; before %@, after %@", monotonicSeconds() - start, before, LiveGate.uptime()))
    }

    /// HMB_HIGH_ENCODE='<source>|<knob>|<distance>|<out.jpg>[;…]': one encode each (no markers), for inspection.
    @Test(.enabled(if: HighestLab.env["HMB_HIGH_ENCODE"] != nil && LiveGate.primitives != nil))
    func encodeOne() throws {
        let p = LiveGate.primitives!
        for job in HighestLab.env["HMB_HIGH_ENCODE"]!.split(separator: ";") {
            let parts = job.split(separator: "|").map(String.init)
            let source = try p.decoder.decode(try p.decoder.inspect(URL(fileURLWithPath: parts[0])))
            let knob = HighestLab.parse(parts[1])[0]
            try JpegliEncoder().encode(source, knobs: knob.knobs(Double(parts[2])!), markers: []).write(to: URL(fileURLWithPath: parts[3]))
        }
    }

    @Test(.enabled(if: HighestLab.env["HMB_TURBO_PAIRS"] != nil && HighestLab.env["HMB_TURBO_OUT"] != nil && LiveGate.primitives != nil))
    func turboPairs() throws {
        let env = HighestLab.env
        let out = env["HMB_TURBO_OUT"]!
        let pairs = try String(contentsOfFile: env["HMB_TURBO_PAIRS"]!, encoding: .utf8).split(separator: "\n").compactMap { line -> (URL, URL)? in
            let parts = line.split(separator: "\t").map(String.init)
            return parts.count == 2 ? (URL(fileURLWithPath: parts[0]), URL(fileURLWithPath: parts[1])) : nil
        }
        let p = LiveGate.primitives!
        let start = monotonicSeconds()
        let gate = DispatchSemaphore(value: Int(env["HMB_TURBO_PAR"] ?? "") ?? 3)
        DispatchQueue.concurrentPerform(iterations: pairs.count) { i in
            gate.wait(); defer { gate.signal() }
            let (source, candidate) = pairs[i]
            do {
                let imageio: Double = try {
                    let ref = try p.metric.prepareReference(try p.decoder.decode(try p.decoder.inspect(source)))
                    defer { p.metric.release(ref) }
                    return try p.metric.score(try p.decoder.decode(encoded: try Data(contentsOf: candidate)), against: ref)
                }()
                let turbo: Double = try {
                    let ref = try p.metric.prepareReference(try TurboDecode.decode(file: source))
                    defer { p.metric.release(ref) }
                    return try p.metric.score(try TurboDecode.decode(file: candidate), against: ref)
                }()
                struct Line: Codable { var source: String; var candidate: String; var bytes: Int; var imageio: Double; var turbo: Double }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: candidate.path)[.size] as? Int) ?? 0
                let line = Line(source: source.lastPathComponent, candidate: candidate.lastPathComponent, bytes: bytes,
                                imageio: imageio, turbo: turbo)
                HighestLab.append(String(decoding: try JSONEncoder().encode(line), as: UTF8.self), to: out)
            } catch {
                Issue.record("\(candidate.lastPathComponent): \(error)")
            }
        }
        print(String(format: "TURBO PAIRS: %d pairs, %.0f s, %@", pairs.count, monotonicSeconds() - start, LiveGate.uptime()))
    }
}
