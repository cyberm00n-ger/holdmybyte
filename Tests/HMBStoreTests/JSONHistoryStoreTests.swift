// WP4 acceptance 3 (Docs/SPEC.md §5.4): round-trip 2000-photo records, load ≤ 100 ms, corrupt files quarantined.
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBStore
import Testing

@Suite struct JSONHistoryStoreTests {
    @Test func roundTripsEveryFixtureRecordExactly() async throws {
        let temp = try TemporaryDirectory("history")
        defer { temp.cleanUp() }
        let store = JSONHistoryStore(directory: temp.url)
        let records = [Fixtures.finnUndLissy, Fixtures.annaUndBen, Fixtures.withIssues(Fixtures.finnUndLissy),
                       Fixtures.inProgress(Fixtures.annaUndBen, done: 40, phase: .paused(.diskFull(volume: "Macintosh HD", neededBytes: 600_000_000))).record]
        // The issues variant shares Finn und Lissy's id: the later save replaces the earlier one.
        for record in records { try await store.save(record) }
        let loaded = try await store.loadAll()
        #expect(loaded.count == 2)
        #expect(loaded.first { $0.id == Fixtures.finnUndLissyID } == records[2])
        #expect(loaded.first { $0.id == Fixtures.annaUndBenID } == records[3])
        let file = temp.url.appending(path: Fixtures.finnUndLissyID.uuid.uuidString).appending(path: "record.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func roundTripsTheWholeHistoryNewestFirst() async throws {
        let temp = try TemporaryDirectory("history")
        defer { temp.cleanUp() }
        let store = JSONHistoryStore(directory: temp.url)
        for record in Fixtures.history.shuffled() { try await store.save(record) }
        let loaded = try await store.loadAll()
        #expect(loaded == Fixtures.history)
        #expect(loaded.reduce(Int64(0)) { $0 + $1.savedBytesFullSize } == Fixtures.historySavedBytes)
    }

    @Test func twoThousandPhotoRecordRoundTripsAndLoadsWithinBudget() async throws {
        let temp = try TemporaryDirectory("history")
        defer { temp.cleanUp() }
        let store = JSONHistoryStore(directory: temp.url)
        let record = StoreFixtures.record(photos: 2000)
        #expect(record.results.count == 8000)
        try await store.save(record)
        // Warm-up (first-use costs of Foundation's decoder), then the median of five loads.
        _ = try await store.loadAll()
        var times: [Duration] = []
        var loaded: [WeddingRecord] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            loaded = try await store.loadAll()
            times.append(ContinuousClock.now - start)
        }
        #expect(loaded == [record])
        let median = times.sorted()[2]
        let bytes = try FileManager.default.attributesOfItem(atPath: store.folder(for: record.id).appending(path: "record.json").path)[.size] as? Int ?? 0
        print("[WP4] 2000-photo record: \(bytes) bytes, loadAll median \(median) (\(loadAverage()))")
        #expect(median <= .milliseconds(100), "load took \(median)")
    }

    @Test func corruptRecordIsQuarantinedNotFatal() async throws {
        let temp = try TemporaryDirectory("history")
        defer { temp.cleanUp() }
        let store = JSONHistoryStore(directory: temp.url)
        try await store.save(Fixtures.finnUndLissy)
        try await store.save(Fixtures.annaUndBen)
        let bad = store.folder(for: Fixtures.annaUndBenID).appending(path: "record.json")
        try Data("{\"id\": \"truncated".utf8).write(to: bad)
        // A second corrupt record whose quarantine name is already taken.
        let other = FixtureFactory.weddingID(77)
        try FileManager.default.createDirectory(at: store.folder(for: other), withIntermediateDirectories: true)
        try Data([0xFF, 0x00]).write(to: store.folder(for: other).appending(path: "record.json"))
        try Data("older".utf8).write(to: store.folder(for: other).appending(path: "record.json.corrupt"))

        let loaded = try await store.loadAll()
        #expect(loaded.map(\.id) == [Fixtures.finnUndLissyID])
        let quarantined = await store.lastQuarantined.map(\.lastPathComponent).sorted()
        #expect(quarantined == ["record.json.corrupt", "record.json.corrupt 2"])
        #expect(!FileManager.default.fileExists(atPath: bad.path))
        #expect(FileManager.default.fileExists(atPath: bad.path + ".corrupt"))
        #expect(try Data(contentsOf: store.folder(for: other).appending(path: "record.json.corrupt")) == Data("older".utf8))
        // The next load is clean and the bad bytes are still there for diagnosis.
        #expect(try await store.loadAll().count == 1)
        #expect(await store.lastQuarantined.isEmpty)
    }

    @Test func removeAndRemoveAllTouchOnlyWeddingFolders() async throws {
        let temp = try TemporaryDirectory("history")
        defer { temp.cleanUp() }
        let store = JSONHistoryStore(directory: temp.url)
        try await store.save(Fixtures.finnUndLissy)
        try await store.save(Fixtures.annaUndBen)
        let foreign = temp.url.appending(path: "Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try await store.remove(Fixtures.annaUndBenID)
        try await store.remove(FixtureFactory.weddingID(4242))          // unknown id: no error
        #expect(try await store.loadAll().map(\.id) == [Fixtures.finnUndLissyID])
        try await store.removeAll()
        #expect(try await store.loadAll().isEmpty)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func missingDirectoryLoadsEmptyAndIsCreatedOnSave() async throws {
        let temp = try TemporaryDirectory("history")
        defer { temp.cleanUp() }
        let store = JSONHistoryStore(directory: temp.url.appending(path: "a/b/Weddings", directoryHint: .isDirectory))
        #expect(try await store.loadAll().isEmpty)
        try await store.save(Fixtures.annaUndBen)
        #expect(try await store.loadAll() == [Fixtures.annaUndBen])
    }

    @Test func defaultLocationIsApplicationSupport() {
        #expect(StoreLocations.weddings.path.hasSuffix("Library/Application Support/holdmybyte/Weddings"))
        #expect(StoreLocations.thumbnails.path.hasSuffix("Library/Caches/eu.sebastianhaas.holdmybyte/Thumbnails"))
    }
}

/// `uptime`-style load averages, printed next to every timing.
func loadAverage() -> String {
    var loads = [Double](repeating: 0, count: 3)
    guard getloadavg(&loads, 3) == 3 else { return "load n/a" }
    return String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
}
