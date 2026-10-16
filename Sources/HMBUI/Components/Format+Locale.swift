// Locale-consistent numbers for the UI (Docs/SPEC.md §2.5 Number formatting): scores use the same decimal separator
// as the byte sizes and percentages beside them ("85,4" next to "25,7 MB" in en_DE). The CLI keeps HMBModel's
// POSIX `HMBFormat.score(_:)`; every view goes through these.
import Foundation
import HMBModel

extension HMBFormat {
    /// One decimal in `locale`'s notation, no grouping: 85.44 → "85.4" (en_US) / "85,4" (en_DE, de_DE).
    public static func score(_ s: Double, locale: Locale) -> String {
        guard s.isFinite else { return "–" }
        return s.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale))
    }

    /// Seconds with two decimals in `locale`'s notation: 0.483 → "0.48 s" (en_US) / "0,48 s" (en_DE).
    public static func preciseSeconds(_ s: Double, locale: Locale) -> String {
        guard s.isFinite else { return "–" }
        return s.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(locale)) + " s"
    }
}
