import Foundation
import HMBModel

/// Delivery presets and the default-on set in UserDefaults (Docs/SPEC.md §5.4), as JSON under versioned keys.
///
/// - Order is kept exactly as saved (it defines ⌘1…⌘9).
/// - Built-ins can be edited but not deleted; a built-in missing from the stored list (e.g. one added by a later
///   version) is appended, so every built-in is always present.
/// - `defaultOn` keeps only ids that exist, in the saved order, without duplicates.
/// - Unreadable data falls back to the shipped defaults; the bad bytes are kept under `<key>.corrupt`.
public final class UserDefaultsPresetStore: PresetStoring, @unchecked Sendable {
    // @unchecked: UserDefaults is documented thread-safe; `defaults` and the keys are immutable.
    public let defaults: UserDefaults
    public let presetsKey: String
    public let defaultOnKey: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "holdmybyte.") {
        self.defaults = defaults
        presetsKey = keyPrefix + "presets.v1"
        defaultOnKey = keyPrefix + "defaultOn.v1"
    }

    public func load() -> (presets: [DeliveryPreset], defaultOn: [DeliveryID]) {
        guard let data = defaults.data(forKey: presetsKey) else {
            return (DeliveryPreset.builtIns, DeliveryPreset.defaultOnIDs)
        }
        guard var presets = try? JSONDecoder().decode([DeliveryPreset].self, from: data) else {
            defaults.set(data, forKey: presetsKey + ".corrupt")
            storeLog.error("Stored delivery presets are unreadable; using the defaults.")
            return (DeliveryPreset.builtIns, DeliveryPreset.defaultOnIDs)
        }
        var seen = Set<DeliveryID>()
        presets = presets.filter { seen.insert($0.id).inserted }
        for builtIn in DeliveryPreset.builtIns where !seen.contains(builtIn.id) { presets.append(builtIn) }

        let storedOn: [DeliveryID]
        if let onData = defaults.data(forKey: defaultOnKey), let ids = try? JSONDecoder().decode([DeliveryID].self, from: onData) {
            storedOn = ids
        } else {
            storedOn = DeliveryPreset.defaultOnIDs
        }
        return (presets, Self.normalised(storedOn, presets: presets))
    }

    public func save(presets: [DeliveryPreset], defaultOn: [DeliveryID]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(presets),
              let onData = try? encoder.encode(Self.normalised(defaultOn, presets: presets)) else { return }
        defaults.set(data, forKey: presetsKey)
        defaults.set(onData, forKey: defaultOnKey)
    }

    /// Existing ids only, no duplicates, saved order.
    static func normalised(_ ids: [DeliveryID], presets: [DeliveryPreset]) -> [DeliveryID] {
        let known = Set(presets.map(\.id))
        var seen = Set<DeliveryID>()
        return ids.filter { known.contains($0) && seen.insert($0).inserted }
    }
}

/// `AppSettings` in UserDefaults as JSON (Docs/SPEC.md §5.4). Unreadable data falls back to `AppSettings()`;
/// the bad bytes are kept under `<key>.corrupt`.
public final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    // @unchecked: UserDefaults is documented thread-safe; `defaults` and the key are immutable.
    public let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "holdmybyte.") {
        self.defaults = defaults
        key = keyPrefix + "settings.v1"
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            defaults.set(data, forKey: key + ".corrupt")
            storeLog.error("Stored settings are unreadable; using the defaults.")
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
