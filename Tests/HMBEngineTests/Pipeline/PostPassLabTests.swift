// Opt-in measurements for the "postpass" variant (Docs/variants/postpass.md). Release build:
//
//   HMB_POSTPASS_DIR=<hmb compress output>  swift test -c release --filter PostPassLabTests/scans
//   HMB_POSTPASS_THRESH=1                   swift test -c release --filter PostPassLabTests/threshold
//   HMB_POSTPASS_WEBP='base:m=4;m6:m=6;…'   swift test -c release --filter PostPassLabTests/webp
//
// Quality is always the engine's: ImageIO decode + Metal SSIMULACRA2 against the variant the pipeline scores against.
import CHMBCodecs
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite(.serialized) struct PostPassLabTests {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func ms(_ body: () throws -> Void) rethrows -> Double { try Measure.seconds(body) * 1000 }

    // MARK: Lossless scan post-pass on delivered JPEGs

    /// Every JPEG of `<dir>/Couple` and `<dir>/Social`: the post-pass result must decode (ImageIO) to identical
    /// pixels; reports bytes and milliseconds. The lab rewrite without changes must reproduce the input byte for byte
    /// (proves the coefficient read/write and the marker copy are exact).
    @Test(.enabled(if: env["HMB_POSTPASS_DIR"] != nil && LiveGate.primitives != nil)) func scans() throws {
        let p = LiveGate.primitives!
        let root = URL(fileURLWithPath: Self.env["HMB_POSTPASS_DIR"]!, isDirectory: true)
        print("SCANS before \(LiveGate.uptime())")
        for folder in ["Couple", "Social"] {
            let files = LocalData.jpegs(in: root.appending(path: folder).path)
            guard !files.isEmpty else { continue }
            var before = 0, after = 0, times: [Double] = []
            for file in files {
                let data = try Data(contentsOf: file)
                let same = try JPEGPostPass.rewrite(data, minK: 0, minRun: 0, componentMask: 0, optimizeScans: false)
                #expect(same == data, "\(file.lastPathComponent): level-2 rewrite is not byte-identical")
                var out: Data?
                times.append(try Self.ms { out = try JPEGPostPass.optimizeScans(data) })
                let result = out ?? data
                if out != nil {
                    let a = try p.decoder.decode(encoded: data), b = try p.decoder.decode(encoded: result)
                    #expect(Measure.identical(a, b), "\(file.lastPathComponent): decoded pixels differ")
                }
                before += data.count; after += result.count
                print(String(format: "SCAN %@/%@ %d → %d (%+.3f%%) %.0f ms", folder, file.lastPathComponent, data.count,
                             result.count, Double(result.count - data.count) / Double(data.count) * 100, times.last!))
            }
            print(String(format: "SCANS %@: %d → %d bytes (%+.3f%%), post-pass %.0f ms mean, %.0f ms max, n %d", folder,
                         before, after, Double(after - before) / Double(before) * 100,
                         times.reduce(0, +) / Double(times.count), times.max()!, files.count))
        }
        print("SCANS after \(LiveGate.uptime())")
    }

    // MARK: Scan choice predicted from the mosaic (full size, no extra full-resolution work)

    /// Couple (full size, Balanced) on the holdout: the script chosen from one mosaic encode at the prior distance,
    /// applied to full-size encodes at d ∈ {0.85, 1, 1.15} × prior, against level 2 and against the script estimated
    /// from the full-size coefficients. Pixels of every scripted encode must equal the level-2 encode's.
    @Test(.enabled(if: env["HMB_POSTPASS_MOSAIC"] != nil && LiveGate.holdoutReady)) func mosaicChoice() throws {
        let p = LiveGate.primitives!
        let files = LocalData.jpegs(in: LiveGate.holdout!.path)
        let preset = DeliveryPreset.builtIns.first { $0.id == .couple }!
        struct Row { var base = 0, mosaic = 0, full = 0, chooseMs = 0.0, encBase = 0.0, encScripted = 0.0, same = true }
        let rows = Locked([String: Row]())
        let gate = DispatchSemaphore(value: 2)
        print("MOSAIC before \(LiveGate.uptime())")
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            gate.wait(); defer { gate.signal() }
            do {
                let info = try p.decoder.inspect(files[i])
                let v = try p.decoder.decode(info)
                let target = try #require(Targets.target(preset.quality, features: p.processing.features(v)))
                let markers = MetadataEditor.jpegMarkers(MetadataEditor.output(for: info, policy: preset.metadata, colour: preset.colour))
                let mosaic = try #require(p.processing.mosaic(v))
                let prior = Targets.jpegPrior(target)
                var choice: JPEGScanChoice?
                let chooseMs = try Self.ms {
                    choice = try p.jpeg.chooseScans(try p.jpeg.encode(mosaic, distance: prior, subsampling: .s420, markers: []))
                }
                for (k, factor) in [0.85, 1.0, 1.15].enumerated() {
                    let d = prior * factor
                    var base = Data(), scripted = Data()
                    let encBase = try Self.ms { base = try p.jpeg.encode(v, distance: d, subsampling: .s420, markers: markers) }
                    let encScripted = try Self.ms { scripted = try p.jpeg.encode(v, distance: d, subsampling: .s420, markers: markers, scans: choice) }
                    let fullChoice = try #require(try p.jpeg.chooseScans(base))
                    let full = try JPEGPostPass.rewrite(base, minK: 0, minRun: 0, componentMask: 0, optimizeScans: false, force: fullChoice)!
                    let same = try k != 1 || Measure.identical(p.decoder.decode(encoded: base), p.decoder.decode(encoded: scripted))
                    rows.withLock {
                        var r = $0["\(factor)", default: Row()]
                        r.base += base.count; r.mosaic += scripted.count; r.full += min(full.count, base.count)
                        r.chooseMs += chooseMs; r.encBase += encBase; r.encScripted += encScripted; r.same = r.same && same
                        $0["\(factor)"] = r
                    }
                    if k == 1 { print("MOSAIC \(files[i].lastPathComponent) T \(target) mosaic \(choice.map { "\($0)" } ?? "nil") full \(fullChoice)") }
                }
            } catch {
                Issue.record("\(files[i].lastPathComponent): \(error)")
            }
        }
        print("MOSAIC after \(LiveGate.uptime())")
        for (key, r) in rows.snapshot.sorted(by: { $0.key < $1.key }) {
            let n = Double(files.count)
            print(String(format: "MOSAIC d×%@: level2 %d, mosaic script %d (%+.3f%%), full-estimate script %d (%+.3f%%), pixels identical %@, choose %.0f ms, encode %.0f → %.0f ms",
                         key, r.base, r.mosaic, Double(r.mosaic - r.base) / Double(r.base) * 100, r.full,
                         Double(r.full - r.base) / Double(r.base) * 100, r.same ? "yes" : "NO", r.chooseMs / n, r.encBase / n, r.encScripted / n))
        }
    }

    // MARK: Near-lossless coefficient zeroing vs. the distance curve

    struct Point { var bytes: Int; var score: Double }

    /// Couple (full size, 74) on 6 holdout photos and Social (1440 px sRGB, 85) on all 19: from a common start
    /// encode at d0, compare "zero isolated ±1 coefficients" against "raise d" in bytes saved per score point lost.
    @Test(.enabled(if: env["HMB_POSTPASS_THRESH"] != nil && LiveGate.holdoutReady)) func threshold() throws {
        let p = LiveGate.primitives!
        let files = LocalData.jpegs(in: LiveGate.holdout!.path)
        let presets = DeliveryPreset.builtIns.filter { $0.id == .couple || $0.id == .social }
        let variants: [(String, Int, Int, Int)] = [("k6r3Y", 6, 3, 1), ("k10r2Y", 10, 2, 1), ("k10r4Y", 10, 4, 1),
                                                   ("k20r2Y", 20, 2, 1), ("k6r3all", 6, 3, 7), ("k3r1all", 3, 1, 7)]
        let steps = [0.02, 0.04, 0.08]
        let lines = Locked([String]())
        print("THRESH before \(LiveGate.uptime())")
        for preset in presets {
            let set = preset.id == .couple ? Array(files.prefix(6)) : files
            let d0 = preset.id == .couple ? 2.0 : 0.65
            let gate = DispatchSemaphore(value: preset.id == .couple ? 2 : 4)
            DispatchQueue.concurrentPerform(iterations: set.count) { i in
                gate.wait(); defer { gate.signal() }
                do {
                    let info = try p.decoder.inspect(set[i])
                    var v = try p.decoder.decode(info)
                    if preset.colour == .convertToSRGB { v = p.processing.convertedToSRGB(v) }
                    if let edge = preset.size.longEdge { v = p.processing.resized(v, longEdge: edge) }
                    let markers = MetadataEditor.jpegMarkers(MetadataEditor.output(for: info, policy: preset.metadata, colour: preset.colour))
                    let ref = try p.metric.prepareReference(v)
                    defer { p.metric.release(ref) }
                    func point(_ data: Data) throws -> Point { Point(bytes: data.count, score: try p.metric.score(try p.decoder.decode(encoded: data), against: ref)) }
                    let start = try p.jpeg.encode(v, distance: d0, subsampling: .s420, markers: markers)
                    let s0 = try point(start)
                    var text = String(format: "%@ %@ d0 %.2f: %d @ %.3f", preset.id.rawValue, set[i].lastPathComponent, d0, s0.bytes, s0.score)
                    for step in steps {
                        let q = try point(try p.jpeg.encode(v, distance: d0 * exp(step), subsampling: .s420, markers: markers))
                        text += String(format: " | d+%.2f %+.3f%% %+.3f", step, Double(q.bytes - s0.bytes) / Double(s0.bytes) * 100, q.score - s0.score)
                    }
                    for (name, k, r, mask) in variants {
                        let q = try point(try JPEGPostPass.rewrite(start, minK: k, minRun: r, componentMask: mask, optimizeScans: false)!)
                        text += String(format: " | %@ %+.3f%% %+.3f", name, Double(q.bytes - s0.bytes) / Double(s0.bytes) * 100, q.score - s0.score)
                    }
                    lines.withLock { $0.append(text) }
                } catch {
                    Issue.record("\(set[i].lastPathComponent): \(error)")
                }
            }
        }
        for line in lines.snapshot.sorted() { print("THRESH " + line) }
        print("THRESH after \(LiveGate.uptime())")
    }

    // MARK: Lossy post-pass: zeroing isolated ±1 coefficients on the delivered JPEG, re-scored

    /// Delivered Social and Couple JPEGs of `HMB_POSTPASS_LOSSY` (an `hmb compress` output with its `--json` report
    /// at `<dir>.json`): bisection over the zigzag start K (run ≥ 2, all components) for the strongest zeroing that
    /// still reaches the target, on top of the scan post-pass. Files are matched to sources in sorted order and the
    /// match is checked against the report's score.
    @Test(.enabled(if: env["HMB_POSTPASS_LOSSY"] != nil && LiveGate.holdoutReady)) func lossyPostPass() throws {
        let p = LiveGate.primitives!
        let root = URL(fileURLWithPath: Self.env["HMB_POSTPASS_LOSSY"]!, isDirectory: true)
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathExtension("json"))) as! [String: Any]
        var scores: [String: Double] = [:]
        for row in report["rows"] as! [[String: Any]] {
            if let score = row["score"] as? Double { scores["\(row["delivery"]!) \(row["name"]!)"] = score }
        }
        let reported = scores
        let files = LocalData.jpegs(in: LiveGate.holdout!.path)
        let mask = Int(Self.env["HMB_POSTPASS_MASK"] ?? "7") ?? 7
        let presets = DeliveryPreset.builtIns.filter { $0.id == .social || $0.id == .couple }
        struct Row { var delivered = 0, scans = 0, lossy = 0, attempts = 0, ms = 0.0, minScore = 100.0, overBefore = 0.0, overAfter = 0.0 }
        let rows = Locked([String: Row]())
        print("LOSSY before \(LiveGate.uptime())")
        for preset in presets {
            let gate = DispatchSemaphore(value: preset.id == .couple ? 2 : 4)
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                gate.wait(); defer { gate.signal() }
                do {
                    let info = try p.decoder.inspect(files[i])
                    var v = try p.decoder.decode(info)
                    let target = try #require(Targets.target(preset.quality, features: p.processing.features(v)))
                    if preset.colour == .convertToSRGB { v = p.processing.convertedToSRGB(v) }
                    if let edge = preset.size.longEdge { v = p.processing.resized(v, longEdge: edge) }
                    let url = root.appending(path: preset.id == .couple ? "Couple" : "Social").appending(path: String(format: "holdout-%04d.jpg", i + 1))
                    let delivered = try Data(contentsOf: url)
                    let ref = try p.metric.prepareReference(v)
                    defer { p.metric.release(ref) }
                    func score(_ d: Data) throws -> Double { try p.metric.score(try p.decoder.decode(encoded: d), against: ref) }
                    let s0 = try score(delivered)
                    let expected = try #require(reported["\(preset.id.rawValue) \(files[i].lastPathComponent)"])
                    #expect(abs(s0 - expected) < 1e-3, "\(url.lastPathComponent) is not \(files[i].lastPathComponent)")
                    let scans = try JPEGPostPass.optimizeScans(delivered) ?? delivered
                    var best = scans, bestScore = s0, attempts = 0
                    var lo = 4, hi = 64                      // K = hi: nothing zeroed (passes); lo: strongest tried
                    let start = DispatchTime.now().uptimeNanoseconds
                    while hi - lo > 1, attempts < 5 {
                        let k = (lo + hi) / 2
                        let candidate = try JPEGPostPass.rewrite(delivered, minK: k, minRun: 2, componentMask: mask, optimizeScans: true)!
                        let s = try score(candidate)
                        attempts += 1
                        if s >= target { hi = k; if candidate.count < best.count { best = candidate; bestScore = s } } else { lo = k }
                    }
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    rows.withLock {
                        var r = $0[preset.id.rawValue, default: Row()]
                        r.delivered += delivered.count; r.scans += scans.count; r.lossy += best.count; r.attempts += attempts
                        r.ms += ms; r.minScore = min(r.minScore, bestScore); r.overBefore += s0 - target; r.overAfter += bestScore - target
                        $0[preset.id.rawValue] = r
                    }
                } catch {
                    Issue.record("\(files[i].lastPathComponent): \(error)")
                }
            }
        }
        print("LOSSY after \(LiveGate.uptime())")
        for (key, r) in rows.snapshot.sorted(by: { $0.key < $1.key }) {
            let n = Double(files.count)
            print(String(format: "LOSSY %@ mask %d: delivered %d, + scans %d (%+.3f%%), + zeroing %d (%+.3f%%), min score %.3f, overshoot %.3f → %.3f, attempts %.2f, %.0f ms/photo wall",
                         key, mask, r.delivered, r.scans, Double(r.scans - r.delivered) / Double(r.delivered) * 100, r.lossy,
                         Double(r.lossy - r.delivered) / Double(r.delivered) * 100, r.minScore, r.overBefore / n, r.overAfter / n,
                         Double(r.attempts) / n, r.ms / n))
        }
    }

    // MARK: WebP encoder settings (Website: WebP 2560 px, ≥ 70)

    static func tunings(_ text: String) throws -> [(String, hmb_webp_tuning, Double?)] {
        try text.split(separator: ";").map { item in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            var t = hmb_webp_tuning(method: 4, sns_strength: -1, filter_strength: -1, filter_sharpness: -1, filter_type: -1,
                                    autofilter: -1, segments: -1, partition_limit: -1, pass: -1)
            var stop: Double?
            for pair in (parts.count > 1 ? parts[1] : "").split(separator: ",") {
                let kv = pair.split(separator: "=").map(String.init)
                if kv.count == 2, kv[0] == "stop", let x = Double(kv[1]) { stop = x; continue }
                guard kv.count == 2, let v = Int32(kv[1]) else { throw PrimitiveError("bad pair \(pair)") }
                switch kv[0] {
                case "m": t.method = v
                case "sns": t.sns_strength = v
                case "f": t.filter_strength = v
                case "sharp": t.filter_sharpness = v
                case "ftype": t.filter_type = v
                case "af": t.autofilter = v
                case "seg": t.segments = v
                default: throw PrimitiveError("unknown key \(kv[0])")
                }
            }
            return (parts[0], t, stop)
        }
    }

    struct WebRow: Sendable { var bytes: Int; var probes: Int; var score: Double; var encodeMs: Double; var q: Double }

    /// The real Website search (DirectSearch.webp, final metadata) once per tuning; plus the post-pass form: the
    /// first tuning's final q re-encoded with every other tuning and re-scored (kept only when ≥ target).
    @Test(.enabled(if: env["HMB_POSTPASS_WEBP"] != nil && LiveGate.holdoutReady)) func webp() throws {
        let tunings = try Self.tunings(Self.env["HMB_POSTPASS_WEBP"]!)
        let p = LiveGate.primitives!
        let encoder = LibWebPEncoder()
        let files = LocalData.jpegs(in: LiveGate.holdout!.path)
        let preset = DeliveryPreset.builtIns.first { $0.id == .website }!
        let target = Targets.target(preset.quality, features: nil)!
        let rows = Locked([String: [String: WebRow]]())     // tuning → file → result
        let post = Locked([String: [String: WebRow]]())
        let gate = DispatchSemaphore(value: Int(Self.env["HMB_POSTPASS_THREADS"] ?? "3") ?? 3)
        print("WEBP before \(LiveGate.uptime())")
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            gate.wait(); defer { gate.signal() }
            do {
                let info = try p.decoder.inspect(files[i])
                let v = p.processing.resized(p.processing.convertedToSRGB(try p.decoder.decode(info)), longEdge: preset.size.longEdge!)
                let meta = MetadataEditor.output(for: info, policy: preset.metadata, colour: preset.colour)
                let ref = try p.metric.prepareReference(v)
                defer { p.metric.release(ref) }
                let prepared = try encoder.prepare(v)
                var baseQ: Double?
                for (index, (name, tuning, stop)) in tunings.enumerated() {
                    var encodeMs: [Double] = []
                    var constants = SearchConstants.spec
                    if let stop { constants.directStop = stop }
                    let web = try DirectSearch.webp(target: target, constants: constants) { q in
                        var data = Data()
                        encodeMs.append(try Self.ms {
                            data = try encoder.encodeTuned(prepared, quality: Float(q), tuning: tuning, icc: meta.icc, exif: meta.exif, xmp: meta.xmp)
                        })
                        return ProbeRecord(parameter: q, subsampling: nil, score: try p.metric.score(try p.decoder.decode(encoded: data), against: ref), data: data)
                    }
                    let best = try #require(web.best, "\(files[i].lastPathComponent) \(name): no passing WebP")
                    let ms = encodeMs.reduce(0, +) / Double(encodeMs.count)
                    rows.withLock { $0[name, default: [:]][files[i].lastPathComponent] = WebRow(bytes: best.bytes, probes: web.probes.count, score: best.score, encodeMs: ms, q: best.parameter) }
                    if index == 0 { baseQ = best.parameter; continue }
                    // Post-pass form: same q as the first tuning's result.
                    var data = Data()
                    let t = try Self.ms {
                        data = try encoder.encodeTuned(prepared, quality: Float(baseQ!), tuning: tuning, icc: meta.icc, exif: meta.exif, xmp: meta.xmp)
                    }
                    let s = try p.metric.score(try p.decoder.decode(encoded: data), against: ref)
                    post.withLock { $0[name, default: [:]][files[i].lastPathComponent] = WebRow(bytes: data.count, probes: 1, score: s, encodeMs: t, q: baseQ!) }
                }
            } catch {
                Issue.record("\(files[i].lastPathComponent): \(error)")
            }
        }
        print("WEBP after \(LiveGate.uptime())")
        let order = tunings.map(\.0)
        let base = rows.snapshot[order[0]] ?? [:]
        let baseBytes = base.values.reduce(0) { $0 + $1.bytes }
        for name in order {
            let r = Array((rows.snapshot[name] ?? [:]).values)
            let bytes = r.reduce(0) { $0 + $1.bytes }
            print(String(format: "WEBP search %-14@ %d bytes (%+.2f%%)  min %.3f  median %.3f  probes %.2f  encode %.0f ms  n %d", name,
                         bytes, Double(bytes - baseBytes) / Double(max(1, baseBytes)) * 100,
                         r.map(\.score).min() ?? 0, Measure.median(r.map(\.score)), Double(r.reduce(0) { $0 + $1.probes }) / Double(max(1, r.count)),
                         r.map(\.encodeMs).reduce(0, +) / Double(max(1, r.count)), r.count))
        }
        for name in order.dropFirst() {
            // Post-pass semantics per photo: the re-encode at the base q replaces the base result only when it still
            // reaches the target and is smaller.
            let r = post.snapshot[name] ?? [:]
            var total = 0, used = 0, below = 0
            for (file, b) in base {
                if let row = r[file], row.score >= target, row.bytes < b.bytes { total += row.bytes; used += 1 } else { total += b.bytes }
                if let row = r[file], row.score < target { below += 1 }
            }
            print(String(format: "WEBP post %-14@ %d bytes (%+.2f%%), used on %d/%d, below target at same q %d, min %.3f, encode %.0f ms", name,
                         total, Double(total - baseBytes) / Double(max(1, baseBytes)) * 100, used, base.count, below,
                         r.values.map(\.score).min() ?? 0, r.values.map(\.encodeMs).reduce(0, +) / Double(max(1, r.count))))
        }
    }
}
