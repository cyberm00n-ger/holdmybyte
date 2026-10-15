// Targets, priors and the shared probe/result types of the searches (§3.3–§3.5).
import Foundation
import HMBModel

/// Binding search constants (§3.4, §3.5). Retuning requires a holdout A/B recorded in Docs/ENGINE.md.
public struct SearchConstants: Sendable, Hashable {
    public var m0 = 0.6
    public var m1 = 0.15
    public var bias = -1.5
    public var stop = 0.5
    public var maxFull = 3
    public var rescue = 2
    public var dMin = 0.5
    /// Proxy curve bisection range (ln d).
    public var lnDistanceRange: ClosedRange<Double> = log(0.3)...log(8)
    /// Hard limits for any probe distance.
    public var distanceLimits: ClosedRange<Double> = 0.1...25
    /// DirectSearch: stop at the first passing probe with s − T below this, or after `directMaxProbes`.
    public var directStop = 1.0
    public var directMaxProbes = 5
    /// E2 chroma gate: also search 4:4:4 when chromaEnergy ≥ this. Off unless `chromaGate` is set.
    public var chromaGateThreshold = 2.42
    public var chromaGate = false
    public init() {}
    public static let spec = SearchConstants()
}

public enum Targets {
    /// Per-photo target on the engine's SSIMULACRA2 scale; nil for lossless.
    public static func target(_ quality: QualityLevel, features: ImageFeatures?) -> Double? {
        switch quality {
        case .lossless: return nil
        case .balanced: return balanced(textureP50: features?.textureP50 ?? 0)
        default: return quality.floor
        }
    }

    /// Ported verbatim from jpegos ClassicTarget: smooth regime 74, else 88 − 0.62·p50 clamped to 75…87.
    public static func balanced(textureP50 p50: Double) -> Double {
        if p50 < 4.5 { return 74 }
        return min(87, max(75, 88 - 0.62 * p50))
    }

    /// JPEG distance prior: exp(0.693 + 0.06·(74 − T)) → 74: 2.00, 85: 1.03, 90: 0.77.
    public static func jpegPrior(_ target: Double) -> Double { exp(0.693 + 0.06 * (74 - target)) }

    /// WebP quality prior: 75 at T = 70 (§3.5). The slope is a placeholder until it is fitted on the holdout
    /// with live primitives (Docs/ENGINE.md).
    public static func webpPrior(_ target: Double) -> Double { min(100, max(5, 75 + webpPriorSlope * (target - 70))) }
    public static let webpPriorSlope = 1.5
}

/// One encoded candidate and its verified score.
struct ProbeRecord: Sendable {
    var parameter: Double                   // JPEG distance or WebP quality
    var subsampling: ChromaSubsampling?     // JPEG only
    var score: Double
    var data: Data
    var bytes: Int { data.count }
    func passes(_ target: Double) -> Bool { score >= target }
}

/// What a lossy search decided.
enum SearchOutcome: Sendable {
    case encoded(ProbeRecord)
    case keepOriginal
    case unreachable
}

struct SearchResult: Sendable {
    var outcome: SearchOutcome
    /// Every full-resolution probe, in order (proxy encodes are not counted).
    var probes: [ProbeRecord]
    var fullProbes: Int { probes.count }
    /// WebP fell back to JPEG.
    var usedFallback = false
}

/// Smallest passing probe.
func bestPassing(_ probes: [ProbeRecord], target: Double) -> ProbeRecord? {
    probes.filter { $0.passes(target) }.min { $0.bytes < $1.bytes }
}
