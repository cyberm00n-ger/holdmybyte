import Foundation
import HMBModel

/// `hmb` argument parsing (§5.5). Kept in the library so tests can drive it.
public enum HMBCommand: Equatable, Sendable {
    case compress(CompressOptions)
    case estimate(sources: [URL], deliveries: [DeliverySpec])
    case score(reference: URL, candidate: URL)
    case inspect(URL)
    case bench(BenchOptions)
    case version
    case help

    public enum DeliverySpec: Equatable, Sendable {
        case named(String)
        case json(URL)
    }

    public struct CompressOptions: Equatable, Sendable {
        public var sources: [URL]
        public var output: URL
        public var deliveries: [DeliverySpec]
        public var workers: Int?
        public var json: URL?
        public init(sources: [URL], output: URL, deliveries: [DeliverySpec] = [], workers: Int? = nil, json: URL? = nil) {
            self.sources = sources; self.output = output; self.deliveries = deliveries; self.workers = workers; self.json = json
        }
    }

    public struct BenchOptions: Equatable, Sendable {
        public var set: URL
        public var out: URL
        public var deliveries: [DeliverySpec]
        public var repeatCount: Int
        public var oldEngine: URL?
        public var label: String?
        public var resumeCheck: Bool
        public var setKind: SetKind?
        public var baselines: URL?
        public var workers: Int?
        public init(set: URL, out: URL, deliveries: [DeliverySpec] = [], repeatCount: Int = 1, oldEngine: URL? = nil,
                    label: String? = nil, resumeCheck: Bool = false, setKind: SetKind? = nil, baselines: URL? = nil, workers: Int? = nil) {
            self.set = set; self.out = out; self.deliveries = deliveries; self.repeatCount = repeatCount
            self.oldEngine = oldEngine; self.label = label; self.resumeCheck = resumeCheck; self.setKind = setKind
            self.baselines = baselines; self.workers = workers
        }
    }

    public struct UsageError: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    public static let usage = """
    hmb: holdmybyte from the command line (every write goes through the engine's OutputWriter; nothing is written inside a source)

      hmb compress <src>… -o <dir> [--delivery NAME]… [--delivery-json <preset.json>]… [--workers N] [--json <report.json>]
      hmb estimate <src>… [--delivery NAME]… [--delivery-json <preset.json>]…
      hmb score <reference> <candidate>      engine metric (Metal SSIMULACRA2), prints one number
      hmb inspect <file>                     SourceInfo + features + Balanced target, as JSON
      hmb bench --set <dir> --out <dir> [--delivery NAME]… [--repeat N] [--old-engine <squeeze>] [--label TEXT]
                [--resume-check] [--set-kind holdout|wedding|other] [--baselines <baselines.json>] [--workers N]
      hmb --version

    Delivery names: \(DeliveryCatalog.names.joined(separator: ", ")) (default: couple, website).
    """

    public static func parse(_ arguments: [String]) throws -> HMBCommand {
        guard let first = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())
        func value(_ flag: String) throws -> String {
            guard !rest.isEmpty, !rest[0].hasPrefix("--") || rest[0] == "-" else { throw UsageError("\(flag) needs a value") }
            return rest.removeFirst()
        }
        func url(_ path: String, directory: Bool = false) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: directory).standardizedFileURL
        }
        func int(_ flag: String, _ text: String, range: ClosedRange<Int>) throws -> Int {
            guard let n = Int(text), range.contains(n) else { throw UsageError("\(flag) needs a number in \(range.lowerBound)…\(range.upperBound)") }
            return n
        }

        switch first {
        case "-h", "--help", "help": return .help
        case "--version", "version": return .version
        case "compress", "estimate":
            var sources: [URL] = [], deliveries: [DeliverySpec] = [], output: URL?, workers: Int?, json: URL?
            while !rest.isEmpty {
                let argument = rest.removeFirst()
                switch argument {
                case "-o", "--output": output = url(try value(argument), directory: true)
                case "--delivery": deliveries.append(.named(try value(argument)))
                case "--delivery-json": deliveries.append(.json(url(try value(argument))))
                case "--workers": workers = try int(argument, try value(argument), range: 1...64)
                case "--json": json = url(try value(argument))
                default:
                    if argument.hasPrefix("-") { throw UsageError("unknown option \(argument)") }
                    sources.append(url(argument))
                }
            }
            if sources.isEmpty { throw UsageError("\(first) needs at least one source") }
            if first == "estimate" {
                if output != nil || workers != nil || json != nil { throw UsageError("estimate takes only sources and --delivery") }
                return .estimate(sources: sources, deliveries: deliveries)
            }
            guard let output else { throw UsageError("compress needs -o <dir>") }
            return .compress(CompressOptions(sources: sources, output: output, deliveries: deliveries, workers: workers, json: json))
        case "score":
            guard rest.count == 2 else { throw UsageError("score needs <reference> <candidate>") }
            return .score(reference: url(rest[0]), candidate: url(rest[1]))
        case "inspect":
            guard rest.count == 1 else { throw UsageError("inspect needs one file") }
            return .inspect(url(rest[0]))
        case "bench":
            var set: URL?, out: URL?, deliveries: [DeliverySpec] = [], repeatCount = 1, oldEngine: URL?, label: String?
            var resumeCheck = false, setKind: SetKind?, baselines: URL?, workers: Int?
            while !rest.isEmpty {
                let argument = rest.removeFirst()
                switch argument {
                case "--set": set = url(try value(argument), directory: true)
                case "--out": out = url(try value(argument), directory: true)
                case "--delivery": deliveries.append(.named(try value(argument)))
                case "--delivery-json": deliveries.append(.json(url(try value(argument))))
                case "--repeat": repeatCount = try int(argument, try value(argument), range: 1...10)
                case "--old-engine": oldEngine = url(try value(argument))
                case "--label": label = try value(argument)
                case "--resume-check": resumeCheck = true
                case "--set-kind":
                    let text = try value(argument)
                    guard let kind = SetKind(rawValue: text) else { throw UsageError("--set-kind is holdout, wedding or other") }
                    setKind = kind
                case "--baselines": baselines = url(try value(argument))
                case "--workers": workers = try int(argument, try value(argument), range: 1...64)
                default: throw UsageError("unknown bench option \(argument)")
                }
            }
            guard let set else { throw UsageError("bench needs --set <dir>") }
            guard let out else { throw UsageError("bench needs --out <dir>") }
            return .bench(BenchOptions(set: set, out: out, deliveries: deliveries, repeatCount: repeatCount, oldEngine: oldEngine,
                                       label: label, resumeCheck: resumeCheck, setKind: setKind, baselines: baselines, workers: workers))
        default:
            throw UsageError("unknown command \(first)")
        }
    }

    /// Resolves delivery specs (default: the app's default-on deliveries). Ids must be unique.
    public static func presets(_ specs: [DeliverySpec]) throws -> [DeliveryPreset] {
        let presets = specs.isEmpty
            ? DeliveryPreset.builtIns.filter { DeliveryPreset.defaultOnIDs.contains($0.id) }
            : try specs.map { spec in
                switch spec {
                case .named(let name): try DeliveryCatalog.preset(named: name)
                case .json(let url): try DeliveryCatalog.preset(jsonAt: url)
                }
            }
        var seen: Set<DeliveryID> = []
        for preset in presets where !seen.insert(preset.id).inserted { throw UsageError("delivery \(preset.id.rawValue) given twice") }
        return presets
    }
}
