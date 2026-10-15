// hmb: the holdmybyte command-line tool (Docs/SPEC.md §5.5). Installed in the app at Contents/Helpers/hmb.
// Parsing and the command logic live in HMBBench (`HMBCommand`, `CommandRunner`, `PrimitiveCommands`) so they are
// tested; this file only wires the live engine and prints.
import Foundation
import HMBBench
import HMBEngine
import HMBModel

func standardError(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

func exitWith(_ error: any Error) -> Never {
    standardError("hmb: \(error)")
    exit(error is HMBCommand.UsageError ? 64 : 1)
}

/// The live engine with its own support folder, so CLI journals never mix with the app's. `--workers N` arrives as
/// HMB_WORKERS (exported by `CommandRunner` before this runs; Docs/DECISIONS.md D-ENG-6). HMB_MEMORY_BUDGET (bytes)
/// overrides the engine's memory budget for tuning runs (D-ENG-7); the app never sets it.
func liveEngine() throws -> LiveEngine {
    let support = FileManager.default.temporaryDirectory.appending(path: "holdmybyte-cli-\(getpid())", directoryHint: .isDirectory)
    let environment = ProcessInfo.processInfo.environment
    let workers = environment["HMB_WORKERS"].flatMap(Int.init).map { min(64, max(1, $0)) }
    var options = EngineOptions(workerCount: workers)
    if let budget = environment["HMB_MEMORY_BUDGET"].flatMap(Int64.init), budget > 0 { options.memoryBudget = budget }
    return LiveEngine(primitives: try .live(), supportDirectory: support, options: options)
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

let command: HMBCommand
do { command = try HMBCommand.parse(Array(CommandLine.arguments.dropFirst())) } catch {
    standardError("hmb: \(error)\n\n" + HMBCommand.usage)
    exit(64)
}

do {
    switch command {
    case .help:
        print(HMBCommand.usage)
    case .version:
        print("hmb 2.0 · \(EnginePrimitives.codecVersions)")
    case .score(let reference, let candidate):
        let value = try PrimitiveCommands(primitives: .live()).score(reference: reference, candidate: candidate)
        print(String(format: "%.4f", value))
    case .inspect(let file):
        try printJSON(PrimitiveCommands(primitives: .live()).inspect(file))
    case .compress(let options):
        let report = try await CommandRunner(makeEngine: liveEngine, log: standardError).compress(options)
        let ok = report.runs.allSatisfy { $0.phase == "finished" } && report.rows.allSatisfy { !$0.status.hasPrefix("failed") }
        exit(ok ? 0 : 1)
    case .estimate(let sources, let deliveries):
        let estimates = try await CommandRunner(makeEngine: liveEngine, log: standardError).estimate(sources: sources, deliveries: deliveries)
        for (preset, estimate) in estimates {
            print(String(format: "%@\t%@\t%.1f %%\t%.2f s/photo", preset.id.rawValue, HMBFormat.bytes(estimate.bytes),
                         estimate.fractionOfSource * 100, estimate.secondsPerPhoto))
        }
    case .bench(let options):
        let report = try await CommandRunner(makeEngine: liveEngine, log: standardError).bench(options)
        print(BenchSummary.text(report), terminator: "")
        print("report: \(options.out.appending(path: "report.json").path)")
        exit(report.gates.contains { $0.status == .fail } ? 1 : 0)
    }
} catch {
    exitWith(error)
}
