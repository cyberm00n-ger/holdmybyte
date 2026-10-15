import Foundation

/// All numbers the UI shows go through here.
public enum HMBFormat {
    /// `ByteCountFormatStyle(style: .file)` (decimal, as Finder): "10.95 GB" (en_US), "10,95 GB" (en_DE, de_DE).
    /// Zero is written as a number ("0 bytes"), never spelled out.
    public static func bytes(_ n: Int64, locale: Locale = .current) -> String {
        ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: locale).format(n)
    }

    /// Saved fraction as a signed, rounded percentage with U+2212 and the locale's percent spacing:
    /// 0.877 → "−88 %" (de, en_DE) / "−88%" (en_US). Growth (negative fraction) is "+5 %"; zero is "0 %".
    public static func savedPercent(_ fraction: Double, locale: Locale = .current) -> String {
        let percent = Int((fraction * 100).rounded())
        let magnitude = (Double(abs(percent)) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        switch percent {
        case 1...: return "\u{2212}" + magnitude
        case ..<0: return "+" + magnitude
        default: return magnitude
        }
    }

    /// One decimal, always "." (scores are a metric, not prose): 85.44 → "85.4".
    public static func score(_ s: Double) -> String {
        guard s.isFinite else { return "–" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), s)
    }

    /// "38 s", "4 min 12 s" ("4 min" on the minute), "1 h 20 min" ("2 h" on the hour). Rounded to whole seconds.
    public static func duration(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        if total < 60 { return "\(total) s" }
        if total < 3600 {
            let m = total / 60, s = total % 60
            return s == 0 ? "\(m) min" : "\(m) min \(s) s"
        }
        let h = total / 3600, m = (total % 3600) / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// The S8 status line, exact copy, with counts grouped for `Locale.current`.
    public static func statusLine(done: Int, total: Int, etaSeconds: Double?, finishing: Bool) -> String {
        statusLine(done: done, total: total, etaSeconds: etaSeconds, finishing: finishing, locale: .current)
    }

    /// The S8 status line with counts grouped for `locale` ("1,800" en_US, "1.800" en_DE).
    /// Precedence: finishing → "Finishing…"; nothing done → "Starting…"; fewer than 10 done or no ETA →
    /// "estimating time…"; ETA < 60 s → "less than a minute left"; ETA ≤ 60 min → "about N min left";
    /// otherwise "about H h M min left".
    public static func statusLine(done: Int, total: Int, etaSeconds: Double?, finishing: Bool, locale: Locale) -> String {
        if finishing { return "Finishing…" }
        if done <= 0 { return "Starting…" }
        let counts = "\(done.formatted(.number.locale(locale))) of \(total.formatted(.number.locale(locale))) photos"
        guard done >= 10, let eta = etaSeconds, eta.isFinite else { return "\(counts) · estimating time…" }
        if eta < 60 { return "\(counts) · less than a minute left" }
        if eta <= 3600 { return "\(counts) · about \(max(1, Int((eta / 60).rounded()))) min left" }
        let minutes = Int((eta / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(counts) · about \(h) h left" : "\(counts) · about \(h) h \(m) min left"
    }

    /// Expands {wedding}, {date} (ISO "2026-07-12") and {year} ("2026"). Without a date, the date tokens are dropped
    /// together with separators left dangling. "/" and ":" become "-" so the result is one path component.
    /// An empty result falls back to the wedding name.
    public static func folderName(pattern: String, wedding: String, date: Date?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var name = pattern.replacingOccurrences(of: "{wedding}", with: wedding)
        if let date {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let iso = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            name = name.replacingOccurrences(of: "{date}", with: iso)
                .replacingOccurrences(of: "{year}", with: String(format: "%04d", c.year ?? 0))
        } else {
            name = name.replacingOccurrences(of: "{date}", with: "").replacingOccurrences(of: "{year}", with: "")
        }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = tidy(name)
        return name.isEmpty ? tidy(wedding.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")) : name
    }

    /// Expands {wedding} (slugged, see `WeddingNaming.slug`) and {number} (zero-padded to at least 4 digits, or
    /// to the digit count of `count`), then appends "." + `ext`: "Finn-und-Lissy-0001.jpg".
    public static func fileName(pattern: String, wedding: String, number: Int, count: Int, ext: String) -> String {
        let width = max(4, String(max(count, 0)).count)
        let digits = String(max(number, 0))
        let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
        var stem = pattern.replacingOccurrences(of: "{wedding}", with: WeddingNaming.slug(wedding))
            .replacingOccurrences(of: "{number}", with: padded)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = padded }
        return ext.isEmpty ? stem : stem + "." + ext
    }

    /// Collapses whitespace runs and trims whitespace and dangling separators ("–", "—", "-", "_", "·") at both ends.
    static func tidy(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " –—-_·"))
    }
}
