// WP4 acceptance 3: presets keep their order and the defaultOn set; settings round-trip; bad data never crashes.
import Foundation
import HMBModel
@testable import HMBStore
import Testing

@Suite struct UserDefaultsPresetStoreTests {
    static let custom = DeliveryPreset(id: DeliveryID(rawValue: "custom-print"), name: "Album Print", symbol: "printer",
                                       format: .jpeg, size: .full, quality: .highest, colour: .keepProfile,
                                       metadata: .removeAll, folderName: "Print")

    @Test func emptyDefaultsGiveTheShippedPresets() {
        let suite = TemporaryDefaults()
        defer { suite.cleanUp() }
        let loaded = UserDefaultsPresetStore(defaults: suite.defaults).load()
        #expect(loaded.presets == DeliveryPreset.builtIns)
        #expect(loaded.defaultOn == [.couple, .website])
    }

    @Test func keepsOrderEditsAndDefaultOnSet() {
        let suite = TemporaryDefaults()
        defer { suite.cleanUp() }
        var website = DeliveryPreset.builtIns[1]
        website.size = .longEdge(2048)
        website.name = "Gallery"
        let presets = [DeliveryPreset.builtIns[3], Self.custom, website, DeliveryPreset.builtIns[0], DeliveryPreset.builtIns[2]]
        let defaultOn: [DeliveryID] = [Self.custom.id, .archive, .couple]
        UserDefaultsPresetStore(defaults: suite.defaults).save(presets: presets, defaultOn: defaultOn)
        // A fresh store instance on the same defaults (as after a relaunch).
        let loaded = UserDefaultsPresetStore(defaults: suite.defaults).load()
        #expect(loaded.presets == presets)
        #expect(loaded.defaultOn == defaultOn)
    }

    @Test func defaultOnDropsUnknownAndDuplicateIDs() {
        let suite = TemporaryDefaults()
        defer { suite.cleanUp() }
        let store = UserDefaultsPresetStore(defaults: suite.defaults)
        store.save(presets: DeliveryPreset.builtIns, defaultOn: [.website, DeliveryID(rawValue: "custom-gone"), .website, .social])
        #expect(store.load().defaultOn == [.website, .social])
    }

    @Test func missingBuiltInsAreAppendedAndDuplicatesDropped() throws {
        let suite = TemporaryDefaults()
        defer { suite.cleanUp() }
        let store = UserDefaultsPresetStore(defaults: suite.defaults)
        let stored = [Self.custom, DeliveryPreset.builtIns[2], Self.custom]
        suite.defaults.set(try JSONEncoder().encode(stored), forKey: store.presetsKey)
        let loaded = store.load()
        #expect(loaded.presets.map(\.id) == [Self.custom.id, .social, .couple, .website, .archive])
        #expect(loaded.defaultOn == [.couple, .website])
    }

    @Test func corruptDataFallsBackAndIsKept() {
        let suite = TemporaryDefaults()
        defer { suite.cleanUp() }
        let store = UserDefaultsPresetStore(defaults: suite.defaults)
        suite.defaults.set(Data("not json".utf8), forKey: store.presetsKey)
        let loaded = store.load()
        #expect(loaded.presets == DeliveryPreset.builtIns)
        #expect(suite.defaults.data(forKey: store.presetsKey + ".corrupt") == Data("not json".utf8))
    }
}

@Suite struct UserDefaultsSettingsStoreTests {
    @Test func roundTripsEveryField() {
        let suite = TemporaryDefaults()
        defer { suite.cleanUp() }
        var settings = AppSettings()
        settings.saveLocation = .folder(URL(fileURLWithPath: "/Volumes/Wedding SSD/Deliveries", isDirectory: true))
        settings.folderNamePattern = "{date} {wedding}"
        settings.naming = NamingScheme(renameByCaptureTime: false, pattern: "{wedding}_{number}")
        settings.notifyWhenFinished = false
        settings.playSound = true
        settings.menuBarWhileClosed = false
        settings.processorUse = .gentle
        settings.detailedLogs = true
        UserDefaultsSettingsStore(defaults: suite.defaults).save(settings)
        #expect(UserDefaultsSettingsStore(defaults: suite.defaults).load() == settings)
    }

    @Test func emptyOrCorruptGivesDefaults() {
        let suite = TemporaryDefaults()
        defer { suite.cleanUp() }
        let store = UserDefaultsSettingsStore(defaults: suite.defaults)
        #expect(store.load() == AppSettings())
        suite.defaults.set(Data([0x7B]), forKey: store.key)
        #expect(store.load() == AppSettings())
        #expect(suite.defaults.data(forKey: store.key + ".corrupt") == Data([0x7B]))
    }
}
