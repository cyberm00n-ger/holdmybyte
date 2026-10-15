import Foundation
import HMBEngine
import HMBModel

/// Executes the engine-backed `hmb` commands (compress, estimate, bench) against any `EngineService`.
/// `hmb` passes a `LiveEngine`; tests pass a fake.
public struct CommandRunner: Sendable {
    public struct Refused: Error, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Creates the engine once the arguments passed every safety check (so a refusal never depends on the engine).
    public let makeEngine: @Sendable () throws -> any EngineService
    /// Progress and summary lines (stderr in `hmb`).
    public let log: @Sendable (String) -> Void

    public init(makeEngine: @escaping @Sendable () throws -> any EngineService, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.makeEngine = makeEngine
        self.log = log
    }

    public init(engine: any EngineService, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(makeEngine: { engine }, log: log)
    }

    static func processorUse(workers: Int?) -> ProcessorUse {
        guard let workers else { return .automatic }
        // JobRequest has no worker count (§3.9); HMB_WORKERS is the hand-over to the engine (Docs/WP5-NOTES.md Q3).
        setenv("HMB_WORKERS", String(workers), 1)
        return workers <= 2 ? .gentle : .automatic
    }

    // MARK: compress

    /// Scans, preflights and runs one job; returns its report (also written to `--json`). Refuses before any work
    /// when the output or the report path is inside a source.
    @discardableResult
    public func compress(_ options: HMBCommand.CompressOptions) async throws -> BenchReport {
        let presets = try HMBCommand.presets(options.deliveries)
        try PathSafety.check(output: options.output, sources: options.sources)
        if let json = options.json { try PathSafety.check(output: json, sources: options.sources) }
        let engine = try makeEngine()
        let jobs = EngineJobRunner(engine: engine)
        let machineBefore = MachineState.capture()
        let started = Date()
        let scan = try await jobs.scan(options.sources)
        guard !scan.photos.isEmpty else { throw Refused("no photos found in the sources") }
        try PathSafety.check(output: options.output, sources: scan.sourceRoots)
        var request = JobRequest(wedding: WeddingID(), name: scan.suggestedName, photos: scan.photos, sourceRoots: scan.sourceRoots,
                                 deliveries: presets, outputFolder: options.output, naming: .default,
                                 processorUse: Self.processorUse(workers: options.workers))
        let preflight = await engine.preflight(request)
        for notice in preflight.notices { log("\(notice.severity.rawValue): \(notice)") }
        guard preflight.canStart else { throw Refused("preflight blocked the job (see the notices above)") }
        request.outputFolder = preflight.outputFolder
        try PathSafety.check(output: request.outputFolder, sources: options.sources + scan.sourceRoots)
        log("compressing \(scan.photos.count) photos (\(HMBFormat.bytes(scan.totalBytes))) → \(request.outputFolder.path)")

        let log = self.log
        let outcome = await jobs.run(request) { progress in
            log(HMBFormat.statusLine(done: progress.photosDone, total: progress.photosTotal, etaSeconds: progress.etaSeconds,
                                     finishing: false))
        }
        await engine.discardJournal(request.wedding)
        let report = makeReport(command: "compress", label: nil, started: started, setPath: options.sources.map(\.path).joined(separator: " "),
                                kind: .other, photos: scan.photos, presets: presets, machineBefore: machineBefore,
                                runs: [(outcome, request.outputFolder)], estimates: [:], baselines: nil)
        for totals in report.runs.first?.deliveries ?? [] { log(Self.summaryLine(totals)) }
        if let json = options.json { try report.encoded().write(to: json, options: .atomic) }
        return report
    }

    // MARK: estimate

    public func estimate(sources: [URL], deliveries: [HMBCommand.DeliverySpec]) async throws -> [(DeliveryPreset, DeliveryEstimate)] {
        let presets = try HMBCommand.presets(deliveries)
        let engine = try makeEngine()
        let scan = try await EngineJobRunner(engine: engine).scan(sources)
        guard !scan.photos.isEmpty else { throw Refused("no photos found in the sources") }
        let estimates = try await engine.estimate(photos: scan.photos, deliveries: presets)
        return presets.compactMap { preset in estimates[preset.id].map { (preset, $0) } }
    }

    // MARK: bench

    public func bench(_ options: HMBCommand.BenchOptions) async throws -> BenchReport {
        let presets = try HMBCommand.presets(options.deliveries)
        try PathSafety.check(output: options.out, sources: [options.set])
        let fileManager = FileManager.default
        if let existing = try? fileManager.contentsOfDirectory(atPath: options.out.path), !existing.isEmpty {
            throw Refused("--out \(options.out.path) is not empty; use a new folder per bench")
        }
        let oldEngine = options.oldEngine.map(OldEngineRunner.init(executable:))
        if let oldEngine {
            guard fileManager.isExecutableFile(atPath: oldEngine.executable.path) else { throw Refused("--old-engine is not executable") }
            if let root = oldEngine.repositoryRoot { try PathSafety.check(output: options.out, sources: [root]) }
            for preset in presets where DeliveryCatalog.oldEngineArguments(for: preset) == nil {
                throw Refused("the old engine has no equivalent of \(preset.id.rawValue)")
            }
        }
        let baselines = try options.baselines.map(Baselines.load(from:)) ?? Baselines.defaultURL().map(Baselines.load(from:))
        let engine = try makeEngine()
        let jobs = EngineJobRunner(engine: engine)
        try fileManager.createDirectory(at: options.out, withIntermediateDirectories: true)

        let machineBefore = MachineState.capture()
        let quietLimit = baselines?.gates.quietLoadAverage ?? 3
        if machineBefore.load1 > quietLimit {
            log(String(format: "machine not quiet (1-minute load %.2f > %.1f): timing gates will not be reported", machineBefore.load1, quietLimit))
        }
        let started = Date()
        let scan = try await jobs.scan([options.set])
        guard !scan.photos.isEmpty else { throw Refused("no photos found in \(options.set.path)") }
        let kind = options.setKind ?? SetKind.detect(photos: scan.photos, baselines: baselines)
        log("set: \(scan.photos.count) photos, \(HMBFormat.bytes(scan.totalBytes)), kind \(kind.rawValue)")

        // Estimates first (G7 compares them with the actual bytes).
        let estimateStart = ContinuousClock.now
        let estimates = (try? await engine.estimate(photos: scan.photos, deliveries: presets)) ?? [:]
        log(String(format: "estimates in %.2f s", Self.seconds(ContinuousClock.now - estimateStart)))

        var runs: [(EngineJobRunner.Outcome, URL)] = []
        var oldRuns: [(OldEngineRunner.Outcome, URL, DeliveryPreset)] = []
        let processorUse = Self.processorUse(workers: options.workers)
        let log = self.log
        for index in 1...options.repeatCount {
            // A/B/A/B: holdmybyte, then the old engine, per repeat.
            let folder = options.out.appending(path: "new/run-\(index)", directoryHint: .isDirectory)
            var request = JobRequest(wedding: WeddingID(), name: scan.suggestedName, photos: scan.photos, sourceRoots: scan.sourceRoots,
                                     deliveries: presets, outputFolder: folder, naming: .default, processorUse: processorUse)
            let preflight = await engine.preflight(request)
            guard preflight.canStart else { throw Refused("preflight blocked the bench: \(preflight.notices)") }
            request.outputFolder = preflight.outputFolder
            try PathSafety.check(output: request.outputFolder, sources: [options.set] + scan.sourceRoots)
            log("run \(index): holdmybyte → \(request.outputFolder.path)")
            let outcome = await jobs.run(request) { progress in
                if progress.photosDone > 0, progress.photosDone % 50 == 0 || progress.photosDone == progress.photosTotal {
                    log("  \(progress.photosDone)/\(progress.photosTotal)")
                }
            }
            await engine.discardJournal(request.wedding)
            log(String(format: "run %d: %@ in %.1f s", index, EngineJobRunner.phaseText(outcome.phase), outcome.wallSeconds))
            runs.append((outcome, request.outputFolder))

            if let oldEngine {
                for preset in presets {
                    let folder = options.out.appending(path: "old/run-\(index)/\(preset.folderName)", directoryHint: .isDirectory)
                    log("run \(index): old engine \(preset.id.rawValue) → \(folder.path)")
                    let old = try oldEngine.run(photos: scan.photos, preset: preset, output: folder, run: index)
                    log(String(format: "run %d: old engine exit %d in %.1f s", index, old.exitStatus, old.wallSeconds))
                    oldRuns.append((old, folder, preset))
                }
            }
        }

        var report = makeReport(command: "bench", label: options.label, started: started, setPath: options.set.path, kind: kind,
                                photos: scan.photos, presets: presets, machineBefore: machineBefore, runs: runs,
                                estimates: estimates, baselines: baselines)
        for (old, folder, preset) in oldRuns {
            let photos = scan.photos.count
            let index = old.rows.first?.run ?? 1
            if let existing = report.runs.firstIndex(where: { $0.engine == "old" && $0.index == index }) {
                report.runs[existing].wallSeconds += old.wallSeconds
                report.runs[existing].cpuSeconds += old.cpuSeconds
                report.runs[existing].deliveries.append(DeliveryTotals.make(delivery: preset.id.rawValue, rows: old.rows, photos: photos))
            } else {
                report.runs.append(BenchRun(engine: "old", index: index, wallSeconds: old.wallSeconds, cpuSeconds: old.cpuSeconds,
                                            secondsPerPhoto: old.wallSeconds / Double(photos), cpuSecondsPerPhoto: old.cpuSeconds / Double(photos),
                                            peakRSSBytes: nil, outputFolder: folder.deletingLastPathComponent().path,
                                            phase: old.exitStatus == 0 ? "finished" : "exit \(old.exitStatus)",
                                            deliveries: [DeliveryTotals.make(delivery: preset.id.rawValue, rows: old.rows, photos: photos)],
                                            loadBefore: [], loadAfter: MachineState.loadAverage()))
            }
            report.rows += old.rows.map { row in var row = row; row.delivery = "old:" + row.delivery; return row }
        }
        for i in report.runs.indices where report.runs[i].engine == "old" {
            report.runs[i].secondsPerPhoto = report.runs[i].wallSeconds / Double(scan.photos.count)
            report.runs[i].cpuSecondsPerPhoto = report.runs[i].cpuSeconds / Double(scan.photos.count)
        }

        // Determinism across repeats.
        if runs.count > 1 {
            let digests = runs.map { OutputDigest.files(in: $0.1) }
            report.deterministic = digests.dropFirst().allSatisfy { OutputDigest.differences($0, digests[0]).isEmpty }
        }

        // G8: stop at ~40 %, resume, compare with run 1.
        if options.resumeCheck, let reference = runs.first?.1 {
            let fraction = baselines?.gates.G8.stopFraction ?? 0.4
            let stopAfter = max(1, Int((Double(scan.photos.count) * fraction).rounded()))
            let folder = options.out.appending(path: "resume", directoryHint: .isDirectory)
            var request = JobRequest(wedding: WeddingID(), name: scan.suggestedName, photos: scan.photos, sourceRoots: scan.sourceRoots,
                                     deliveries: presets, outputFolder: folder, naming: .default, processorUse: processorUse)
            request.outputFolder = await engine.preflight(request).outputFolder
            log("resume check: stop after \(stopAfter) photos, then resume → \(request.outputFolder.path)")
            let first = await jobs.run(request, stopAfterPhotos: stopAfter)
            log("resume check: first part \(EngineJobRunner.phaseText(first.phase))")
            _ = await jobs.run(request, resume: true)
            await engine.discardJournal(request.wedding)
            let mismatches = OutputDigest.differences(OutputDigest.files(in: reference), OutputDigest.files(in: request.outputFolder))
            report.resumeCheck = ResumeCheck(stoppedAfterPhotos: first.lastProgress?.photosDone ?? stopAfter,
                                             filesCompared: OutputDigest.files(in: reference).count, identical: mismatches.isEmpty,
                                             mismatches: Array(mismatches.prefix(50)),
                                             leftoverTemporaryFiles: OutputDigest.temporaryFiles(in: request.outputFolder))
        }

        report.machineAfter = MachineState.capture()
        if let baselines { report.gates = GateEvaluator.evaluate(report, baselines: baselines) }
        try report.encoded().write(to: options.out.appending(path: "report.json"), options: .atomic)
        try Data(CSV.perFile(report.rows).utf8).write(to: options.out.appending(path: "files.csv"), options: .atomic)
        try Data(BenchSummary.text(report).utf8).write(to: options.out.appending(path: "summary.txt"), options: .atomic)
        return report
    }

    // MARK: Report assembly

    func makeReport(command: String, label: String?, started: Date, setPath: String, kind: SetKind, photos: [SourcePhoto],
                    presets: [DeliveryPreset], machineBefore: MachineState, runs: [(EngineJobRunner.Outcome, URL)],
                    estimates: [DeliveryID: DeliveryEstimate], baselines: Baselines?) -> BenchReport {
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var rows: [BenchFileRow] = []
        var benchRuns: [BenchRun] = []
        for (index, (outcome, folder)) in runs.enumerated() {
            let runRows = outcome.results.map { BenchFileRow(run: index + 1, result: $0, photo: byID[$0.photo]) }
            rows += runRows
            benchRuns.append(BenchRun(
                engine: "holdmybyte", index: index + 1, wallSeconds: outcome.wallSeconds, cpuSeconds: outcome.cpuSeconds,
                secondsPerPhoto: outcome.wallSeconds / Double(max(1, photos.count)),
                cpuSecondsPerPhoto: outcome.cpuSeconds / Double(max(1, photos.count)), peakRSSBytes: outcome.peakRSSBytes,
                outputFolder: folder.path, phase: EngineJobRunner.phaseText(outcome.phase),
                deliveries: presets.map { DeliveryTotals.make(delivery: $0.id.rawValue, rows: runRows, photos: photos.count,
                                                              estimate: estimates[$0.id]?.bytes) },
                loadBefore: index == 0 ? machineBefore.loadAverage : [], loadAfter: MachineState.loadAverage()))
        }
        let quietLimit = baselines?.gates.quietLoadAverage ?? 3
        return BenchReport(
            label: label, command: command, startedAt: started,
            set: .init(path: setPath, kind: kind.rawValue, photos: photos.count, sourceBytes: photos.reduce(0) { $0 + $1.byteCount }),
            deliveries: presets, machineBefore: machineBefore, machineAfter: MachineState.capture(), provenance: Provenance.capture(),
            timingSuppressed: machineBefore.load1 > quietLimit, runs: benchRuns, rows: rows, deterministic: nil, resumeCheck: nil, gates: [])
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func summaryLine(_ t: DeliveryTotals) -> String {
        var text = "\(t.delivery): \(t.delivered)/\(t.photos) delivered, \(HMBFormat.bytes(t.sourceBytes, locale: Locale(identifier: "en_US"))) → "
            + "\(HMBFormat.bytes(t.outputBytes, locale: Locale(identifier: "en_US"))) (\(HMBFormat.savedPercent(t.savedFraction, locale: Locale(identifier: "en_US"))))"
        if let low = t.scoreMin, let median = t.scoreMedian, let high = t.scoreMax {
            text += String(format: ", scores %.1f / %.1f / %.1f", low, median, high)
        }
        if t.keptOriginal > 0 { text += ", \(t.keptOriginal) kept original" }
        if t.failed > 0 { text += ", \(t.failed) FAILED" }
        if t.belowTarget > 0 { text += ", \(t.belowTarget) BELOW TARGET" }
        return text
    }
}

/// The human-readable `summary.txt` of a bench.
public enum BenchSummary {
    public static func text(_ report: BenchReport) -> String {
        var lines: [String] = []
        lines.append("holdmybyte bench\(report.label.map { " · " + $0 } ?? "") · \(ISO8601DateFormatter().string(from: report.startedAt))")
        lines.append("set: \(report.set.path) (\(report.set.kind), \(report.set.photos) photos, \(String(format: "%.2f GB", Double(report.set.sourceBytes) / 1e9)))")
        lines.append("deliveries: \(report.deliveries.map(\.id.rawValue).joined(separator: ", "))")
        let m = report.machineBefore
        lines.append("machine: \(m.hardwareModel), \(m.activeProcessors) cores, load \(m.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")) → "
                     + "\(report.machineAfter.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")), thermal \(m.thermalState), "
                     + "Lightroom \(m.lightroomRunning ? "running" : "not running")")
        lines.append("build: \(report.provenance.gitCommit)\(report.provenance.gitDirty == true ? " (dirty)" : "") · \(report.provenance.codecVersions)")
        if report.timingSuppressed { lines.append("timing gates suppressed: machine not quiet") }
        for run in report.runs {
            lines.append(String(format: "%@ run %d: %@, wall %.1f s (%.3f s/photo), CPU %.3f s/photo%@", run.engine, run.index, run.phase,
                                run.wallSeconds, run.secondsPerPhoto, run.cpuSecondsPerPhoto,
                                run.peakRSSBytes.map { String(format: ", peak RSS %.2f GB", Double($0) / 1e9) } ?? ""))
            for totals in run.deliveries { lines.append("  " + CommandRunner.summaryLine(totals)) }
        }
        if let deterministic = report.deterministic { lines.append("deterministic across repeats: \(deterministic ? "yes" : "NO")") }
        for gate in report.gates { lines.append("\(gate.id) \(gate.status.rawValue): \(gate.detail)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
