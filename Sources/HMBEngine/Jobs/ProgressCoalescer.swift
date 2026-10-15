// ProgressCoalescer: results are emitted at most 10× per second, progress at least once per second while
// running (§3.8 Events), and the smoothed seconds-per-photo / ETA (S8: α = 0.1, ETA after 10 photos).
import Foundation
import HMBModel

struct ProgressCoalescer: Sendable {
    static let resultsInterval = 0.1
    static let progressInterval = 0.5        // well inside the ≥ 1 Hz requirement
    private var lastResults = -Double.infinity
    private var lastProgress = -Double.infinity

    enum Emission: Equatable { case none, progress, resultsAndProgress }

    /// Seconds to wait before a final flush so that results events stay at least `resultsInterval` apart.
    func delayBeforeFlush(now: Double) -> Double { max(0, lastResults + Self.resultsInterval - now) }

    /// Decides what to emit at `now` given whether results are pending.
    mutating func tick(now: Double, hasPending: Bool, force: Bool = false) -> Emission {
        if hasPending && (force || now - lastResults >= Self.resultsInterval) {
            lastResults = now
            lastProgress = now
            return .resultsAndProgress
        }
        if force || now - lastProgress >= Self.progressInterval {
            lastProgress = now
            return .progress
        }
        return .none
    }
}

/// Exponentially smoothed seconds per finished photo, over completion intervals.
struct PhotoRate: Sendable {
    static let alpha = 0.1
    static let etaAfter = 10
    private(set) var secondsPerPhoto: Double?
    private(set) var finished = 0
    private var last: Double
    private let parallelism: Double

    init(start: Double, parallelism: Int) {
        last = start
        self.parallelism = Double(max(1, parallelism))
    }

    mutating func photoFinished(at now: Double) {
        let interval = max(0, now - last)
        last = now
        finished += 1
        if let current = secondsPerPhoto {
            secondsPerPhoto = Self.alpha * interval + (1 - Self.alpha) * current
        } else {
            secondsPerPhoto = interval / parallelism   // the first photos finish together after one photo time
        }
    }

    func eta(remaining: Int) -> Double? {
        guard finished >= Self.etaAfter, let s = secondsPerPhoto else { return nil }
        return s * Double(remaining)
    }
}
