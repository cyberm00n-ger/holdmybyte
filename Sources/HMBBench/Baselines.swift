import Foundation

/// `Benchmarks/baselines.json`: the old engine's and JPEGmini's numbers plus the gate thresholds (§5.5, §6.2).
public struct Baselines: Codable, Sendable, Hashable {
    public struct Result: Codable, Sendable, Hashable {
        public var label: String?
        public var bytes: Int64
        public var savedFraction: Double?
        public var scoreMin: Double?
        public var scoreMedian: Double?
        public var scoreMax: Double?
        public var byteExact: Int?
        public var wallSeconds: Double?
        public var secondsPerPhoto: Double?
        public var cpuSecondsPerPhoto: Double?
        public var source: String?
    }

    public struct OldWedding: Codable, Sendable, Hashable {
        public var couple: Result
        public var highFull: Result
        public var website: Result
        public var social: Result
        public var archive: Result
        public var allFourSeparateRunsWallSeconds: Double
        public var allFourBytes: Int64?
        public var secondsPerPhotoCouple: Double?
    }

    public struct Wedding: Codable, Sendable, Hashable {
        public var name: String
        public var photos: Int
        public var sourceBytes: Int64
        public var jpegmini: Result
        public var oldEngine: OldWedding
    }

    public struct HoldoutFile: Codable, Sendable, Hashable {
        public struct AtV2Floor: Codable, Sendable, Hashable {
            /// The old engine's `-t` target that produced it (74 = the Classic output itself).
            public var target: Double
            public var bytes: Int64
            public var v2Score: Double
        }
        public var name: String
        public var sourceBytes: Int64
        public var oldBytes: Int64
        public var oldReferenceScore: Double
        public var oldOwnScore: Double
        /// The old output re-scored with v2's decoder and metric (Docs/METRIC.md §4).
        public var oldV2Score: Double?
        /// The smallest old-engine output whose v2 score reaches the floor (Docs/DECISIONS.md D-ENG-1).
        public var oldAtV2Floor: AtV2Floor?
        /// APPn/COM bytes in the old output and in v2's Couple's Package output (keepAll).
        public var oldMetadataBytes: Int64?
        public var v2MetadataBytes: Int64?
    }

    public struct HoldoutAtV2Floor: Codable, Sendable, Hashable {
        public var label: String?
        public var bytes: Int64
        public var metadataBytes: Int64?
        public var v2MetadataBytes: Int64?
        public var source: String?
    }

    public struct HoldoutOldEngine: Codable, Sendable, Hashable {
        public var target: String?
        public var bytes: Int64
        public var wallSeconds: Double
        public var userSeconds: Double?
        public var systemSeconds: Double?
        public var peakRSSBytes: Int64?
        public var fullProbesPerPhoto: Double?
        public var source: String?
    }

    public struct Holdout: Codable, Sendable, Hashable {
        public var photos: Int
        public var sourceBytes: Int64
        public var oldEngine: HoldoutOldEngine
        /// The old engine held to v2's measured floor (the G1 basis since D-ENG-1).
        public var oldEngineAtV2Floor: HoldoutAtV2Floor?
        public var files: [HoldoutFile]
    }

    public struct Gates: Codable, Sendable, Hashable {
        public struct Single: Codable, Sendable, Hashable {
            public var set: String
            public var delivery: String?
            public var deliveries: [String]?
            public var minScore: Double?
            public var maxBytes: Int64?
            public var maxMeanProbes: Double?
            public var maxWallSeconds: Double?
            public var maxWallSecondsAlone: Double?
            public var maxWallRatioToOldEngine: Double?
            public var maxEstimateError: Double?
            public var maxPeakRSSBytes: Int64?
            public var stopFraction: Double?
            /// Where the threshold comes from, when it is not the spec's number (Docs/DECISIONS.md).
            public var basis: String?
        }
        public struct Limits: Codable, Sendable, Hashable {
            public var minScore: Double?
            public var maxBytes: Int64?
            public var maxWallSecondsAlone: Double?
        }
        public struct WebsiteSocial: Codable, Sendable, Hashable {
            public var set: String
            public var website: Limits
            public var social: Limits
        }
        public var quietLoadAverage: Double
        public var G1: Single
        public var G2: Single
        public var G3: Single
        public var G4: Single
        public var G5: WebsiteSocial
        public var G6: Single
        public var G7: Single
        public var G8: Single
    }

    public var schema: Int
    public var wedding: Wedding
    public var holdout: Holdout
    public var gates: Gates

    public static func load(from url: URL) throws -> Baselines {
        try JSONDecoder().decode(Baselines.self, from: Data(contentsOf: url))
    }

    /// `Benchmarks/baselines.json` next to the working directory or above the executable (repo checkout), if any.
    public static func defaultURL(executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")) -> URL? {
        var candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 { candidates.append(directory); directory.deleteLastPathComponent() }
        return candidates.map { $0.appending(path: "Benchmarks/baselines.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
