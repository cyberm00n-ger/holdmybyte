import Foundation
import HMBModel

/// Building blocks for the domain fixtures. Everything is deterministic: no `Date()`, no `UUID()`, no system state.
public enum FixtureFactory {
    /// The home folder used by every fixture path (fixed, so snapshots do not depend on the machine).
    public static let home = URL(fileURLWithPath: "/Users/sebastian", isDirectory: true)
    public static let weddingsFolder = home.appending(path: "Weddings", directoryHint: .isDirectory)
    public static let timeZone = TimeZone(identifier: "Europe/Berlin")!

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// A Europe/Berlin wall-clock date.
    public static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// Deterministic wedding ids: 00000000-0000-4000-8000-<n, 12 digits>.
    public static func weddingID(_ n: Int) -> WeddingID {
        WeddingID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!)
    }

    // MARK: Photos

    /// `count` photos in capture order, whose byte counts sum to exactly `totalBytes`.
    /// About a quarter are portrait. Capture times run from `firstCapture` over `hours`.
    public static func photos(count: Int, totalBytes: Int64, root: URL, firstCapture: Date, hours: Double,
                              camera: String, pixelSize: (width: Int, height: Int), filePrefix: String = "DSC",
                              firstNumber: Int = 1, seed: UInt64) -> [SourcePhoto] {
        var random = FixtureRandom(seed: seed)
        let weights = (0..<count).map { _ in random.uniform(0.7...1.3) }
        let bytes = distribute(totalBytes, weights: weights)
        let step = count > 1 ? hours * 3600 / Double(count - 1) : 0
        let modified = firstCapture.addingTimeInterval(3 * 86_400)
        return (0..<count).map { i in
            let portrait = random.unit() < 0.27
            let name = String(format: "%@%05d.jpg", filePrefix, firstNumber + i)
            let capture = firstCapture.addingTimeInterval((Double(i) * step + random.uniform(0...(step * 0.6))).rounded())
            return SourcePhoto(id: PhotoID(i), url: root.appending(path: name, directoryHint: .notDirectory),
                               relativePath: name, byteCount: bytes[i],
                               pixelWidth: portrait ? pixelSize.height : pixelSize.width,
                               pixelHeight: portrait ? pixelSize.width : pixelSize.height,
                               captureDate: capture, camera: camera, kind: .jpeg, modified: modified)
        }
    }

    /// Splits `total` proportionally to `weights`; the parts sum to exactly `total`.
    public static func distribute(_ total: Int64, weights: [Double]) -> [Int64] {
        guard !weights.isEmpty else { return [] }
        let sum = weights.reduce(0, +)
        var parts = weights.map { Int64((Double(total) * $0 / sum).rounded(.down)) }
        var remainder = total - parts.reduce(0, +)
        var i = 0
        while remainder != 0 {
            let delta: Int64 = remainder > 0 ? 1 : -1
            parts[i % parts.count] += delta
            remainder -= delta
            i += 1
        }
        return parts
    }

    // MARK: Scores

    /// `count` scores (two decimals) with exactly the given minimum, maximum and median (count ≥ 3), skewed towards
    /// the minimum like real per-photo searches, in a seeded random order.
    public static func scores(count: Int, min lo: Double, max hi: Double, median: Double, seed: UInt64) -> [Double] {
        guard count > 0 else { return [] }
        guard count >= 3 else { return Array([lo, hi, median].prefix(count)) }
        var random = FixtureRandom(seed: seed)
        // u^k has median 0.5^k; pick k so that the median lands on `median`.
        let fraction = Swift.max(0.01, Swift.min(0.99, (median - lo) / (hi - lo)))
        let k = log(fraction) / log(0.5)
        var values = (0..<count).map { _ in ((lo + (hi - lo) * pow(random.unit(), k)) * 100).rounded() / 100 }
        values.sort()
        let mid = count / 2
        values[0] = lo
        values[count - 1] = hi
        for i in 1..<(count - 1) { values[i] = i < mid ? Swift.min(values[i], median) : Swift.max(values[i], median) }
        values[mid] = median
        if count.isMultiple(of: 2) { values[mid - 1] = median }   // even count: both middle values on the median
        // Seeded Fisher–Yates shuffle.
        for i in stride(from: count - 1, to: 0, by: -1) { values.swapAt(i, Int(random.next() % UInt64(i + 1))) }
        return values
    }

    // MARK: Results

    /// Output pixel size of `photo` in `preset` (never upscaled).
    public static func outputSize(of photo: SourcePhoto, preset: DeliveryPreset) -> (width: Int, height: Int) {
        guard let edge = preset.size.longEdge, edge < max(photo.pixelWidth, photo.pixelHeight) else {
            return (photo.pixelWidth, photo.pixelHeight)
        }
        let scale = Double(edge) / Double(max(photo.pixelWidth, photo.pixelHeight))
        return (Int((Double(photo.pixelWidth) * scale).rounded()), Int((Double(photo.pixelHeight) * scale).rounded()))
    }

    /// Typical output/source byte ratio for a preset (DATENLAGE §8 for the built-ins; a rough model otherwise).
    public static func typicalFraction(for preset: DeliveryPreset, sourcePixels: Int = 61_000_000) -> Double {
        if preset.format == .jxlLossless { return 0.78 }
        let qualityFraction: Double = switch preset.quality {
        case .highest: 0.30
        case .high: 0.19
        case .balanced: 0.123
        case .web: 0.085
        case .lossless: 0.78
        }
        let formatFactor = preset.format == .webp ? 0.62 : 1.0
        guard let edge = preset.size.longEdge else { return qualityFraction * formatFactor }
        // Resized: area ratio of a 3:2 frame, with small images costing relatively more bits per pixel.
        let outPixels = Double(edge) * Double(edge) * 2 / 3
        let area = min(1, outPixels / Double(sourcePixels))
        return min(1, qualityFraction * formatFactor * area * 1.6)
    }

    /// Fixed floor or, for Balanced, a target derived from the score (always ≤ score).
    static func target(for preset: DeliveryPreset, score: Double) -> Double? {
        if let floor = preset.quality.floor { return floor }
        guard preset.quality == .balanced else { return nil }
        return ((74 + (score - 74) * 0.7) * 10).rounded(.down) / 10
    }

    static func encoder(for preset: DeliveryPreset) -> String {
        switch preset.format { case .jpeg: "jpegli"; case .webp: "libwebp"; case .jxlLossless: "libjxl" }
    }

    /// One delivered (`.done`) result per photo whose `outBytes` sum to exactly `outputTotal`.
    /// `scores` (lossy presets only) are used in photo order.
    public static func results(photos: [SourcePhoto], preset: DeliveryPreset, wedding: String,
                               outputTotal: Int64, scores: [Double]?, seed: UInt64) -> [PhotoResult] {
        var random = FixtureRandom(seed: seed)
        let weights = photos.map { Double($0.byteCount) * random.uniform(0.75...1.25) }
        let outBytes = distribute(outputTotal, weights: weights)
        return photos.enumerated().map { i, photo in
            let score = preset.isLossy ? scores?[i] : nil
            let size = outputSize(of: photo, preset: preset)
            let isJPEG = preset.format == .jpeg
            return PhotoResult(
                photo: photo.id, delivery: preset.id, status: .done,
                score: score, target: score.flatMap { target(for: preset, score: $0) },
                inBytes: photo.byteCount, outBytes: outBytes[i],
                outRelativePath: relativePath(preset: preset, wedding: wedding, index: i, count: photos.count),
                outPixelWidth: size.width, outPixelHeight: size.height, encoder: encoder(for: preset),
                chroma: isJPEG ? (preset.isFullSize && random.unit() < 0.013 ? .s444 : .s420) : nil,
                byteExact: preset.format == .jxlLossless ? true : nil,
                probes: preset.isLossy ? (preset.isFullSize ? random.int(1...3) : random.int(1...2)) : 0,
                seconds: ((preset.isFullSize ? random.uniform(0.32...0.62) : random.uniform(0.05...0.14)) * 1000).rounded() / 1000)
        }
    }

    /// "Couple/Finn-und-Lissy-0001.jpg"
    public static func relativePath(preset: DeliveryPreset, wedding: String, index: Int, count: Int) -> String {
        preset.folderName + "/" + HMBFormat.fileName(pattern: NamingScheme.default.pattern, wedding: wedding,
                                                      number: index + 1, count: count, ext: preset.format.fileExtension)
    }

    /// A single deterministic result for any photo and preset (used by `FixtureEngine` while it replays a job).
    public static func result(for photo: SourcePhoto, preset: DeliveryPreset, wedding: String, count: Int) -> PhotoResult {
        var random = FixtureRandom(seed: FixtureRandom.seed(wedding, preset.id.rawValue, String(photo.id.index)))
        let fraction = typicalFraction(for: preset, sourcePixels: photo.pixelWidth * photo.pixelHeight) * random.uniform(0.7...1.3)
        let size = outputSize(of: photo, preset: preset)
        let score: Double? = switch preset.quality {
        case .lossless: nil
        case .balanced: ((74 + 2.2 * pow(random.unit(), 2.14)) * 100).rounded() / 100
        default: (((preset.quality.floor ?? 70) + 4 * pow(random.unit(), 2)) * 100).rounded() / 100
        }
        return PhotoResult(
            photo: photo.id, delivery: preset.id, status: .done, score: score,
            target: score.flatMap { target(for: preset, score: $0) },
            inBytes: photo.byteCount, outBytes: max(1, Int64(Double(photo.byteCount) * min(1, fraction))),
            outRelativePath: relativePath(preset: preset, wedding: wedding, index: photo.id.index, count: count),
            outPixelWidth: size.width, outPixelHeight: size.height, encoder: encoder(for: preset),
            chroma: preset.format == .jpeg ? .s420 : nil, byteExact: preset.format == .jxlLossless ? true : nil,
            probes: preset.isLossy ? random.int(1...3) : 0, seconds: (random.uniform(0.3...0.6) * 1000).rounded() / 1000)
    }
}
