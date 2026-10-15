import Foundation
import HMBModel

/// Which reference set a bench ran on (decides which gates apply).
public enum SetKind: String, Codable, Sendable {
    case holdout, wedding, other

    /// Holdout: exactly the baseline's 19 file names. Wedding: the baseline's photo count and total size (±1 %).
    public static func detect(photos: [SourcePhoto], baselines: Baselines?) -> SetKind {
        guard let baselines else { return .other }
        let names = Set(photos.map { ($0.relativePath as NSString).lastPathComponent })
        if names == Set(baselines.holdout.files.map(\.name)) { return .holdout }
        let bytes = photos.reduce(Int64(0)) { $0 + $1.byteCount }
        if photos.count == baselines.wedding.photos,
           abs(Double(bytes) / Double(baselines.wedding.sourceBytes) - 1) <= 0.01 { return .wedding }
        return .other
    }
}

/// Gates G1–G8 (§6.2) for one bench report. A gate applies only to its set and deliveries; timing parts need a run
/// that contains only the gate's deliveries ("alone") and a quiet machine.
public enum GateEvaluator {
    public static func evaluate(_ report: BenchReport, baselines: Baselines) -> [GateResult] {
        let gates = baselines.gates
        let kind = SetKind(rawValue: report.set.kind) ?? .other
        let ids = Set(report.deliveries.map(\.id.rawValue))
        let best = report.bestRun
        func totals(_ delivery: String) -> DeliveryTotals? { best?.deliveries.first { $0.delivery == delivery } }
        let suppressed = report.timingSuppressed
        let loadText = String(format: "%.2f", report.machineBefore.load1)

        func notApplicable(_ id: String, _ why: String) -> GateResult { GateResult(id: id, status: .notApplicable, detail: why) }
        func noRun(_ id: String) -> GateResult { GateResult(id: id, status: .notEvaluated, detail: "no finished holdmybyte run") }

        /// Combines byte/quality checks with an optional timing check into one result.
        func combine(_ id: String, checks: [(Bool, String)], timing: (Bool, String)?, timingRequired: Bool,
                     timingUnavailable: String?) -> GateResult {
            var parts = checks.map { ($0.0 ? "ok: " : "FAIL: ") + $0.1 }
            let failed = checks.contains { !$0.0 }
            if let timing {
                parts.append((timing.0 ? "ok: " : "FAIL: ") + timing.1)
                let status: GateStatus = failed || !timing.0 ? .fail : .pass
                return GateResult(id: id, status: status, detail: parts.joined(separator: "; "))
            }
            if timingRequired, let why = timingUnavailable { parts.append("timing not evaluated: " + why) }
            if failed { return GateResult(id: id, status: .fail, detail: parts.joined(separator: "; ")) }
            return GateResult(id: id, status: timingRequired ? .notEvaluated : .pass, detail: parts.joined(separator: "; "))
        }

        func timingBlocker(alone: Set<String>) -> String? {
            if suppressed { return "1-minute load \(loadText) > \(gates.quietLoadAverage)" }
            if ids != alone { return "the run must contain only \(alone.sorted().joined(separator: " + "))" }
            return nil
        }

        func mb(_ bytes: Int64) -> String { String(format: "%.2f MB", Double(bytes) / 1e6) }
        func gb(_ bytes: Int64) -> String { String(format: "%.3f GB", Double(bytes) / 1e9) }
        func quality(_ t: DeliveryTotals) -> (Bool, String) {
            (t.belowTarget == 0 && t.failed == 0 && t.delivered == t.photos,
             "\(t.delivered)/\(t.photos) delivered, \(t.belowTarget) below target, \(t.failed) failed, \(t.keptOriginal) kept original")
        }

        var results: [GateResult] = []

        // G1: holdout, Couple’s Package bytes, quality and probes.
        if kind == .holdout, ids.contains("couple") {
            if let t = totals("couple"), let limit = gates.G1.maxBytes, let maxProbes = gates.G1.maxMeanProbes {
                results.append(combine("G1", checks: [
                    quality(t),
                    (t.outputBytes <= limit, "total \(mb(t.outputBytes)) ≤ \(mb(limit)) (old engine \(mb(baselines.holdout.oldEngine.bytes)))"),
                    ((t.meanProbes ?? .infinity) <= maxProbes, "mean probes \(t.meanProbes.map { String(format: "%.2f", $0) } ?? "–") ≤ \(maxProbes)"),
                ], timing: nil, timingRequired: false, timingUnavailable: nil))
            } else { results.append(noRun("G1")) }
        } else { results.append(notApplicable("G1", "holdout set with couple only")) }

        // G2: holdout, wall time vs the old engine in the same session.
        if kind == .holdout, ids.contains("couple") {
            if let blocker = timingBlocker(alone: ["couple"]) {
                results.append(GateResult(id: "G2", status: .notEvaluated, detail: blocker))
            } else if let best, let old = report.bestOldRun, let ratio = gates.G2.maxWallRatioToOldEngine {
                let measured = best.wallSeconds / max(old.wallSeconds, 0.001)
                results.append(GateResult(id: "G2", status: measured <= ratio ? .pass : .fail,
                                          detail: String(format: "%.1f s vs old %.1f s = %.2f× (≤ %.2f×)", best.wallSeconds, old.wallSeconds, measured, ratio)))
            } else {
                results.append(GateResult(id: "G2", status: .notEvaluated, detail: "needs --old-engine in the same session"))
            }
        } else { results.append(notApplicable("G2", "holdout set with couple only")) }

        // G3: wedding, Couple’s Package.
        if kind == .wedding, ids.contains("couple") {
            if let t = totals("couple"), let best, let limit = gates.G3.maxBytes, let wall = gates.G3.maxWallSeconds {
                let blocker = timingBlocker(alone: ["couple"])
                results.append(combine("G3", checks: [quality(t), (t.outputBytes <= limit, "total \(gb(t.outputBytes)) ≤ \(gb(limit))")],
                                       timing: blocker == nil ? (best.wallSeconds <= wall, String(format: "wall %.0f s ≤ %.0f s", best.wallSeconds, wall)) : nil,
                                       timingRequired: true, timingUnavailable: blocker))
            } else { results.append(noRun("G3")) }
        } else { results.append(notApplicable("G3", "wedding set with couple")) }

        // G4: wedding, custom High full-size.
        if kind == .wedding, ids.contains("high-full") {
            if let t = totals("high-full"), let minScore = gates.G4.minScore, let limit = gates.G4.maxBytes {
                results.append(combine("G4", checks: [
                    ((t.scoreMin ?? 0) >= minScore && t.failed == 0, "min \(t.scoreMin.map { String(format: "%.1f", $0) } ?? "–") ≥ \(minScore)"),
                    (t.outputBytes <= limit, "total \(gb(t.outputBytes)) ≤ \(gb(limit))"),
                ], timing: nil, timingRequired: false, timingUnavailable: nil))
            } else { results.append(noRun("G4")) }
        } else { results.append(notApplicable("G4", "wedding set with high-full")) }

        // G5: wedding, Website and Social.
        if kind == .wedding, ids.contains("website") || ids.contains("social") {
            var checks: [(Bool, String)] = []
            var timing: (Bool, String)?
            var blocker: String?
            if ids.contains("website"), let t = totals("website") {
                let limits = gates.G5.website
                checks.append(((t.scoreMin ?? 0) >= (limits.minScore ?? 0) && t.failed == 0, "website min \(t.scoreMin.map { String(format: "%.1f", $0) } ?? "–") ≥ \(limits.minScore ?? 0)"))
                if let limit = limits.maxBytes { checks.append((t.outputBytes <= limit, "website \(mb(t.outputBytes)) ≤ \(mb(limit))")) }
                blocker = timingBlocker(alone: ["website"])
                if blocker == nil, let best, let wall = limits.maxWallSecondsAlone {
                    timing = (best.wallSeconds <= wall, String(format: "website alone %.0f s ≤ %.0f s", best.wallSeconds, wall))
                }
            }
            if ids.contains("social"), let t = totals("social") {
                let limits = gates.G5.social
                checks.append(((t.scoreMin ?? 0) >= (limits.minScore ?? 0) && t.failed == 0, "social min \(t.scoreMin.map { String(format: "%.1f", $0) } ?? "–") ≥ \(limits.minScore ?? 0)"))
                if let limit = limits.maxBytes { checks.append((t.outputBytes <= limit, "social \(mb(t.outputBytes)) ≤ \(mb(limit))")) }
            }
            results.append(checks.isEmpty ? noRun("G5")
                           : combine("G5", checks: checks, timing: timing, timingRequired: ids.contains("website"), timingUnavailable: blocker))
        } else { results.append(notApplicable("G5", "wedding set with website or social")) }

        // G6: wedding, Archive.
        if kind == .wedding, ids.contains("archive") {
            if let t = totals("archive"), let best, let limit = gates.G6.maxBytes {
                let blocker = timingBlocker(alone: ["archive"])
                results.append(combine("G6", checks: [
                    (t.byteExact == t.photos, "\(t.byteExact)/\(t.photos) byte-exact"),
                    (t.outputBytes <= limit, "total \(gb(t.outputBytes)) ≤ \(gb(limit))"),
                ], timing: blocker == nil ? gates.G6.maxWallSecondsAlone.map { (best.wallSeconds <= $0, String(format: "wall %.0f s ≤ %.0f s", best.wallSeconds, $0)) } : nil,
                   timingRequired: true, timingUnavailable: blocker))
            } else { results.append(noRun("G6")) }
        } else { results.append(notApplicable("G6", "wedding set with archive")) }

        // G7: wedding, all four deliveries in one run.
        let allFour = Set(gates.G7.deliveries ?? ["couple", "website", "social", "archive"])
        if kind == .wedding, allFour.isSubset(of: ids) {
            if let best {
                var checks: [(Bool, String)] = []
                if let maxError = gates.G7.maxEstimateError {
                    for delivery in allFour.sorted() {
                        if let error = totals(delivery)?.estimateError {
                            checks.append((abs(error) <= maxError, String(format: "%@ estimate error %+.1f %%", delivery, error * 100)))
                        } else {
                            checks.append((false, "\(delivery): no estimate recorded"))
                        }
                    }
                }
                if let maxRSS = gates.G7.maxPeakRSSBytes, let rss = best.peakRSSBytes {
                    checks.append((rss <= maxRSS, "peak RSS \(gb(rss)) ≤ \(gb(maxRSS))"))
                }
                let blocker = timingBlocker(alone: allFour)
                results.append(combine("G7", checks: checks,
                                       timing: blocker == nil ? gates.G7.maxWallSeconds.map { (best.wallSeconds <= $0, String(format: "wall %.0f s ≤ %.0f s", best.wallSeconds, $0)) } : nil,
                                       timingRequired: true, timingUnavailable: blocker))
            } else { results.append(noRun("G7")) }
        } else { results.append(notApplicable("G7", "wedding set with all four deliveries")) }

        // G8: stop, resume, compare.
        if let check = report.resumeCheck {
            let ok = check.identical && check.leftoverTemporaryFiles.isEmpty
            let scope = kind == .wedding ? "" : " (on the \(kind.rawValue) set; the gate itself is defined on the wedding)"
            results.append(GateResult(id: "G8", status: ok ? .pass : .fail,
                                      detail: "stopped after \(check.stoppedAfterPhotos) photos; \(check.filesCompared) files compared, "
                                          + "\(check.mismatches.count) mismatches, \(check.leftoverTemporaryFiles.count) leftover temporary files" + scope))
        } else if kind == .wedding, ids.contains("couple") {
            results.append(GateResult(id: "G8", status: .notEvaluated, detail: "run with --resume-check"))
        } else { results.append(notApplicable("G8", "wedding set with couple and --resume-check")) }

        return results
    }
}
