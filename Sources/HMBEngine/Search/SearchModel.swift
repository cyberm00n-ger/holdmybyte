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

    /// How full-size probes are aimed (Docs/ENGINE.md §3.2). `.proxyCurve` is the original §3.4 loop (bias against a
    /// 3-point piecewise-linear proxy curve); `.mosaicExact` predicts a full-resolution score as the mosaic's score
    /// *at the same distance* (encoded and scored exactly, so jpegli's quantiser steps are tracked) plus a per-photo bias.
    public enum Aim: String, Sendable, Hashable { case proxyCurve, mosaicExact }
    public var aim: Aim = .mosaicExact
    /// `.mosaicExact`: full − mosaic before any full probe (holdout median, live ImageIO decode).
    public var exactBiasPrior = -1.1
    /// `.mosaicExact`: d(full − mosaic)/d ln d, used while only one side of the bracket is known.
    public var exactBiasSlope = -0.6
    /// `.mosaicExact`: margins above T for the first and for later full probes, and the accept rule.
    public var exactFirstMargin = 0.0
    public var exactMargin = 0.03
    public var exactStop = 0.15
    /// `.mosaicExact`: mosaic evaluations per aim (the solver stops earlier once the bracket is below `exactSolverWidth`).
    public var exactSolverEvals = 6
    public var exactSolverWidth = 0.004
    /// `.mosaicExact`: no full probe within this distance (ln d) of an earlier one — inside a quantiser step the bytes and
    /// the score do not change, and a bracket this narrow straddles a step.
    public var exactMinStep = 0.003
    /// `.mosaicExact`: the margin grows by this for every failing full probe after the first (0: off; the holdout A/B
    /// preferred the rescue below).
    public var exactFailStep = 0.0
    /// `.mosaicExact`: when no full probe passes, the first rescue probe is aimed by the model at T + this (instead of
    /// d × 0.8, which overshoots by 2–3 points); further rescue probes use d × 0.8.
    public var exactRescueMargin = 0.3
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

    /// WebP quality prior, fitted on the holdout at 2560 px (median q reaching T: 65 → 72, 70 → 80, 75 → 86, 80 → 90,
    /// 85 → 94; Docs/ENGINE.md §3.1). §3.5's 75 at T = 70 was 5 q too low.
    public static func webpPrior(_ target: Double) -> Double {
        min(100, max(5, webpPriorAt70 + webpPriorSlope * (target - 70)))
    }
    public static let webpPriorAt70 = 80.0
    public static let webpPriorSlope = 1.1
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
