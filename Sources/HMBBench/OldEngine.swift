import Foundation
import HMBModel

/// Runs the old jpegos `squeeze` CLI on the same set for A/B timing (§5.5 "Old engine A/B"). Its outputs go to
/// `--out/old/…`, never into the jpegos checkout.
public struct OldEngineRunner: Sendable {
    public struct Outcome: Sendable {
        public var rows: [BenchFileRow]
        public var wallSeconds: Double
        public var cpuSeconds: Double
        public var exitStatus: Int32
        public var outputBytes: Int64
    }

    public struct Refused: Error, CustomStringConvertible { public var description: String }

    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    /// The package root of the old engine (the first ancestor with a Package.swift), which outputs must stay out of.
    public var repositoryRoot: URL? {
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path) { return directory }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    public func run(photos: [SourcePhoto], preset: DeliveryPreset, output: URL, run index: Int) throws -> Outcome {
        guard let arguments = DeliveryCatalog.oldEngineArguments(for: preset) else {
            throw Refused(description: "the old engine has no equivalent of the delivery “\(preset.id.rawValue)”")
        }
        if let root = repositoryRoot { try PathSafety.check(output: output, sources: [root]) }
        try PathSafety.check(output: output, sources: photos.map(\.url))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + ["-o", output.path] + photos.map(\.url.path)
        // `hmb` runs with MallocLargeCache=0 (D-ENG-10); the old engine keeps its own default allocator behaviour.
        var environment = ProcessInfo.processInfo.environment
        environment["MallocLargeCache"] = nil
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let usageBefore = ResourceUsage.current(children: true)
        let start = ContinuousClock.now
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let elapsed = ContinuousClock.now - start
        let usageAfter = ResourceUsage.current(children: true)

        let parsed = Self.parse(String(decoding: data, as: UTF8.self))
        let outputs = ((try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let rows = photos.map { photo -> BenchFileRow in
            let name = (photo.relativePath as NSString).lastPathComponent
            let match = Self.output(for: name, in: outputs)
            let bytes = match.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init)
            let line = parsed[name]
            return BenchFileRow(run: index, delivery: preset.id.rawValue, name: photo.relativePath, sourceBytes: photo.byteCount,
                                outputBytes: bytes, score: line?.score, target: nil, probes: 0, seconds: line?.seconds ?? 0,
                                encoder: "old " + (line?.format ?? "?"), chroma: nil, status: bytes == nil ? "failed:missing" : "done")
        }
        return Outcome(rows: rows, wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                       cpuSeconds: usageAfter.cpuSeconds - usageBefore.cpuSeconds, exitStatus: process.terminationStatus,
                       outputBytes: OutputDigest.totalBytes(in: output))
    }

    /// The old engine's output for the source file `name`: same stem (any extension), else the stem followed by a
    /// separator (a suffix the old CLI added). A bare prefix never matches, so `IMG_1` does not claim `IMG_10.jpg`.
    static func output(for name: String, in outputs: [URL]) -> URL? {
        let stem = (name as NSString).deletingPathExtension
        func outputStem(_ url: URL) -> String { (url.lastPathComponent as NSString).deletingPathExtension }
        if let exact = outputs.first(where: { outputStem($0) == stem }) { return exact }
        return outputs.first { url in
            let candidate = outputStem(url)
            guard candidate.hasPrefix(stem), let next = candidate.dropFirst(stem.count).first else { return false }
            return !next.isLetter && !next.isNumber
        }
    }

    public struct Line: Equatable, Sendable {
        public var format: String
        public var score: Double?
        public var seconds: Double?
    }

    /// Parses the old CLI's per-file lines, e.g.
    /// `SH_Wedding_Lissy_Finn0014.jpg  18,6 MB → 1,9 MB  (−89.6%)  JPEG  score 74.1  2.8s`.
    public static func parse(_ output: String) -> [String: Line] {
        var result: [String: Line] = [:]
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            guard line.contains("→"), let name = line.split(separator: " ").first.map(String.init),
                  name.contains(".") else { continue }
            let tokens = line.split(separator: " ").map(String.init)
            var score: Double?
            if let index = tokens.firstIndex(of: "score"), index + 1 < tokens.count { score = Double(tokens[index + 1]) }
            var seconds: Double?
            if let last = tokens.last, last.hasSuffix("s") { seconds = Double(last.dropLast()) }
            var format = "?"
            if let close = tokens.firstIndex(where: { $0.hasSuffix(")") }), close + 1 < tokens.count { format = tokens[close + 1] }
            result[name] = Line(format: format, score: score, seconds: seconds)
        }
        return result
    }
}
