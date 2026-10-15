import Foundation
@testable import HMBBench
import HMBModel
import Testing

@Suite struct ReportTests {
    static func row(_ name: String, delivery: String = "couple", source: Int64 = 1000, output: Int64? = 120, score: Double? = 75,
                    target: Double? = 74, status: String = "done", probes: Int = 2) -> BenchFileRow {
        BenchFileRow(run: 1, delivery: delivery, name: name, sourceBytes: source, outputBytes: output, score: score, target: target,
                     probes: probes, seconds: 0.5, encoder: "jpegli", chroma: "4:2:0", status: status)
    }

    @Test func csvHasTheSpecColumnsInOrder() {
        let csv = CSV.perFile([Self.row("a.jpg")])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "run,delivery,name,source_bytes,output_bytes,score,target,probes,seconds,encoder,chroma,status,byte_exact")
        #expect(lines[1] == "1,couple,a.jpg,1000,120,75.000,74.00,2,0.500,jpegli,4:2:0,done,")
        // §5.5 names: name, source bytes, output bytes, score, target, probes, seconds, encoder, chroma.
        for column in ["name", "source_bytes", "output_bytes", "score", "target", "probes", "seconds", "encoder", "chroma"] {
            #expect(BenchFileRow.csvHeader.contains(column))
        }
    }

    @Test func csvQuotesAwkwardNames() {
        let csv = CSV.perFile([Self.row("Finn, \"Lissy\".jpg")])
        #expect(csv.contains("\"Finn, \"\"Lissy\"\".jpg\""))
        #expect(CSV.field("plain") == "plain")
        #expect(CSV.field("two\nlines") == "\"two\nlines\"")
    }

    @Test func totalsCountScoresBytesAndStatuses() {
        let rows = [
            Self.row("a", score: 74.0), Self.row("b", score: 76.0), Self.row("c", score: 75.0), Self.row("d", score: 80.0),
            Self.row("e", output: 1000, score: nil, target: nil, status: "keptOriginal", probes: 3),
            Self.row("f", output: nil, score: nil, status: "failed:unreadable"),
            Self.row("g", score: 73.0, target: 74),          // below its target
            Self.row("x", delivery: "website", score: 99),
        ]
        let t = DeliveryTotals.make(delivery: "couple", rows: rows, photos: 7, estimate: 1000)
        #expect(t.delivered == 6 && t.keptOriginal == 1 && t.failed == 1)
        #expect(t.sourceBytes == 6000 && t.outputBytes == 5 * 120 + 1000)
        #expect(t.scoreMin == 73 && t.scoreMax == 80 && t.scoreMedian == 75)
        #expect(t.belowTarget == 1)
        #expect(t.meanProbes == 2 && t.maxProbes == 2)              // lossy, done rows only
        #expect(abs(t.savedFraction - (1 - 1600.0 / 6000)) < 1e-12)
        #expect(abs((t.estimateError ?? 0) - 0.6) < 1e-12)
        let even = DeliveryTotals.make(delivery: "couple", rows: [Self.row("a", score: 74), Self.row("b", score: 75)], photos: 2)
        #expect(even.scoreMedian == 74.5)
    }

    @Test func reportJSONRoundTripsWithTheSpecFields() throws {
        let report = Self.sampleReport()
        let data = try report.encoded()
        #expect(try BenchReport.decode(data).encoded() == data)        // dates are whole seconds in ISO 8601
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["schema", "set", "deliveries", "machineBefore", "machineAfter", "provenance", "runs", "rows", "gates", "timingSuppressed"] {
            #expect(object[key] != nil, "missing \(key)")
        }
        let run = try #require((object["runs"] as? [[String: Any]])?.first)
        for key in ["wallSeconds", "secondsPerPhoto", "cpuSecondsPerPhoto", "peakRSSBytes", "deliveries", "loadBefore", "loadAfter"] {
            #expect(run[key] != nil, "missing run.\(key)")
        }
        let totals = try #require((run["deliveries"] as? [[String: Any]])?.first)
        for key in ["outputBytes", "sourceBytes", "savedFraction", "scoreMin", "scoreMedian", "scoreMax"] {
            #expect(totals[key] != nil, "missing totals.\(key)")
        }
        let machine = try #require(object["machineBefore"] as? [String: Any])
        for key in ["loadAverage", "thermalState", "hardwareModel", "lightroomRunning", "availableMemoryBytes"] {
            #expect(machine[key] != nil, "missing machine.\(key)")
        }
        let provenance = try #require(object["provenance"] as? [String: Any])
        #expect(provenance["gitCommit"] != nil && provenance["codecVersions"] != nil)
    }

    @Test func machineStateIsPlausible() {
        let state = MachineState.capture()
        #expect(state.loadAverage.count == 3)
        #expect(state.activeProcessors > 0 && state.physicalMemoryBytes > 0)
        #expect(state.hardwareModel != "unknown")
        #expect((state.availableMemoryBytes ?? 0) > 0)
    }

    @Test func oldEngineOutputLinesParse() {
        let text = """
        SH_Wedding_Lissy_Finn0014.jpg  18,6 MB → 1,9 MB  (−89.6%)  JPEG  score 74.1  2.8s

        19 files  400,3 MB → 49,8 MB  (−87.6%)
        """
        let lines = OldEngineRunner.parse(text)
        #expect(lines.count == 1)
        #expect(lines["SH_Wedding_Lissy_Finn0014.jpg"] == .init(format: "JPEG", score: 74.1, seconds: 2.8))
    }

    static func sampleReport(kind: SetKind = .holdout, deliveries: [DeliveryPreset] = [DeliveryPreset.builtIns[0]],
                             rows: [BenchFileRow] = [row("a.jpg")], wall: Double = 10, load: Double = 1.0,
                             peakRSS: Int64 = 1_000_000_000) -> BenchReport {
        var machine = MachineState.capture()
        machine.loadAverage = [load, load, load]
        let totals = deliveries.map { DeliveryTotals.make(delivery: $0.id.rawValue, rows: rows, photos: Set(rows.map(\.name)).count) }
        return BenchReport(label: "test", command: "bench", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                           set: .init(path: "/set", kind: kind.rawValue, photos: Set(rows.map(\.name)).count, sourceBytes: 1000),
                           deliveries: deliveries, machineBefore: machine, machineAfter: machine,
                           provenance: Provenance(gitCommit: "abc", gitDirty: false, codecVersions: "test", executable: "hmb"),
                           timingSuppressed: load > 3,
                           runs: [BenchRun(engine: "holdmybyte", index: 1, wallSeconds: wall, cpuSeconds: wall * 4, secondsPerPhoto: wall,
                                           cpuSecondsPerPhoto: wall * 4, peakRSSBytes: peakRSS, outputFolder: "/out", phase: "finished",
                                           deliveries: totals, loadBefore: [load], loadAfter: [load])],
                           rows: rows, deterministic: nil, resumeCheck: nil, gates: [])
    }
}
