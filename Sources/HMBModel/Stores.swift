import Foundation

public protocol HistoryStoring: Sendable {
    func loadAll() async throws -> [WeddingRecord]
    func save(_ record: WeddingRecord) async throws
    func remove(_ id: WeddingID) async throws
    func removeAll() async throws
}
public protocol PresetStoring: Sendable {
    func load() -> (presets: [DeliveryPreset], defaultOn: [DeliveryID])
    func save(presets: [DeliveryPreset], defaultOn: [DeliveryID])
}
public protocol SettingsStoring: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}
public protocol ThumbnailProviding: Sendable {
    /// Embedded thumbnail first, max `maxPixelSize`, orientation applied. Disk-cached by path+size+mtime.
    func thumbnail(for photo: SourcePhoto, maxPixelSize: Int) async -> SendableImage?
}
