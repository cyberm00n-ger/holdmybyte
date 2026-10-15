// WP0: the in-memory stores from HMBFixtures honour the store protocols (the contract WP4's stores also meet).
import Foundation
import HMBFixtures
import HMBModel
import Testing

@Suite struct InMemoryStoreTests {
    @Test func historyKeepsInsertionOrderAndReplacesById() async throws {
        let store = InMemoryHistory()
        var first = Fixtures.annaUndBen
        try await store.save(first)
        try await store.save(Fixtures.finnUndLissy)
        first.name = "Anna & Ben"
        try await store.save(first)
        let all = try await store.loadAll()
        #expect(all.map(\.id) == [Fixtures.annaUndBenID, Fixtures.finnUndLissyID])
        #expect(all.first?.name == "Anna & Ben")
        try await store.remove(Fixtures.annaUndBenID)
        #expect(try await store.loadAll().count == 1)
        try await store.removeAll()
        #expect(try await store.loadAll().isEmpty)
    }

    @Test func presetsAndSettingsRoundTrip() {
        let presets = InMemoryPresets()
        #expect(presets.load().presets == DeliveryPreset.builtIns)
        #expect(presets.load().defaultOn == DeliveryPreset.defaultOnIDs)
        let reordered = Array(DeliveryPreset.builtIns.reversed())
        presets.save(presets: reordered, defaultOn: [.archive])
        #expect(presets.load().presets == reordered)
        #expect(presets.load().defaultOn == [.archive])

        let settings = InMemorySettings()
        var changed = settings.load()
        changed.playSound = true
        changed.saveLocation = .folder(URL(fileURLWithPath: "/tmp/out"))
        settings.save(changed)
        #expect(settings.load() == changed)
    }
}
