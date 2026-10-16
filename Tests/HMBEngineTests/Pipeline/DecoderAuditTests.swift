// Decoder robustness audit (opt-in, Docs/variants/safety.md): re-scores delivered files with the decoders viewers use
// instead of ImageIO (the engine's scoring decoder, SPEC E6). Test-only tools, nothing vendored: libjpeg-turbo's
// `djpeg` (Chrome, Firefox, Edge, most libjpeg-based software), libwebp's `dwebp` (Chrome, Firefox) and ffmpeg's own
// decoders, all from PATH (or HMB_DJPEG / HMB_DWEBP / HMB_FFMPEG).
//
//   HMB_DECODER_AUDIT=<hmb compress output folder with Couple/Website/Social/High/Highest>  HMB_DECODER_AUDIT_REPORT=<report.json>
//   [HMB_DECODER_AUDIT_SOURCES=<the compressed set, default HMB_HOLDOUT>] [HMB_DECODER_AUDIT_JSON=<out.json>]
//   [HMB_DECODER_AUDIT_FAST=1: libjpeg-turbo only, in process]
//   swift test -c release -Xswiftc -enable-testing --filter DecoderAuditTests
//
// Pairings per delivered file (reference = the engine's reference pipeline: decode → sRGB if converted → resize):
//   engine  ImageIO source / ImageIO candidate (must reproduce the reported score)
//   mixed   ImageIO source / X candidate        (what viewer X shows against the engine's reference)
//   same    X source       / X candidate        (the original and the delivery both opened in viewer X)
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

enum ExternalDecode {
    static func tool(_ name: String, env variable: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let path = env[variable] { return URL(fileURLWithPath: path) }
        for directory in (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
    static let djpeg = tool("djpeg", env: "HMB_DJPEG")
    static let dwebp = tool("dwebp", env: "HMB_DWEBP")
    static let ffmpeg = tool("ffmpeg", env: "HMB_FFMPEG")

    static func run(_ tool: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PrimitiveError("\(tool.lastPathComponent) exited \(process.terminationStatus)") }
        return data
    }

    /// RGB → RGBX PixelImage in `space` (the colour space ImageIO reports for the same file).
    static func image(rgb data: Data, offset: Int, width: Int, height: Int, space: CGColorSpace) throws -> PixelImage {
        guard data.count - offset >= width * height * 3 else { throw PrimitiveError("short decoder output") }
        let image = PixelImage(width: width, height: height, colorSpace: space)
        let base = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        data.withUnsafeBytes { raw in
            let rgb = raw.bindMemory(to: UInt8.self).baseAddress! + offset
            for y in 0..<height {
                let row = base + y * image.bytesPerRow, src = rgb + y * width * 3
                for x in 0..<width {
                    row[x * 4] = src[x * 3]; row[x * 4 + 1] = src[x * 3 + 1]; row[x * 4 + 2] = src[x * 3 + 2]; row[x * 4 + 3] = 255
                }
            }
        }
        return image
    }

    /// Binary PPM (P6, maxval 255).
    static func ppm(_ data: Data, space: CGColorSpace) throws -> PixelImage {
        var fields: [Int] = [], index = 2, current = ""
        guard data.count > 8, data[0] == 0x50, data[1] == 0x36 else { throw PrimitiveError("not a P6 PPM") }
        while fields.count < 3 {
            let byte = data[index]; index += 1
            if byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D {
                if !current.isEmpty { fields.append(Int(current)!); current = "" }
            } else { current.append(Character(UnicodeScalar(byte))) }
        }
        guard fields[2] == 255 else { throw PrimitiveError("PPM maxval \(fields[2])") }
        return try image(rgb: data, offset: index, width: fields[0], height: fields[1], space: space)
    }

    /// A named way to decode a file into stored-orientation RGB.
    struct Decoder: Sendable {
        var name: String
        var decode: @Sendable (URL, _ width: Int, _ height: Int, CGColorSpace) throws -> PixelImage
    }

    static func djpegDecoder(_ name: String, _ options: [String]) -> Decoder? {
        guard let djpeg else { return nil }
        return Decoder(name: name) { url, _, _, space in try ppm(run(djpeg, options + ["-ppm", url.path]), space: space) }
    }
    static func dwebpDecoder(_ name: String, _ options: [String]) -> Decoder? {
        guard let dwebp else { return nil }
        return Decoder(name: name) { url, _, _, space in try ppm(run(dwebp, options + ["-ppm", url.path, "-o", "-"]), space: space) }
    }
    /// ffmpeg's own decoders (mjpeg / webp) and swscale's default conversion to RGB, no autorotation.
    static func ffmpegDecoder(_ name: String) -> Decoder? {
        guard let ffmpeg else { return nil }
        return Decoder(name: name) { url, width, height, space in
            let data = try run(ffmpeg, ["-v", "error", "-noautorotate", "-i", url.path, "-frames:v", "1", "-f", "rawvideo",
                                        "-pix_fmt", "rgb24", "-"])
            return try image(rgb: data, offset: 0, width: width, height: height, space: space)
        }
    }

    /// libjpeg-turbo's pixels in process (`IslowDecoder`, = djpeg; `IslowDecodeTests`), for large sets.
    static let islow = Decoder(name: "turbo") { url, width, height, space in
        guard let image = try IslowDecoder.decode(Data(contentsOf: url), width: width, height: height, colorSpace: space) else {
            throw PrimitiveError("islow: unsupported layout")
        }
        return image
    }
    /// HMB_DECODER_AUDIT_FAST=1: only libjpeg-turbo (in process) for JPEG, nothing for WebP (ImageIO's WebP pixels are
    /// libwebp's, identical on the holdout).
    static var fast: Bool { ProcessInfo.processInfo.environment["HMB_DECODER_AUDIT_FAST"] == "1" }

    /// Viewer decoders for JPEG (the source and JPEG deliveries) and WebP deliveries.
    static var jpegDecoders: [Decoder] {
        if fast { return [islow] }
        return [djpegDecoder("turbo", []),                         // ISLOW IDCT + fancy upsampling (browsers)
         djpegDecoder("turbo-nofancy", ["-nosmooth"]),      // box chroma upsampling
         djpegDecoder("turbo-fast", ["-dct", "fast"]),      // IFAST IDCT
         djpegDecoder("turbo-float", ["-dct", "float"]),
         ffmpegDecoder("ffmpeg")].compactMap { $0 }
    }
    static var webpDecoders: [Decoder] {
        if fast { return [] }
        return [dwebpDecoder("libwebp", []),                       // fancy upsampling (browsers)
         dwebpDecoder("libwebp-nofancy", ["-nofancy"]),
         ffmpegDecoder("ffmpeg")].compactMap { $0 }
    }
}

@Suite(.serialized) struct DecoderAuditTests {
    struct Row: Decodable { var name: String; var delivery: String; var score: Double?; var target: Double?; var status: String }
    struct Report: Decodable { var rows: [Row] }

    struct Line: Encodable {
        var delivery: String, file: String, source: String, target: Double, reported: Double, engine: Double
        var mixed: [String: Double], same: [String: Double]
        /// PSNR of decoder X's candidate pixels against ImageIO's (inf = identical).
        var candidatePSNR: [String: Double]
        /// The source decoded by X (through the same reference pipeline) scored against the engine's reference.
        var sourceFloor: [String: Double]
    }

    static var auditFolder: URL? { LiveGate.folder("HMB_DECODER_AUDIT") }
    /// The compressed set's sources: HMB_DECODER_AUDIT_SOURCES (read only), else the holdout.
    static var sourceFolder: URL? { LiveGate.folder("HMB_DECODER_AUDIT_SOURCES") ?? LiveGate.holdout }
    static var ready: Bool {
        LiveGate.primitives != nil && sourceFolder != nil && auditFolder != nil && (ExternalDecode.fast || ExternalDecode.djpeg != nil)
    }

    @Test(.enabled(if: ready)) func deliveredFilesUnderViewerDecoders() async throws {
        let env = ProcessInfo.processInfo.environment
        let p = LiveGate.primitives!
        let folder = Self.auditFolder!
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(env["HMB_DECODER_AUDIT_REPORT"]))))
        let scan = Scanner().scan([Self.sourceFolder!]) { _ in }
        let fm = FileManager.default
        print("[audit] \(LiveGate.uptime()); jpeg decoders \(ExternalDecode.jpegDecoders.map(\.name)), webp \(ExternalDecode.webpDecoders.map(\.name))")
        let deliveries: [(folder: String, id: String, edge: Int?, srgb: Bool)] = [
            ("Couple", "couple", nil, false), ("Website", "website", 2560, true), ("Social", "social", 1440, true),
            ("High", "high-full", nil, false), ("Highest", "highest-full", nil, false)]
        var lines: [Line] = []
        // The file stems `hmb compress` gave each photo (capture order, the scan's suggested name).
        let stems = JobRunner.stems(request: makeRequest(name: scan.suggestedName, photos: scan.photos, roots: scan.sourceRoots,
                                                         output: folder))
        for photo in scan.photos {
            guard let stem = stems[photo.id.index] else { continue }
            // Nothing delivered for this photo (another set, or a partial run): skip its decodes.
            guard deliveries.contains(where: { d in
                ["jpg", "webp"].contains { fm.fileExists(atPath: folder.appending(path: "\(d.folder)/\(stem).\($0)").path) }
            }) else { continue }
            let sourceImageIO = try p.decoder.decode(p.decoder.inspect(photo.url))
            let space = sourceImageIO.colorSpace
            // Source decodes: ImageIO plus every JPEG viewer decoder (all in the source's own colour space).
            var sources: [String: PixelImage] = ["imageio": sourceImageIO]
            for d in ExternalDecode.jpegDecoders {
                sources[d.name] = try d.decode(photo.url, sourceImageIO.width, sourceImageIO.height, space)
            }
            for delivery in deliveries {
                let dir = folder.appending(path: delivery.folder, directoryHint: .isDirectory)
                guard let file = ["jpg", "webp"].map({ dir.appending(path: "\(stem).\($0)") }).first(where: { fm.fileExists(atPath: $0.path) }),
                      let row = report.rows.first(where: { $0.name == photo.url.lastPathComponent && $0.delivery == delivery.id }),
                      row.status == "done", let reported = row.score, let target = row.target else { continue }
                func reference(_ s: PixelImage) -> PixelImage {
                    var base = s
                    if delivery.srgb { base = p.processing.convertedToSRGB(s) }
                    if let edge = delivery.edge, edge < max(base.width, base.height) { base = p.processing.resized(base, longEdge: edge) }
                    return base
                }
                func score(_ candidate: PixelImage, _ ref: PixelImage) throws -> Double {
                    let session = try p.metric.prepareReference(ref)
                    defer { p.metric.release(session) }
                    return try p.metric.score(candidate, against: session)
                }
                let engineRef = reference(sourceImageIO)
                let candImageIO = try p.decoder.decode(encoded: Data(contentsOf: file))
                let engine = try score(candImageIO, engineRef)
                let candSpace = candImageIO.colorSpace
                let isWebP = file.pathExtension == "webp"
                var mixed: [String: Double] = [:], same: [String: Double] = [:], psnr: [String: Double] = [:], floor: [String: Double] = [:]
                for d in ExternalDecode.jpegDecoders {
                    if let s = sources[d.name] { floor[d.name] = try score(reference(s), engineRef) }
                }
                for d in isWebP ? ExternalDecode.webpDecoders : ExternalDecode.jpegDecoders {
                    let cand = try d.decode(file, candImageIO.width, candImageIO.height, candSpace)
                    psnr[d.name] = min(99, Measure.psnr(cand, candImageIO))   // 99 = identical (JSON has no inf)
                    mixed[d.name] = try score(cand, engineRef)
                    // Same viewer for the source: the JPEG decoder of that name, for WebP libjpeg-turbo (browsers) or ffmpeg.
                    let sourceName = isWebP ? (d.name == "ffmpeg" ? "ffmpeg" : "turbo") : d.name
                    if let s = sources[sourceName] { same[d.name] = try score(cand, reference(s)) }
                }
                let line = Line(delivery: delivery.id, file: file.lastPathComponent, source: photo.url.lastPathComponent, target: target,
                                reported: reported, engine: engine, mixed: mixed, same: same,
                                candidatePSNR: psnr, sourceFloor: floor)
                lines.append(line)
                // The reported score is ImageIO's, or under the decoder guard (D-ENG-12) the lower libjpeg-turbo reading.
                let guarded = min(engine, mixed["turbo"] ?? engine)
                #expect(abs(engine - reported) < 1e-4 || abs(guarded - reported) < 1e-4,
                        "\(file.lastPathComponent): audit engine score \(engine) (guarded \(guarded)) vs reported \(reported)")
                let fmt = { (d: [String: Double]) in d.keys.sorted().map { String(format: "%@ %+.3f", $0, d[$0]! - target) }.joined(separator: " ") }
                let raw = { (d: [String: Double]) in d.keys.sorted().map { String(format: "%@ %.2f", $0, d[$0]!) }.joined(separator: " ") }
                print(String(format: "[audit] %@ %@ T %.2f engine %+.4f | mixed %@ | same %@ | psnr %@ | floor %@", delivery.id,
                             file.lastPathComponent, target, engine - target, fmt(mixed), fmt(same), raw(psnr), raw(floor)))
            }
        }
        #expect(!lines.isEmpty, "no delivered file matched a source (wrong HMB_DECODER_AUDIT_SOURCES?)")
        if let out = env["HMB_DECODER_AUDIT_JSON"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(lines).write(to: URL(fileURLWithPath: out))
        }
        // Summary: minimum margin per delivery and pairing.
        for id in ["couple", "website", "social", "high-full", "highest-full"] {
            let rows = lines.filter { $0.delivery == id }
            guard !rows.isEmpty else { continue }
            var summary = String(format: "[audit] %@ n %d engine min %+.4f", id, rows.count, rows.map { $0.engine - $0.target }.min()!)
            for key in Set(rows.flatMap { $0.mixed.keys }).sorted() {
                let m = rows.compactMap { r in r.mixed[key].map { $0 - r.target } }
                let s = rows.compactMap { r in r.same[key].map { $0 - r.target } }
                let gap = rows.compactMap { r in r.mixed[key].map { $0 - r.engine } }
                summary += String(format: " | %@ mixed min %+.3f med %+.3f below %d, gap to ImageIO min %+.3f, same min %+.3f med %+.3f below %d",
                                  key, m.min() ?? .nan, m.sorted()[m.count / 2], m.filter { $0 < 0 }.count, gap.min() ?? .nan,
                                  s.min() ?? .nan, s.isEmpty ? .nan : s.sorted()[s.count / 2], s.filter { $0 < 0 }.count)
            }
            print(summary)
        }
    }
}
