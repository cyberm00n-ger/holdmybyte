// Interim stores until WP4's HMBStore lands (see LiveWiring.swift). They follow §5.4's layout so data written now is
// readable later: one `record.json` per wedding in `<Application Support>/holdmybyte/Weddings/<id>/` (atomic writes),
// presets and settings as JSON in UserDefaults, thumbnails via ImageIO (memory only, no disk cache).
import Foundation
import HMBModel
import ImageIO
import Synchronization

actor InterimHistoryStore: HistoryStoring {
    let directory: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL) { self.directory = directory }

    func loadAll() async throws -> [WeddingRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let file = folder.appending(path: "record.json", directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: file) else { return nil }
            do {
                return try decoder.decode(WeddingRecord.self, from: data)
            } catch {
                // A corrupt record is quarantined, never fatal.
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("corrupt"))
                return nil
            }
        }
    }

    func save(_ record: WeddingRecord) async throws {
        let folder = directory.appending(path: record.id.description, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: folder.appending(path: "record.json", directoryHint: .notDirectory), options: .atomic)
    }

    func remove(_ id: WeddingID) async throws {
        let folder = directory.appending(path: id.description, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    func removeAll() async throws {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders { try FileManager.default.removeItem(at: folder) }
    }
}

final class InterimPresetStore: PresetStoring {
    private struct Stored: Codable { var presets: [DeliveryPreset]; var defaultOn: [DeliveryID] }
    private static let key = "presets.v1"

    func load() -> (presets: [DeliveryPreset], defaultOn: [DeliveryID]) {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), !stored.presets.isEmpty else {
            return (DeliveryPreset.builtIns, DeliveryPreset.defaultOnIDs)
        }
        return (stored.presets, stored.defaultOn)
    }

    func save(presets: [DeliveryPreset], defaultOn: [DeliveryID]) {
        if let data = try? JSONEncoder().encode(Stored(presets: presets, defaultOn: defaultOn)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

final class InterimSettingsStore: SettingsStoring {
    private static let key = "settings.v1"

    func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Embedded thumbnail first (ImageIO), orientation applied, ≤ `maxPixelSize`. Decodes off the main actor.
final class InterimThumbnails: ThumbnailProviding {
    func thumbnail(for photo: SourcePhoto, maxPixelSize: Int) async -> SendableImage? {
        let url = photo.url
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(SendableImage.init)
        }.value
    }
}
