// Compare (Docs/SPEC.md §2.4 S14): the pure parts — which photos can be compared, in which order, the spot-check
// count, the copy of the HUD and labels, and the rules for Show Original. No AppKit, fully unit-tested.
import CoreGraphics
import Foundation
import HMBModel

enum CompareSequence {
    /// The last result per photo for `delivery` that has a delivered file (done or kept original).
    static func deliveredResults(_ record: WeddingRecord, delivery: DeliveryID) -> [PhotoID: PhotoResult] {
        var latest: [PhotoID: PhotoResult] = [:]
        for result in record.results where result.delivery == delivery { latest[result.photo] = result }
        return latest.filter { _, result in result.status == .done || result.status == .keptOriginal }
    }

    /// Lossy deliveries of `record` in record order. The archive is byte-exact and never offered in Compare.
    static func lossyDeliveries(_ record: WeddingRecord) -> [DeliveryPreset] {
        record.deliveries.filter(\.isLossy)
    }

    /// `requested` if it is a lossy delivery of `record`, otherwise the first lossy delivery (nil: none).
    static func resolvedDelivery(_ requested: DeliveryID, in record: WeddingRecord) -> DeliveryID? {
        let lossy = lossyDeliveries(record)
        return lossy.first { $0.id == requested }?.id ?? lossy.first?.id
    }

    /// Delivered photos of `delivery` in `order`. Ties (and kept originals, which have no score) fall back to
    /// capture order; kept originals come last in Lowest Score First.
    static func make(_ record: WeddingRecord, delivery: DeliveryID, order: CompareOrder) -> [PhotoID] {
        let results = deliveredResults(record, delivery: delivery)
        let ids = results.keys.sorted()
        switch order {
        case .captureTime:
            return ids
        case .lowestScore:
            return ids.sorted { a, b in
                let sa = results[a]?.score ?? .infinity, sb = results[b]?.score ?? .infinity
                return sa != sb ? sa < sb : a < b
            }
        case .largestSavings:
            return ids.sorted { a, b in
                let fa = savedFraction(results[a]), fb = savedFraction(results[b])
                return fa != fb ? fa > fb : a < b
            }
        }
    }

    static func savedFraction(_ result: PhotoResult?) -> Double {
        guard let result, result.inBytes > 0, let out = result.outBytes else { return 0 }
        return 1 - Double(out) / Double(result.inBytes)
    }

    /// K = clamp(ceil(0.03 × photos), 5, 12), never more than there are photos.
    static func hardestCount(_ photos: Int) -> Int {
        guard photos > 0 else { return 0 }
        return min(photos, min(12, max(5, Int((0.03 * Double(photos)).rounded(.up)))))
    }
}

enum CompareCopy {
    static func spotCheckToast(_ k: Int) -> String {
        "You’ve checked the \(k) hardest photos. Everything else scored higher."
    }

    /// "12 of 535" or, in a spot-check in Lowest Score First within the first K, "Hardest 3 of 12".
    static func counter(_ state: CompareState, locale: Locale = .current) -> String {
        let count = state.sequence.count
        guard count > 0 else { return "–" }
        let n = state.position + 1
        let k = CompareSequence.hardestCount(count)
        if state.route.spotCheck, state.order == .lowestScore, n <= k {
            return "Hardest \(n.formatted(.number.locale(locale))) of \(k.formatted(.number.locale(locale)))"
        }
        return "\(n.formatted(.number.locale(locale))) of \(count.formatted(.number.locale(locale)))"
    }

    static func orderTitle(_ order: CompareOrder) -> String {
        switch order {
        case .captureTime: "Capture Time"
        case .lowestScore: "Lowest Score First"
        case .largestSavings: "Largest Savings First"
        }
    }

    /// "21.4 MB → 2.61 MB · −88 %"
    static func sizeLine(original: Int64, delivered: Int64, locale: Locale = .current) -> String {
        let fraction = original > 0 ? 1 - Double(delivered) / Double(original) : 0
        return "\(HMBFormat.bytes(original, locale: locale)) → \(HMBFormat.bytes(delivered, locale: locale)) · \(HMBFormat.savedPercent(fraction, locale: locale))"
    }

    static func originalLabel(bytes: Int64?, available: Bool, locale: Locale = .current) -> String {
        guard available else { return "Original not available" }
        return bytes.map { "Original · \(HMBFormat.bytes($0, locale: locale))" } ?? "Original"
    }

    static func deliveredLabel(bytes: Int64?, locale: Locale = .current) -> String {
        bytes.map { "Delivered · \(HMBFormat.bytes($0, locale: locale))" } ?? "Delivered"
    }

    static func connectVolume(_ volume: String?) -> String {
        volume.map { "Connect “\($0)” to compare." } ?? "The original isn’t available."
    }

    static let differencesLegend = "Differences amplified 10×"
    static let originalCapsule = "Original"

    static func comparedResized(_ edge: Int, locale: Locale = .current) -> String {
        "Compared with the original resized to \(edge.formatted(.number.grouping(.never).locale(locale))) px."
    }

    static func metadataText(_ policy: MetadataPolicy) -> String {
        switch policy {
        case .keepAll: "Kept"
        case .removeLocation: "Location removed"
        case .removeAll: "Removed except copyright"
        }
    }

    /// "Target 85 · High"; Balanced: "Target 74.6 · Balanced".
    static func targetLine(target: Double?, quality: QualityLevel) -> String {
        guard let target else { return quality.displayName }
        let text = target.rounded() == target ? String(Int(target)) : HMBFormat.score(target)
        return "Target \(text) · \(quality.displayName)"
    }

    /// Display name of a colour space ("Display P3", "sRGB IEC61966-2.1", …).
    static func colourName(_ space: CGColorSpace?) -> String? {
        guard let space else { return nil }
        if let name = space.name {
            let known: [CFString: String] = [
                CGColorSpace.sRGB: "sRGB", CGColorSpace.displayP3: "Display P3", CGColorSpace.adobeRGB1998: "Adobe RGB (1998)",
                CGColorSpace.genericGrayGamma2_2: "Grey", CGColorSpace.linearGray: "Grey",
            ]
            if let label = known[name] { return label }
        }
        if let icc = space.copyICCData() as Data?, let description = iccDescription(icc) { return description }
        return space.name.map { $0 as String }
    }

    /// The `desc` tag of an ICC profile (v2 `desc` or v4 `mluc`, first record).
    static func iccDescription(_ icc: Data) -> String? {
        let bytes = [UInt8](icc)
        func u32(_ o: Int) -> Int { o + 4 <= bytes.count ? Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3]) : 0 }
        guard bytes.count > 132 else { return nil }
        let count = u32(128)
        for i in 0..<min(count, 100) {
            let entry = 132 + i * 12
            guard entry + 12 <= bytes.count, String(bytes: bytes[entry..<entry + 4], encoding: .ascii) == "desc" else { continue }
            let offset = u32(entry + 4)
            guard offset + 12 <= bytes.count else { return nil }
            let type = String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
            if type == "desc" {
                let length = u32(offset + 8)
                guard length > 1, offset + 12 + length <= bytes.count else { return nil }
                return String(bytes: bytes[(offset + 12)..<(offset + 11 + length)], encoding: .ascii)
            }
            if type == "mluc" {
                let recordLength = u32(offset + 20 + 4), recordOffset = u32(offset + 20 + 8)
                let start = offset + recordOffset
                guard recordLength > 0, start + recordLength <= bytes.count else { return nil }
                return String(bytes: bytes[start..<(start + recordLength)], encoding: .utf16BigEndian)
            }
        }
        return nil
    }
}

extension CompareState {
    /// Split is offered only with an original to compare against.
    var canSplit: Bool { originalAvailable }
    /// `\` (Show Original) needs the original.
    var canShowOriginal: Bool { originalAvailable }
    /// `D` (Differences) needs the original.
    var canShowDifferences: Bool { originalAvailable }

    /// Enforces the invariants after any change: no original → no Show Original and no Differences; divider in
    /// 0…1; centre in the unit square; position inside the sequence.
    mutating func normalise() {
        if !originalAvailable {
            showsOriginal = false
            originalLatched = false
            showsDifferences = false
        }
        if !showsOriginal { originalLatched = false }
        divider = min(1, max(0, divider.isFinite ? divider : 0.5))
        zoomCenter = CGPoint(x: min(1, max(0, zoomCenter.x.isFinite ? zoomCenter.x : 0.5)),
                             y: min(1, max(0, zoomCenter.y.isFinite ? zoomCenter.y : 0.5)))
        position = sequence.isEmpty ? 0 : min(sequence.count - 1, max(0, position))
    }

    /// `\` pressed. A press while latched releases the latch (and is consumed). Returns whether this press started
    /// showing the original; pass that to `originalKeyUp`. Key repeats return false.
    mutating func originalKeyDown() -> Bool {
        guard canShowOriginal else { return false }
        if originalLatched {
            originalLatched = false
            showsOriginal = false
            return false
        }
        if showsOriginal { return false }
        showsOriginal = true
        return true
    }

    /// `\` released after `heldFor` seconds. Released within 200 ms: latch on. Held longer: back to the delivered.
    mutating func originalKeyUp(heldFor: TimeInterval, pressStarted: Bool) {
        guard pressStarted, showsOriginal else { return }
        if heldFor < Self.latchThreshold {
            originalLatched = true
        } else {
            showsOriginal = false
        }
    }

    static let latchThreshold: TimeInterval = 0.2

    var currentPhoto: PhotoID? { sequence.indices.contains(position) ? sequence[position] : nil }
}
