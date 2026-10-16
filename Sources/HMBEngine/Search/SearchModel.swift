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
    /// DirectSearch for JPEG (Social, small full-size): the same rule with a tighter window. jpegli's distance is
    /// continuous, so a narrower window costs ~0.4 probes on a ≤ 5 MP variant and saves ~2 % of the bytes (holdout,
    /// Social 1440 ≥ 85: 6.158 → 6.016 MB, overshoot 0.44 → 0.24, probes 3.58 → 3.95; Docs/DECISIONS.md D-ENG-8). WebP
    /// keeps `directStop`: its integer q steps are coarser than a tighter window (holdout Website: no gain, more probes).
    public var directStopJPEG = 0.5
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
    /// Quantisation-table tuning of every full-size JPEG probe and mosaic encode (Docs/ENGINE.md §3.5).
    public var jpegTuning = JPEGTuning.fullSize
    /// The same for resized JPEG deliveries (Social, WebP fallback) and small full-size images (DirectSearch).
    public var directJPEGTuning = JPEGTuning.resized
    /// DirectSearch JPEG searches 4:4:4 first (no 4:2:0) at targets from this up: with `JPEGTuning.resized`, 4:4:4
    /// is 7–12 % smaller than 4:2:0 at T 85 (1024/1440 px) and 4:2:0 cannot reach 90 at 1440 px, while 4:2:0 wins
    /// at T 70–74. `.infinity`: the §3.5 order (4:2:0, d = dMin, then 4:4:4).
    public var direct444From = 80.0
    /// Variant "postpass" (Docs/variants/postpass.md): full-size JPEG probes are encoded with the per-component
    /// progressive AC script estimated from the first mosaic encode of their subsampling, and JPEGs found by
    /// DirectSearch get the lossless scan post-pass. Neither changes a coefficient, so scores are unaffected.
    public var optimizeScans = true
    /// Variant "postpass": layout whitespace in XMP packets (see `XMPMinify`).
    public var xmpLayout: XMPLayout = .minifiedUnlessKeepAll
    /// Variant "postpass": JPEGs found by DirectSearch (Social, small full-size, WebP fallback) try up to this many
    /// rewrites that zero isolated ±1 AC coefficients (bisection over the zigzag start), each re-scored; the
    /// smallest that still reaches the target is delivered. 0 = off.
    public var zeroingAttempts = 4
    public init() {}
    public static let spec = SearchConstants()
}

/// How jpegli's quantisation tables are derived from the searched distance d (Docs/ENGINE.md §3.5). The search still
/// moves one parameter (d); the tuning fixes the shape of the tables around it. Every setting is a standard JPEG.
public struct JPEGTuning: Sendable, Hashable {
    /// Cb/Cr tables at d × this (jpegli: 1).
    public var chromaRatio = 1.0
    /// Luma / chroma AC entries at row + col ≥ 4 scaled by exp(tilt·(f − 3)/11) (jpegli: 0).
    public var lumaTilt = 0.0
    public var chromaTilt = 0.0
    /// DC entries at the table's distance × this (jpegli: 1).
    public var dcRatio = 1.0
    /// jpegli's adaptive quantisation (jpegli: on).
    public var adaptiveQuantization = true
    public init(chromaRatio: Double = 1, lumaTilt: Double = 0, chromaTilt: Double = 0, dcRatio: Double = 1,
                adaptiveQuantization: Bool = true) {
        self.chromaRatio = chromaRatio; self.lumaTilt = lumaTilt; self.chromaTilt = chromaTilt; self.dcRatio = dcRatio
        self.adaptiveQuantization = adaptiveQuantization
    }
    /// jpegli's own tables.
    public static let jpegli = JPEGTuning()
    /// Full-size JPEG (MosaicSearch): finer chroma and DC, coarser luma high frequencies. Holdout, real search:
    /// 50.240 → 48.523 MB (−3.4 %), 1.95 → 1.84 probes, 19/19 ≥ 74; T = 85: −6.6 % (Docs/variants/search.md).
    public static let fullSize = JPEGTuning(chromaRatio: 0.65, lumaTilt: 1.6, dcRatio: 0.8)
    /// Resized deliveries (DirectSearch): finer chroma and no adaptive quantisation, jpegli's table shape otherwise
    /// (the full-size tilt costs +3 % at 1440 px, T = 85: a downscaled photo's high frequencies are detail, a 45 MP
    /// original's are mostly sensor noise). Holdout frontiers vs jpegli 4:2:0: 1440 px T 74 −5.8 % (4:2:0), T 85
    /// −12.5 % (4:4:4, `direct444From`), 2560 px T 70 −2.9 %, 1024 px T 85 −7.2 % (Docs/variants/search.md).
    public static let resized = JPEGTuning(chromaRatio: 0.7, adaptiveQuantization: false)
    public var isIdentity: Bool { self == .jpegli }

    public func knobs(distance d: Double, subsampling: ChromaSubsampling) -> JPEGKnobs {
        var k = JPEGKnobs(distance: d, chromaDistance: chromaRatio == 1 ? nil : min(25, d * chromaRatio),
                          sampling: subsampling == .s444 ? .s444 : .s420, adaptiveQuantization: adaptiveQuantization)
        k.lumaTilt = lumaTilt
        k.chromaTilt = chromaTilt
        k.dcRatio = dcRatio
        return k
    }
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
