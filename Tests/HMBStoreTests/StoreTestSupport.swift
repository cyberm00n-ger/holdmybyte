import Foundation
import HMBFixtures
import HMBModel

/// A unique temporary directory under the system temp folder, removed by `cleanUp()`.
struct TemporaryDirectory {
    let url: URL

    init(_ label: String = "store") throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "hmb-wp4-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

/// A UserDefaults suite of its own, removed by `cleanUp()`.
struct TemporaryDefaults {
    let name = "hmb-wp4-tests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func cleanUp() { UserDefaults().removePersistentDomain(forName: name) }
}

enum StoreFixtures {
    /// A finished wedding with `count` photos and all four built-in deliveries (4 × `count` results).
    static func record(photos count: Int, number: Int = 900) -> WeddingRecord {
        let name = "Large Wedding \(number)"
        let root = FixtureFactory.weddingsFolder.appending(path: name, directoryHint: .isDirectory)
        let photos = FixtureFactory.photos(count: count, totalBytes: Int64(count) * 21_000_000, root: root,
                                           firstCapture: FixtureFactory.date(2026, 6, 6, 11), hours: 12, camera: "ILCE-1",
                                           pixelSize: (8640, 5760), seed: UInt64(number))
        let presets = DeliveryPreset.builtIns
        let results = presets.enumerated().flatMap { i, preset in
            FixtureFactory.results(photos: photos, preset: preset, wedding: name,
                                   outputTotal: Int64(Double(count) * 21_000_000 * [0.12, 0.015, 0.014, 0.78][i]),
                                   scores: preset.isLossy ? FixtureFactory.scores(count: count, min: 74, max: 90, median: 80, seed: UInt64(i)) : nil,
                                   seed: UInt64(number + i))
        }
        return WeddingRecord(
            id: FixtureFactory.weddingID(number), name: name, createdAt: FixtureFactory.date(2026, 6, 8, 10),
            weddingDate: photos.first?.captureDate, camera: "ILCE-1", sourceRoots: [root], sourceBookmarks: [Data([1, 2, 3])],
            photos: photos, deliveries: presets,
            deliveryCompletedAt: Dictionary(uniqueKeysWithValues: presets.map { ($0.id.rawValue, FixtureFactory.date(2026, 6, 8, 12)) }),
            outputFolder: root.appending(path: "\(name) – Deliveries", directoryHint: .isDirectory), outputBookmark: nil,
            naming: .default, phase: .finished, results: results, startedAt: FixtureFactory.date(2026, 6, 8, 10, 1),
            finishedAt: FixtureFactory.date(2026, 6, 8, 12), activeSeconds: 7_000, viewed: true)
    }
}
