import Foundation
import HMBModel

extension Fixtures {
    /// Lifetime saving of `history`: Σ `savedBytesFullSize` = exactly 1.24 TB.
    public static let historySavedBytes: Int64 = 1_240_000_000_000

    /// 38 finished weddings over 14 months (September 2025 – October 2026), newest wedding date first,
    /// including `finnUndLissy`. Σ savedBytesFullSize = `historySavedBytes` ("1.24 TB saved across 38 weddings").
    public static let history: [WeddingRecord] = {
        let others = historyNames.count
        var random = FixtureRandom(seed: FixtureRandom.seed("history"))
        let remaining = historySavedBytes - finnUndLissy.savedBytesFullSize
        let saved = FixtureFactory.distribute(remaining, weights: (0..<others).map { _ in random.uniform(0.6...1.4) })
        var records = [finnUndLissy]
        for (i, name) in historyNames.enumerated() {
            records.append(historyRecord(index: i, name: name, date: historyDates[i], savedBytes: saved[i]))
        }
        return records.sorted { ($0.weddingDate ?? .distantPast) > ($1.weddingDate ?? .distantPast) }
    }()

    static let historyNames = [
        "Marie und Jonas", "Lea und Paul", "Sophie und Felix", "Hannah und Lukas", "Emma und Leon", "Mia und Elias",
        "Lena und Noah", "Laura und Tim", "Julia und Max", "Clara und Jakob", "Lisa und Niklas", "Sarah und David",
        "Johanna und Moritz", "Katharina und Simon", "Charlotte und Henri", "Amelie und Theo", "Nele und Jan",
        "Paula und Erik", "Greta und Anton", "Frieda und Karl", "Ida und Oskar", "Luisa und Fabian", "Carla und Vincent",
        "Marlene und Konstantin", "Theresa und Florian", "Helena und Matthias", "Antonia und Philipp",
        "Valerie und Tobias", "Rosa und Samuel", "Maja und Linus", "Ella und Johannes", "Victoria und Dominik",
        "Isabel und Raphael", "Annika und Stefan", "Svenja und Markus", "Pia und Daniel", "Merle und Jonathan",
    ]

    /// 37 wedding days (plus Finn und Lissy on July 12, 2026): 14 months, busy in the summer season.
    static let historyDates: [Date] = {
        let days: [(Int, Int, Int)] = [
            (2025, 9, 6), (2025, 9, 13), (2025, 9, 20), (2025, 9, 27), (2025, 10, 4), (2025, 10, 18), (2025, 11, 15),
            (2025, 12, 13), (2026, 1, 24), (2026, 2, 14), (2026, 3, 21), (2026, 4, 18), (2026, 4, 25), (2026, 5, 2),
            (2026, 5, 9), (2026, 5, 16), (2026, 5, 23), (2026, 5, 30), (2026, 6, 6), (2026, 6, 13), (2026, 6, 20),
            (2026, 6, 27), (2026, 7, 4), (2026, 7, 18), (2026, 7, 25), (2026, 8, 1), (2026, 8, 8), (2026, 8, 15),
            (2026, 8, 29), (2026, 9, 5), (2026, 9, 12), (2026, 9, 19), (2026, 9, 26), (2026, 10, 2), (2026, 10, 3),
            (2026, 10, 9), (2026, 10, 10),
        ]
        return days.map { FixtureFactory.date($0.0, $0.1, $0.2, 11, 30) }
    }()

    static let historyCameras = ["ILCE-7RM5", "ILCE-1", "Z 8", "EOS R5", "ILCE-7M4", "X-H2"]

    /// A finished wedding whose full-size deliveries save exactly `savedBytes`.
    static func historyRecord(index: Int, name: String, date: Date, savedBytes: Int64) -> WeddingRecord {
        var random = FixtureRandom(seed: FixtureRandom.seed("history", name))
        let presets = DeliveryPreset.builtIns
        let hasArchive = random.unit() < 0.4
        let hasWebsite = random.unit() < 0.65
        let hasSocial = random.unit() < 0.3
        let coupleFraction = random.uniform(0.105...0.14)
        let archiveFraction = random.uniform(0.76...0.80)
        // saved = src·(1 − c) + [archive] src·(1 − a)
        let sourceBytes = Int64((Double(savedBytes) / ((1 - coupleFraction) + (hasArchive ? 1 - archiveFraction : 0))).rounded())
        let averagePhoto = random.uniform(21_000_000...31_000_000)
        let count = max(150, Int((Double(sourceBytes) / averagePhoto).rounded()))
        let camera = historyCameras[index % historyCameras.count]
        let folder = FixtureFactory.weddingsFolder.appending(path: name, directoryHint: .isDirectory)
        let root = folder.appending(path: index.isMultiple(of: 3) ? "Export" : "fertig", directoryHint: .isDirectory)
        let photos = FixtureFactory.photos(count: count, totalBytes: sourceBytes, root: root, firstCapture: date,
                                           hours: random.uniform(8...13), camera: camera,
                                           pixelSize: camera == "X-H2" ? (7728, 5152) : (8640, 5760),
                                           seed: FixtureRandom.seed("history", name, "photos"))
        var coupleOut = Int64((Double(sourceBytes) * coupleFraction).rounded())
        var archiveOut: Int64 = 0
        if hasArchive { archiveOut = 2 * sourceBytes - coupleOut - savedBytes } else { coupleOut = sourceBytes - savedBytes }

        var deliveries = [presets[0]]
        var perDelivery = [FixtureFactory.results(
            photos: photos, preset: presets[0], wedding: name, outputTotal: coupleOut,
            scores: FixtureFactory.scores(count: count, min: 74.0, max: random.uniform(75.8...77.4).rounded(toPlaces: 1),
                                          median: random.uniform(74.4...75.0).rounded(toPlaces: 1), seed: random.next()),
            seed: random.next())]
        if hasWebsite {
            deliveries.append(presets[1])
            perDelivery.append(FixtureFactory.results(
                photos: photos, preset: presets[1], wedding: name,
                outputTotal: Int64(Double(sourceBytes) * random.uniform(0.013...0.016)),
                scores: FixtureFactory.scores(count: count, min: 70.0, max: 79.0, median: 72.0, seed: random.next()),
                seed: random.next()))
        }
        if hasSocial {
            deliveries.append(presets[2])
            perDelivery.append(FixtureFactory.results(
                photos: photos, preset: presets[2], wedding: name,
                outputTotal: Int64(Double(sourceBytes) * random.uniform(0.012...0.015)),
                scores: FixtureFactory.scores(count: count, min: 85.0, max: 89.0, median: 86.0, seed: random.next()),
                seed: random.next()))
        }
        if hasArchive {
            deliveries.append(presets[3])
            perDelivery.append(FixtureFactory.results(photos: photos, preset: presets[3], wedding: name,
                                                      outputTotal: archiveOut, scores: nil, seed: random.next()))
        }
        let started = date.addingTimeInterval(Double(random.int(2...4)) * 86_400 + 9 * 3600)
        let active = (Double(count) * random.uniform(0.42...0.55)).rounded()
        let finished = started.addingTimeInterval(active)
        return WeddingRecord(
            id: FixtureFactory.weddingID(100 + index), name: name, createdAt: started.addingTimeInterval(-90),
            weddingDate: photos.first?.captureDate, camera: camera, sourceRoots: [root], sourceBookmarks: [],
            photos: photos, deliveries: deliveries,
            deliveryCompletedAt: Dictionary(uniqueKeysWithValues: deliveries.map { ($0.id.rawValue, finished) }),
            outputFolder: folder.appending(path: "\(name) – Deliveries", directoryHint: .isDirectory),
            outputBookmark: nil, naming: .default, phase: .finished, results: interleave(perDelivery),
            startedAt: started, finishedAt: finished, activeSeconds: active, viewed: true)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
