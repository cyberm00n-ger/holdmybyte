import Foundation
import HMBModel
import Synchronization

/// History kept in memory, in insertion order (a re-saved record keeps its position).
public actor InMemoryHistory: HistoryStoring {
    public private(set) var records: [WeddingRecord]
    /// Number of `save` calls (for tests of the persistence cadence).
    public private(set) var saveCount = 0

    public init(_ records: [WeddingRecord] = []) { self.records = records }

    public func loadAll() async throws -> [WeddingRecord] { records }
    public func save(_ record: WeddingRecord) async throws {
        saveCount += 1
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record } else { records.append(record) }
    }
    public func remove(_ id: WeddingID) async throws { records.removeAll { $0.id == id } }
    public func removeAll() async throws { records.removeAll() }
}

public final class InMemoryPresets: PresetStoring {
    private let state: Mutex<(presets: [DeliveryPreset], defaultOn: [DeliveryID])>

    public init(presets: [DeliveryPreset] = DeliveryPreset.builtIns, defaultOn: [DeliveryID] = DeliveryPreset.defaultOnIDs) {
        state = Mutex((presets, defaultOn))
    }

    public func load() -> (presets: [DeliveryPreset], defaultOn: [DeliveryID]) { state.withLock { $0 } }
    public func save(presets: [DeliveryPreset], defaultOn: [DeliveryID]) { state.withLock { $0 = (presets, defaultOn) } }
}

public final class InMemorySettings: SettingsStoring {
    private let state: Mutex<AppSettings>

    public init(_ settings: AppSettings = AppSettings()) { state = Mutex(settings) }

    public func load() -> AppSettings { state.withLock { $0 } }
    public func save(_ settings: AppSettings) { state.withLock { $0 = settings } }
}
