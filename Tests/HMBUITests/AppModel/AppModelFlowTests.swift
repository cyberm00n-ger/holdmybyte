// §5.3 acceptance 1: intent tests with FixtureEngine and in-memory stores.
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Testing

@MainActor @Suite struct AppModelFlowTests {
    // MARK: drop → scanning → ready → start → running → finished → record saved

    @Test func dropToFinishedSavesRecord() async throws {
        let h = Harness(TestData.configuration(scanDuration: .milliseconds(50)))
        h.model.handleDrop([TestData.folder])
        let draft = try #require(h.model.state.draft)
        #expect(draft.name == "Finn und Lissy")                        // "fertig" is generic: the parent's name
        #expect(draft.scan == .scanning(found: 0))
        #expect(draft.enabled[.couple] == true && draft.enabled[.website] == true && draft.enabled[.archive] == false)
        #expect(h.model.state.selection == .newWedding)

        try await waitUntil("ready") { if case .ready? = h.model.state.draft?.scan { true } else { false } }
        try await waitUntil("estimates") { h.model.draftEstimatedBytes != nil }
        try await waitUntil("preflight") { h.model.state.draft?.preflight != nil }
        #expect(h.model.draftOutputFolder?.lastPathComponent == "Finn und Lissy – Deliveries")
        #expect(h.model.draftCanStart)

        let id = draft.wedding
        h.model.startDraft()
        try await waitUntil("finished") { h.phase(id) == .finished }
        let record = try #require(h.model.record(id))
        #expect(record.results.count == 40 * 2)
        #expect(Set(record.deliveryCompletedAt.keys) == ["couple", "website"])
        #expect(record.startedAt != nil && record.finishedAt != nil)
        #expect(h.model.state.queue.isEmpty)
        #expect(h.model.state.live[id] == nil)
        #expect(h.model.state.sidebarVisible)                        // the sidebar animates in with the first job
        await h.model.flushSaves()
        let saved = try #require(try await h.history.loadAll().first { $0.id == id })
        #expect(saved.phase == .finished && saved.results.count == 80)
        #expect(await h.history.saveCount >= 3)                       // queued, running, finished at least
        let request = try #require(h.engine.runs.first)
        #expect(request.resume == false)
        #expect(request.request.deliveries.map(\.id) == [.couple, .website])
        #expect(request.request.outputFolder.lastPathComponent == "Finn und Lissy – Deliveries")
        // F1 step 6: Show in Finder reveals the first delivery folder.
        h.model.revealInFinder(id, delivery: nil)
        #expect(h.log.revealed.last?.first?.lastPathComponent == "Couple")
        #expect(h.log.events.contains { if case .finished(id, _, _) = $0 { true } else { false } })
    }

    @Test func startWhileScanningStartsWhenScanEnds() async throws {
        let h = Harness(TestData.configuration(scanDuration: .milliseconds(300)))
        h.model.handleDrop([TestData.folder])
        let id = try #require(h.model.state.draft?.wedding)
        h.model.startDraft()
        #expect(h.model.startPending)
        #expect(h.model.state.draft != nil)
        try await waitUntil("finished") { h.phase(id) == .finished }
        #expect(!h.model.startPending)
    }

    @Test func cancelSetupWritesNothing() async throws {
        let h = Harness()
        h.model.handleDrop([TestData.folder])
        try await waitUntil("ready") { if case .ready? = h.model.state.draft?.scan { true } else { false } }
        h.model.cancelSetup()
        #expect(h.model.state.draft == nil)
        #expect(h.model.state.dropZone == .idle)
        #expect(h.engine.runs.isEmpty)
        #expect(await h.history.saveCount == 0)
    }

    @Test func toggleDeliveryAndRememberDefaults() async throws {
        let h = Harness()
        h.model.handleDrop([TestData.folder])
        try await waitUntil("estimates") { h.model.draftEstimatedBytes != nil }
        h.model.toggleDelivery(atRow: 4)                               // ⌘4: Archive
        #expect(h.model.state.draft?.enabled[.archive] == true)
        try await waitUntil("archive estimate") {
            if case .ready? = h.model.state.draft?.estimates[.archive] { true } else { false }
        }
        h.model.toggleDelivery(.website)
        h.model.toggleDelivery(.couple)
        #expect(h.model.draftSelectedPresets.map(\.id) == [.archive])
        h.model.toggleDelivery(.archive)
        #expect(!h.model.draftCanStart)                                // "Choose at least one delivery."
        h.model.startDraft()
        #expect(h.model.state.draft != nil && h.engine.runs.isEmpty)
    }

    @Test func blockingNoticeDisablesStart() async throws {
        let h = Harness(TestData.configuration(preflightNotices: [.notEnoughSpace(volume: "Macintosh HD", needed: 1_900_000_000,
                                                                                    available: 800_000_000)]))
        h.model.handleDrop([TestData.folder])
        try await waitUntil("preflight") { h.model.state.draft?.preflight != nil }
        #expect(h.model.draftIsBlocked)
        #expect(!h.model.draftCanStart)
        h.model.startDraft()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.engine.runs.isEmpty)
    }

    @Test func warningsCanBeAcknowledgedAndArchiveOnly() async throws {
        let notice = ScanNotice.alreadyCompressed(count: 30, of: 40)
        let h = Harness(TestData.configuration(TestData.scan(notices: [notice, .holdMyByteOutput(count: 40)])))
        h.model.handleDrop([TestData.folder])
        try await waitUntil("ready") { if case .ready? = h.model.state.draft?.scan { true } else { false } }
        #expect(h.model.draftNotices.contains(notice))
        #expect(h.model.draftCanStart)                                 // warnings never block
        h.model.acknowledge(.holdMyByteOutput(count: 40))
        #expect(!h.model.draftNotices.contains(.holdMyByteOutput(count: 40)))
        h.model.useArchiveOnly(notice)
        #expect(h.model.draftSelectedPresets.map(\.id) == [.archive])
        #expect(!h.model.draftNotices.contains(notice))
    }

    @Test func renameDraftAndChooseFolder() async throws {
        let h = Harness()
        h.model.handleDrop([TestData.folder])
        try await waitUntil("preflight") { h.model.state.draft?.preflight != nil }
        h.model.renameDraft("Lissy & Finn")
        try await waitUntil("re-preflight") { h.model.state.draft?.preflight?.outputFolder.lastPathComponent == "Lissy & Finn – Deliveries" }
        h.log.chooseFolder = URL(fileURLWithPath: "/Volumes/Wedding SSD/Out", isDirectory: true)
        h.model.chooseOutputFolder()
        try await waitUntil("chosen folder") { h.model.draftOutputFolder?.path == "/Volumes/Wedding SSD/Out/Lissy & Finn – Deliveries" }
        // A late scan result must not overwrite the name the user typed.
        #expect(h.model.state.draft?.name == "Lissy & Finn")
    }

    // MARK: queue

    @Test func queueRunsFIFOOneAtATime() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.004))
        let a = try await h.dropAndStart()
        #expect(h.model.isRunning)
        h.model.handleDrop([TestData.folder])
        try await waitUntil("ready") { if case .ready? = h.model.state.draft?.scan { true } else { false } }
        try await waitUntil("estimates") { h.model.draftEstimatedBytes != nil }
        let b = try #require(h.model.state.draft?.wedding)
        h.model.startDraft()
        try await waitUntil("b committed") { h.model.record(b) != nil }
        #expect(h.model.state.queue == [a, b])
        #expect(h.phase(b) == .queued(position: 1))
        #expect(h.phase(a) == .running)
        try await waitUntil("a finished") { h.phase(a) == .finished }
        try await waitUntil("b finished") { h.phase(b) == .finished }
        #expect(h.engine.runs.map(\.request.wedding) == [a, b])
        let finishedA = try #require(h.model.record(a)?.finishedAt), startedB = try #require(h.model.record(b)?.startedAt)
        #expect(finishedA <= startedB)
    }

    @Test func removeFromQueueForgetsTheWedding() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.004))
        let a = try await h.dropAndStart()
        let b = try await h.dropAndStart()
        #expect(h.phase(b) == .queued(position: 1))
        h.model.removeFromQueue(b)
        #expect(h.model.record(b) == nil)
        #expect(h.model.state.queue == [a])
        try await waitUntil("a finished") { h.phase(a) == .finished }
        #expect(h.engine.runs.count == 1)
    }

    @Test func startNowInsteadPausesTheCurrentJob() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.004))
        let a = try await h.dropAndStart()
        let b = try await h.dropAndStart()
        h.model.startNow(b)
        try await waitUntil("b running") { h.phase(b) == .running }
        #expect(h.engine.pauses.contains(a))
        #expect(h.phase(a) == .paused(.user))
        #expect(h.model.state.queue.first == b)
        try await waitUntil("b finished") { h.phase(b) == .finished }
        try await waitUntil("a finished") { h.phase(a) == .finished }
        #expect(h.engine.runs.last?.request.wedding == a)
        #expect(h.engine.runs.last?.resume == true)
        #expect(h.model.record(a)?.results.count == 80)
    }

    // MARK: pause / resume / stop

    @Test func pauseResumeStop() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.004))
        let id = try await h.dropAndStart()
        try await waitUntil("progress") { (h.model.state.live[id]?.photosDone ?? 0) > 2 }
        h.model.pause(id)
        try await waitUntil("paused") { h.phase(id) == .paused(.user) }
        #expect(h.model.state.queue == [id])                          // a paused job holds the queue
        #expect(!h.model.isRunning)
        h.model.resume(id)
        try await waitUntil("running again") { h.phase(id) == .running }
        #expect(h.engine.runs.last?.resume == true)
        h.model.requestStop(id)
        #expect(h.model.state.alert == .stop(id))
        h.model.dismissAlert()                                         // Continue
        #expect(h.phase(id) == .running)
        h.model.requestStop(id)
        h.model.confirmAlert()                                         // Stop
        try await waitUntil("stopped") { h.phase(id) == .stopped }
        #expect(h.model.state.queue.isEmpty)
        let done = h.model.record(id)?.photosFinished ?? 0
        #expect(done > 0 && done < 40)
        h.model.resume(id)                                             // "The rest can be finished any time."
        try await waitUntil("finished") { h.phase(id) == .finished }
        #expect(h.model.record(id)?.results.filter { $0.status == .done }.count == 80)
    }

    @Test func driveDisconnectPausesUntilMounted() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.002,
                                               pausePoint: .init(afterPhotos: 5, reason: .sourceUnavailable(volume: "Wedding SSD"))))
        let id = try await h.dropAndStart()
        try await waitUntil("paused") { h.phase(id) == .paused(.sourceUnavailable(volume: "Wedding SSD")) }
        let record = try #require(h.model.record(id))
        #expect(!h.model.canResume(record))
        h.model.resume(id)
        #expect(h.phase(id) == .paused(.sourceUnavailable(volume: "Wedding SSD")))
        #expect(h.log.events.contains { if case .pausedByDrive(id, _) = $0 { true } else { false } })
        h.log.volumes.insert("Wedding SSD")
        h.log.volumeCallback?() ?? h.model.volumesChanged()
        #expect(h.model.canResume(try #require(h.model.record(id))))
        h.model.resume(id)
        try await waitUntil("finished") { h.phase(id) == .finished }
    }

    // MARK: interrupted at bootstrap

    @Test func unfinishedJobBecomesInterruptedAndResumes() async throws {
        let scan = TestData.scan()
        let id = FixtureFactory.weddingID(77)
        let deliveries = DeliveryPreset.builtIns.filter { DeliveryPreset.defaultOnIDs.contains($0.id) }
        let request = JobRequest(wedding: id, name: "Finn und Lissy", photos: scan.photos, sourceRoots: scan.sourceRoots,
                                 deliveries: deliveries, outputFolder: URL(fileURLWithPath: "/tmp/hmb-never-written"),
                                 naming: .default, processorUse: .automatic)
        let done = scan.photos.prefix(12).flatMap { photo in
            deliveries.map { FixtureFactory.result(for: photo, preset: $0, wedding: "Finn und Lissy", count: scan.photos.count) }
        }
        var record = WeddingRecord(id: id, name: "Finn und Lissy", createdAt: Date(), weddingDate: scan.weddingDate,
                                   camera: scan.camera, sourceRoots: scan.sourceRoots, sourceBookmarks: [],
                                   photos: scan.photos, deliveries: deliveries, deliveryCompletedAt: [:],
                                   outputFolder: request.outputFolder, outputBookmark: nil, naming: .default,
                                   phase: .running, results: Array(done.prefix(10)), startedAt: Date(), finishedAt: nil,
                                   activeSeconds: 5, viewed: false)
        record.results = Array(done.prefix(10))
        let h = Harness(TestData.configuration(scan, unfinished: [UnfinishedJob(request: request, results: done)]), records: [record])
        await h.model.bootstrap()
        #expect(h.phase(id) == .interrupted)
        #expect(h.model.record(id)?.results.count == 24)               // journal results merged in
        #expect(h.model.record(id)?.photosFinished == 12)
        #expect(h.model.state.queue.isEmpty)                           // never resumes on its own
        #expect(h.engine.runs.isEmpty)
        #expect(AppAlert.photosDone(id, in: h.model.state) == 12)
        h.model.resume(id)
        try await waitUntil("finished") { h.phase(id) == .finished }
        #expect(h.engine.runs.first?.resume == true)
        #expect(h.model.record(id)?.results.count == 80)
    }

    @Test func journalWithoutRecordAndStopHere() async throws {
        let scan = TestData.scan(10)
        let id = FixtureFactory.weddingID(78)
        let request = JobRequest(wedding: id, name: "Anna und Ben", photos: scan.photos, sourceRoots: scan.sourceRoots,
                                 deliveries: [DeliveryPreset.builtIns[0]], outputFolder: URL(fileURLWithPath: "/tmp/x"),
                                 naming: .default, processorUse: .automatic)
        let h = Harness(TestData.configuration(scan, unfinished: [UnfinishedJob(request: request, results: [])]))
        await h.model.bootstrap()
        #expect(h.phase(id) == .interrupted)
        #expect(h.model.record(id)?.name == "Anna und Ben")
        h.model.stopHere(id)
        #expect(h.phase(id) == .stopped)
    }

    @Test func bootstrapLoadsStoresAndRequeues() async throws {
        let queued = Fixtures.annaUndBen
        let h = Harness(TestData.configuration(TestData.scan(5)), records: [Fixtures.finnUndLissy, queued])
        await h.model.bootstrap()
        #expect(h.model.state.records.count == 2)
        #expect(h.model.state.sidebarVisible)                           // history exists
        try await waitUntil("queued wedding runs") { h.phase(queued.id) == .finished }
    }

    // MARK: Create More Deliveries

    @Test func createMoreDeliveriesUsesTheExistingFolder() async throws {
        let original = Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy)
        let h = Harness(records: [original])
        await h.model.bootstrap()
        h.model.createMoreDeliveries(original.id)
        let draft = try #require(h.model.state.draft)
        #expect(draft.existingWedding == original.id)
        #expect(h.model.state.selection == .wedding(original.id))
        #expect(draft.completedDeliveries[.couple] != nil && draft.completedDeliveries[.website] != nil)
        #expect(draft.enabled[.couple] == true && draft.enabled[.archive] == false)
        h.model.toggleDelivery(.couple)                                 // completed: disabled
        #expect(h.model.state.draft?.enabled[.couple] == true)
        #expect(h.model.draftSelectedPresets.isEmpty && !h.model.draftCanStart)
        #expect(Copy.Setup.done(try #require(draft.completedDeliveries[.couple]), locale: Locale(identifier: "en_US"),
                                timeZone: FixtureFactory.timeZone) == "Done Jul 14")
        h.model.toggleDelivery(.archive)
        #expect(h.model.draftOutputFolder == original.outputFolder)
        try await waitUntil("estimate") { h.model.draftEstimatedBytes != nil }
        h.model.startDraft()
        try await waitUntil("finished") { h.phase(original.id) == .finished && h.model.state.draft == nil }
        let run = try #require(h.engine.runs.first)
        #expect(run.request.deliveries.map(\.id) == [.archive])
        #expect(run.request.appendToExistingFolder)
        #expect(run.request.outputFolder == original.outputFolder)
        let record = try #require(h.model.record(original.id))
        #expect(record.deliveries.map(\.id) == [.couple, .website, .archive])
        #expect(record.deliveryCompletedAt["archive"] != nil)
        #expect(record.deliveryCompletedAt["couple"] == original.deliveryCompletedAt["couple"])
        #expect(record.results.filter { $0.delivery == .couple }.count == 535)   // untouched
        #expect(record.results.filter { $0.delivery == .archive }.count == 535)
        #expect(h.model.state.records.count == 1)
    }

    @Test func cancelCreateMoreReturnsToDone() async throws {
        let original = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let h = Harness(records: [original])
        h.model.createMoreDeliveries(original.id)
        #expect(h.model.state.draft != nil)
        h.model.cancelSetup()
        #expect(h.model.state.selection == .wedding(original.id))
        #expect(h.model.record(original.id) == original)
    }

    // MARK: retry

    @Test func retryRedoesOnlyFailedPairs() async throws {
        let failing = FixtureEngine(TestData.configuration(failures: [
            .init(photo: PhotoID(3), delivery: .website, failure: .encodeFailed),
            .init(photo: PhotoID(7), failure: .unreadable),
        ]))
        let clean = FixtureEngine(TestData.configuration())
        let h = Harness(engine: SpyEngine(failing, clean))
        let id = try await h.dropAndStart()
        try await waitUntil("finished") { h.phase(id) == .finished }
        let presentation = WeddingPresentation(try #require(h.model.record(id)))
        #expect(presentation.issuePhotoCount == 2)
        #expect(presentation.issueGroups.map(\.failure) == [.unreadable, .encodeFailed])
        h.model.retry(id, photos: nil)                                  // Try Again for All: retryable only
        try await waitUntil("retry finished") { h.engine.runs.count == 2 && h.phase(id) == .finished }
        let retry = try #require(h.engine.runs.last)
        #expect(retry.request.onlyPhotos == [PhotoID(3)])
        #expect(retry.request.deliveries.map(\.id) == [.website])
        #expect(retry.request.appendToExistingFolder)
        let after = WeddingPresentation(try #require(h.model.record(id)))
        #expect(after.issuePhotoCount == 1)                              // the unreadable one stays
        #expect(after.issueGroups.map(\.failure) == [.unreadable])
    }

    @Test func failedJobTryAgainAndRemove() async throws {
        let h = Harness(engine: SpyEngine(FixtureEngine(TestData.configuration(failJob: "“Wedding SSD” was disconnected before any photo was finished.")),
                                          FixtureEngine(TestData.configuration())))
        let id = try await h.dropAndStart()
        try await waitUntil("failed") { if case .failed? = h.phase(id) { true } else { false } }
        #expect(h.model.state.queue.isEmpty)
        h.model.retry(id, photos: nil)
        try await waitUntil("finished") { h.phase(id) == .finished }
        #expect(h.engine.runs.last?.resume == false)
    }

    // MARK: relink and remove

    @Test func relinkNeedsNinetyPercentOfOutputs() throws {
        let record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let h = Harness(records: [record])
        let folder = URL(fileURLWithPath: "/Volumes/Archive/Finn und Lissy – Deliveries", isDirectory: true)
        let paths = record.results.compactMap(\.outRelativePath)
        #expect(paths.count == 535)
        h.log.existing = Set(paths.prefix(470).map { folder.appending(path: $0).standardizedFileURL.path })    // 87.9 %
        #expect(!h.model.relink(record.id, to: folder))
        #expect(h.model.record(record.id)?.outputFolder == record.outputFolder)
        h.log.existing = Set(paths.prefix(482).map { folder.appending(path: $0).standardizedFileURL.path })    // 90.1 %
        #expect(h.model.relink(record.id, to: folder))
        #expect(h.model.record(record.id)?.outputFolder == folder)
        #expect(!h.model.missingFolders.contains(record.id))
    }

    @Test func missingFolderIsDetectedAndLocated() async throws {
        let record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let h = Harness(records: [record])
        h.log.existing = []
        await h.model.bootstrap()
        #expect(h.model.missingFolders.contains(record.id))
        #expect(!h.model.canCompare(try #require(h.model.record(record.id))))
        h.model.createMoreDeliveries(record.id)
        #expect(h.model.state.draft == nil)                              // disabled while missing
        let folder = URL(fileURLWithPath: "/Volumes/X/Deliveries", isDirectory: true)
        h.log.chooseFolder = folder
        h.model.locateFolder(record.id)
        #expect(h.model.state.toast == Copy.MissingFolder.locateFailed)
        h.log.existing = Set(record.results.compactMap(\.outRelativePath).map { folder.appending(path: $0).standardizedFileURL.path })
        h.model.locateFolder(record.id)
        #expect(!h.model.missingFolders.contains(record.id))
    }

    @Test func removeFromHistoryLeavesFilesAlone() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hmb-wp3-\(UUID().uuidString)", directoryHint: .isDirectory)
        let couple = directory.appending(path: "Couple", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: couple, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = couple.appending(path: "Finn-und-Lissy-0001.jpg")
        try Data("jpeg".utf8).write(to: file)
        var record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        record.outputFolder = directory
        let h = Harness(records: [record])
        h.model.select(.wedding(record.id))
        h.model.requestRemoveFromHistory(record.id)
        #expect(h.model.state.alert == .removeFromHistory(record.id))
        let copy = try #require(h.model.state.alert).copy(in: h.model.state)
        #expect(copy.title == "Remove “Finn und Lissy” from history?")
        h.model.confirmAlert()
        #expect(h.model.record(record.id) == nil)
        #expect(h.model.state.selection == .newWedding)
        await h.model.flushSaves()
        #expect(try await h.history.loadAll().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file) == Data("jpeg".utf8))
    }

    @Test func renameAndMarkViewed() async throws {
        var record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        record.viewed = false
        let h = Harness(records: [record])
        h.model.requestRename(record.id)
        #expect(h.model.state.sheet == .renameWedding(record.id))
        h.model.renameWedding(record.id, to: "  Lissy & Finn ")
        #expect(h.model.record(record.id)?.name == "Lissy & Finn")
        h.model.select(.wedding(record.id))
        #expect(h.model.record(record.id)?.viewed == true)
        #expect(h.log.dock.last?.1 == 0)
    }
}
