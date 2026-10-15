import Foundation
import HMBModel

/// One row of the per-file CSV (§5.5): name, source bytes, output bytes, score, target, probes, seconds, encoder, chroma.
/// `delivery`, `status` and `run` are added so one CSV can hold several deliveries and repeats.
public struct BenchFileRow: Codable, Sendable, Hashable {
    public var run: Int
    public var delivery: String
    public var name: String
    public var sourceBytes: Int64
    public var outputBytes: Int64?
    public var score: Double?
    public var target: Double?
    public var probes: Int
    public var seconds: Double
    public var encoder: String?
    public var chroma: String?
    public var status: String
    public var byteExact: Bool?

    public init(run: Int, delivery: String, name: String, sourceBytes: Int64, outputBytes: Int64?, score: Double?,
                target: Double?, probes: Int, seconds: Double, encoder: String?, chroma: String?, status: String,
                byteExact: Bool? = nil) {
        self.run = run; self.delivery = delivery; self.name = name; self.sourceBytes = sourceBytes
        self.outputBytes = outputBytes; self.score = score; self.target = target; self.probes = probes
        self.seconds = seconds; self.encoder = encoder; self.chroma = chroma; self.status = status; self.byteExact = byteExact
    }

    public init(run: Int, result: PhotoResult, photo: SourcePhoto?) {
        self.init(run: run, delivery: result.delivery.rawValue, name: photo?.relativePath ?? "#\(result.photo.index)",
                  sourceBytes: result.inBytes, outputBytes: result.outBytes, score: result.score, target: result.target,
                  probes: result.probes, seconds: result.seconds, encoder: result.encoder, chroma: result.chroma?.rawValue,
                  status: BenchFileRow.statusText(result.status), byteExact: result.byteExact)
    }

    public static func statusText(_ status: PhotoStatus) -> String {
        switch status {
        case .queued: "queued"
        case .working: "working"
        case .done: "done"
        case .keptOriginal: "keptOriginal"
        case .failed(let failure): "failed:" + failure.rawValue
        }
    }

    public var isDelivered: Bool { status == "done" || status == "keptOriginal" }

    /// The fixed CSV column order.
    public static let csvHeader = ["run", "delivery", "name", "source_bytes", "output_bytes", "score", "target", "probes",
                                   "seconds", "encoder", "chroma", "status", "byte_exact"]

    var csvFields: [String] {
        [String(run), delivery, name, String(sourceBytes), outputBytes.map(String.init) ?? "",
         score.map { String(format: "%.3f", $0) } ?? "", target.map { String(format: "%.2f", $0) } ?? "", String(probes),
         String(format: "%.3f", seconds), encoder ?? "", chroma ?? "", status, byteExact.map { $0 ? "1" : "0" } ?? ""]
    }
}

public enum CSV {
    /// RFC 4180: fields with a comma, quote or line break are quoted, quotes doubled. Lines end in "\n".
    public static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func perFile(_ rows: [BenchFileRow]) -> String {
        var lines = [BenchFileRow.csvHeader.joined(separator: ",")]
        lines += rows.map { $0.csvFields.map(field).joined(separator: ",") }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Totals for one delivery in one run (§5.5 "Totals JSON").
public struct DeliveryTotals: Codable, Sendable, Hashable {
    public var delivery: String
    public var photos: Int
    public var delivered: Int
    public var keptOriginal: Int
    public var failed: Int
    public var byteExact: Int
    public var sourceBytes: Int64
    public var outputBytes: Int64
    public var savedFraction: Double
    public var scoreMin: Double?
    public var scoreMedian: Double?
    public var scoreMax: Double?
    /// Photos whose score is below their target (must be 0; §3.12 guarantee 2).
    public var belowTarget: Int
    public var meanProbes: Double?
    public var maxProbes: Int?
    /// The engine's estimate before the run, if one was taken, and its relative error (actual/estimate − 1).
    public var estimatedBytes: Int64?
    public var estimateError: Double?

    public static func make(delivery: String, rows: [BenchFileRow], photos: Int, estimate: Int64? = nil) -> DeliveryTotals {
        let mine = rows.filter { $0.delivery == delivery }
        let delivered = mine.filter(\.isDelivered)
        let scores = mine.filter { $0.status == "done" }.compactMap(\.score).sorted()
        let lossyProbes = mine.filter { $0.status == "done" && $0.score != nil }.map(\.probes)
        let source = delivered.reduce(Int64(0)) { $0 + $1.sourceBytes }
        let output = delivered.reduce(Int64(0)) { $0 + ($1.outputBytes ?? 0) }
        let median: Double? = scores.isEmpty ? nil : scores.count.isMultiple(of: 2)
            ? (scores[scores.count / 2 - 1] + scores[scores.count / 2]) / 2 : scores[scores.count / 2]
        return DeliveryTotals(
            delivery: delivery, photos: photos, delivered: delivered.count,
            keptOriginal: mine.filter { $0.status == "keptOriginal" }.count,
            failed: mine.filter { $0.status.hasPrefix("failed") }.count,
            byteExact: mine.filter { $0.byteExact == true }.count,
            sourceBytes: source, outputBytes: output, savedFraction: source > 0 ? 1 - Double(output) / Double(source) : 0,
            scoreMin: scores.first, scoreMedian: median, scoreMax: scores.last,
            belowTarget: mine.filter { row in
                guard let score = row.score, let target = row.target, row.status == "done" else { return false }
                return score < target
            }.count,
            meanProbes: lossyProbes.isEmpty ? nil : Double(lossyProbes.reduce(0, +)) / Double(lossyProbes.count),
            maxProbes: lossyProbes.max(),
            estimatedBytes: estimate,
            estimateError: estimate.flatMap { $0 > 0 ? Double(output) / Double($0) - 1 : nil })
    }
}

/// One engine (or old-engine) run over the set.
public struct BenchRun: Codable, Sendable, Hashable {
    public var engine: String                // "holdmybyte" | "old"
    public var index: Int                    // 1-based repeat
    public var wallSeconds: Double
    public var cpuSeconds: Double
    public var secondsPerPhoto: Double
    public var cpuSecondsPerPhoto: Double
    public var peakRSSBytes: Int64?
    public var outputFolder: String
    public var phase: String                 // final JobPhase, e.g. "finished"
    public var deliveries: [DeliveryTotals]
    public var loadBefore: [Double]
    public var loadAfter: [Double]
}

public enum GateStatus: String, Codable, Sendable { case pass, fail, notEvaluated = "not-evaluated", notApplicable = "not-applicable" }

public struct GateResult: Codable, Sendable, Hashable {
    public var id: String
    public var status: GateStatus
    public var detail: String
    public init(id: String, status: GateStatus, detail: String) { self.id = id; self.status = status; self.detail = detail }
}

public struct BenchReport: Codable, Sendable, Hashable {
    public struct SetInfo: Codable, Sendable, Hashable {
        public var path: String
        public var kind: String              // "holdout" | "wedding" | "other"
        public var photos: Int
        public var sourceBytes: Int64
    }

    public var schema = HMBBench.reportSchema
    public var label: String?
    public var command: String
    public var startedAt: Date
    public var set: SetInfo
    public var deliveries: [DeliveryPreset]
    public var machineBefore: MachineState
    public var machineAfter: MachineState
    public var provenance: Provenance
    /// True when the 1-minute load average at start exceeded the quiet threshold: timing gates are not reported.
    public var timingSuppressed: Bool
    public var runs: [BenchRun]
    /// Per-file rows of every run.
    public var rows: [BenchFileRow]
    /// Byte-identical outputs across the holdmybyte repeats (nil with one run).
    public var deterministic: Bool?
    public var resumeCheck: ResumeCheck?
    public var gates: [GateResult]

    /// The fastest holdmybyte run (§6.2: "the faster run counts").
    public var bestRun: BenchRun? { runs.filter { $0.engine == "holdmybyte" && $0.phase == "finished" }.min { $0.wallSeconds < $1.wallSeconds } }
    public var bestOldRun: BenchRun? { runs.filter { $0.engine == "old" }.min { $0.wallSeconds < $1.wallSeconds } }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> BenchReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BenchReport.self, from: data)
    }
}

/// G8: stop at about `stopFraction`, resume, compare with an uninterrupted run.
public struct ResumeCheck: Codable, Sendable, Hashable {
    public var stoppedAfterPhotos: Int
    public var filesCompared: Int
    public var identical: Bool
    public var mismatches: [String]
    public var leftoverTemporaryFiles: [String]
}
