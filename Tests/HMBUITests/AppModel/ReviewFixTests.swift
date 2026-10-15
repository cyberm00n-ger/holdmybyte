// Regression tests for the WP3 review fixes: stale preflight on Return, Create More as a fresh job, leftover journals
// of finished weddings, quit waiting for pending saves.
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Testing

@MainActor @Suite struct ReviewFixTests {
    /// Typing a name and pressing Return before the debounced preflight ran must not commit the old folder name.
    @Test func renameThenReturnUsesTheNewFolderName() async throws {
        let h = Harness()
        h.model.handleDrop([TestData.folder])
        try await waitUntil("ready") { if case .ready? = h.model.state.draft?.scan { true } else { false } }
        try await waitUntil("estimates") { h.model.draftEstimatedBytes != nil }
        try await waitUntil("preflight") { h.model.state.draft?.preflight != nil }
        let id = try #require(h.model.state.draft?.wedding)
        #expect(h.model.draftOutputFolder?.lastPathComponent == "Finn und Lissy – Deliveries")
        h.model.renameDraft("Anna und Ben")
        h.model.startDraft()                                             // within the 250 ms debounce
        try await waitUntil("committed") { h.model.record(id) != nil && h.model.state.draft == nil }
        #expect(h.model.record(id)?.outputFolder.lastPathComponent == "Anna und Ben – Deliveries")
        try await waitUntil("run") { !h.engine.runs.isEmpty }
        #expect(h.engine.runs.first?.request.outputFolder.lastPathComponent == "Anna und Ben – Deliveries")
    }

    /// Create More Deliveries is a new job (the original journal was discarded when it finished): never `resume: true`.
    @Test func createMoreRunsAsANewJob() async throws {
        let original = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let h = Harness(records: [original])
        await h.model.bootstrap()
        h.model.createMoreDeliveries(original.id)
        h.model.toggleDelivery(.archive)
        try await waitUntil("estimate") { h.model.draftEstimatedBytes != nil }
        h.model.startDraft()
        try await waitUntil("finished") { h.phase(original.id) == .finished && h.model.state.draft == nil }
        let run = try #require(h.engine.runs.first)
        #expect(run.resume == false)
        #expect(run.request.appendToExistingFolder)
    }

    /// A queued Create More found at launch (no journal) also starts as a new job.
    @Test func queuedCreateMoreAtLaunchRunsAsANewJob() async throws {
        var record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let archive = try #require(DeliveryPreset.builtIns.first { $0.id == .archive })
        record.deliveries.append(archive)
        record.phase = .queued(position: 0)
        let h = Harness(records: [record])
        await h.model.bootstrap()
        try await waitUntil("finished") { h.phase(record.id) == .finished }
        let run = try #require(h.engine.runs.first)
        #expect(run.resume == false)
        #expect(run.request.deliveries.map(\.id) == [.archive])
    }

    /// A finished wedding whose journal was not yet discarded when the app quit stays finished.
    @Test func leftoverJournalOfAFinishedWeddingIsDiscarded() async throws {
        let record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let request = JobRequest(wedding: record.id, name: record.name, photos: record.photos, sourceRoots: record.sourceRoots,
                                 deliveries: record.deliveries, outputFolder: record.outputFolder, naming: record.naming,
                                 processorUse: .automatic)
        let h = Harness(TestData.configuration(unfinished: [UnfinishedJob(request: request, results: [])]), records: [record])
        await h.model.bootstrap()
        #expect(h.phase(record.id) == .finished)
        #expect(h.model.record(record.id)?.results == record.results)
        #expect(h.engine.runs.isEmpty)
        #expect(h.model.state.queue.isEmpty)
        for _ in 0..<50 where await !h.engine.unfinishedJobs().isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await h.engine.unfinishedJobs().isEmpty)
    }

    /// Quitting while idle waits until a pending save (here a rename) has reached the history store.
    @Test func idleQuitWaitsForPendingSaves() async throws {
        let record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let h = Harness(records: [record])
        h.model.renameWedding(record.id, to: "Lissy & Finn")
        #expect(!h.model.requestQuit())
        try await waitUntil("reply") { h.log.terminateReplies == [true] }
        let saved = try #require(try await h.history.loadAll().first { $0.id == record.id })
        #expect(saved.name == "Lissy & Finn")
        #expect(h.model.requestQuit())                                    // nothing pending any more
    }

    /// A drag summary that arrives after the drag left the window must not re-target the drop zone.
    @Test func lateDragSummaryDoesNotRetarget() {
        let h = Harness()
        h.model.setDropTargeted(true, summary: .items(count: 1))
        #expect(h.model.isDropTargeted)
        h.model.setDropTargeted(false, summary: nil)
        #expect(!h.model.isDropTargeted)
        #expect(h.model.state.dropZone == .idle)
    }
}

@MainActor @Suite struct ReviewFixRetryTests {
    /// Try Again writes into the delivery folder, so it does nothing while that folder is missing (S12).
    @Test func retryIsBlockedWhileTheFolderIsMissing() async throws {
        var record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let first = try #require(record.results.firstIndex { $0.delivery == .couple })
        record.results[first] = PhotoResult(photo: record.results[first].photo, delivery: .couple, status: .failed(.encodeFailed),
                                            inBytes: record.results[first].inBytes)
        let h = Harness(records: [record])
        h.log.existing = []
        await h.model.bootstrap()
        #expect(h.model.missingFolders.contains(record.id))
        h.model.retry(record.id, photos: nil)
        #expect(h.phase(record.id) == .finished)
        #expect(h.engine.runs.isEmpty)
    }
}
