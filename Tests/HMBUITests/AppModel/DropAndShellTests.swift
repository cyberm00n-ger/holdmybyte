// §5.3 acceptance 3 (drag and drop → S2–S4) and 4 (closing the window, the menu-bar extra, quitting).
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Testing

@MainActor @Suite struct DropTests {
    @Test func dragSummaryForFolderFilesAndMix() {
        let h = Harness()
        let folder = URL(fileURLWithPath: "/Users/sebastian/Weddings/Finn und Lissy/fertig", isDirectory: true)
        let other = URL(fileURLWithPath: "/Users/sebastian/Weddings/Anna", isDirectory: true)
        let files = (1...535).map { URL(fileURLWithPath: "/Users/sebastian/Weddings/Finn und Lissy/fertig/DSC\($0).jpg") }
        #expect(h.model.dragSummary(for: [folder]) == .folder(name: "Finn und Lissy"))
        #expect(h.model.dragSummary(for: files) == .photos(count: 535))
        #expect(h.model.dragSummary(for: [folder, files[0], files[1]]) == .items(count: 3))
        #expect(h.model.dragSummary(for: [folder, other]) == .items(count: 2))
        #expect(Copy.DragTarget.title(.folder(name: "Finn und Lissy")) == "Release to add “Finn und Lissy”")
    }

    @Test func dragTargetStatesOnEachScreen() async throws {
        let h = Harness()
        h.model.setDropTargeted(true, summary: .folder(name: "Finn und Lissy"))
        #expect(h.model.state.dropZone == .targeted(.folder(name: "Finn und Lissy")))
        h.model.setDropTargeted(false, summary: nil)
        #expect(h.model.state.dropZone == .idle)
        // Over Setup: the setup gets the "Add to this wedding" state, the zone stays idle.
        h.model.handleDrop([TestData.folder])
        h.model.setDropTargeted(true, summary: .photos(count: 3))
        #expect(h.model.state.draft?.isDropTargeted == true)
        #expect(h.model.state.dropZone == .idle)
        h.model.setDropTargeted(false, summary: nil)
        #expect(h.model.state.draft?.isDropTargeted == false)
    }

    @Test func dropFolderOpensSetupImmediately() {
        let h = Harness(TestData.configuration(scanDuration: .seconds(5)))
        let start = ContinuousClock.now
        #expect(h.model.handleDrop([TestData.folder]))
        let elapsed = ContinuousClock.now - start
        #expect(h.model.state.draft?.name == "Finn und Lissy")
        #expect(h.model.state.draft?.scan == .scanning(found: 0))
        #expect(elapsed < .milliseconds(100))                           // F1 step 2: setup within 100 ms
        #expect(!h.model.handleDrop([]))
    }

    @Test func dropLooseFilesUsesTheirCommonParent() {
        let h = Harness(TestData.configuration(scanDuration: .seconds(5)))
        let files = ["DSC1.jpg", "DSC2.jpg"].map { URL(fileURLWithPath: "/Users/sebastian/Weddings/Lea und Paul/Export/\($0)") }
        h.model.handleDrop(files)
        #expect(h.model.state.draft?.name == "Lea und Paul")
    }

    @Test func dropOnlyRawShowsTheRawError() async throws {
        let h = Harness(TestData.configuration(TestData.scan(0, rawCount: 535)))
        h.model.handleDrop([TestData.folder])
        try await waitUntil("error") { h.model.state.dropZone != .idle }
        #expect(h.model.state.dropZone == .error(.onlyRaw(folderName: "Finn und Lissy", count: 535)))
        #expect(h.model.state.draft == nil)
        #expect(Copy.DropError.onlyRaw(folderName: "Finn und Lissy", count: 535, locale: Locale(identifier: "en_US"))
                == "“Finn und Lissy” contains 535 RAW files. holdmybyte compresses finished photos: export JPEGs first.")
        // The next drag clears the error.
        h.model.setDropTargeted(true, summary: .photos(count: 2))
        #expect(h.model.state.dropZone == .targeted(.photos(count: 2)))
    }

    @Test func dropNothingUsableShowsNoPhotos() async throws {
        let h = Harness(TestData.configuration(TestData.scan(0)))
        h.model.handleDrop([URL(fileURLWithPath: "/Users/sebastian/Documents/notes.txt")])
        try await waitUntil("error") { h.model.state.dropZone != .idle }
        #expect(h.model.state.dropZone == .error(.noPhotos))
    }

    @Test func scanErrorShowsNoPhotos() async throws {
        var configuration = TestData.configuration()
        configuration.scanError = "unreadable volume"
        let h = Harness(configuration)
        h.model.handleDrop([TestData.folder])
        try await waitUntil("error") { h.model.state.dropZone != .idle }
        #expect(h.model.state.dropZone == .error(.noPhotos))
    }

    @Test func dropOnSetupAddsToThisWedding() async throws {
        let h = Harness()
        h.model.handleDrop([TestData.folder])
        try await waitUntil("ready") { if case .ready? = h.model.state.draft?.scan { true } else { false } }
        let id = try #require(h.model.state.draft?.wedding)
        let extra = URL(fileURLWithPath: "/Users/sebastian/Weddings/Finn und Lissy/Getting Ready", isDirectory: true)
        h.model.handleDrop([extra])
        #expect(h.model.state.draft?.wedding == id)                       // same wedding
        #expect(h.engine.scans.last == [TestData.folder, extra])
    }

    @Test func dropOverDoneStartsANewWedding() async throws {
        let record = Fixtures.only([.couple], of: Fixtures.finnUndLissy)
        let h = Harness(TestData.configuration(scanDuration: .seconds(5)), records: [record])
        h.model.select(.wedding(record.id))
        h.model.setDropTargeted(true, summary: .folder(name: "Anna"))
        #expect(h.model.state.dropZone == .targeted(.folder(name: "Anna")))   // "Start a new wedding" capsule
        h.model.setDropTargeted(false, summary: nil)
        h.model.handleDrop([URL(fileURLWithPath: "/Users/sebastian/Weddings/Anna und Ben/Export", isDirectory: true)])
        #expect(h.model.state.selection == .newWedding)
        #expect(h.model.state.draft?.name == "Anna und Ben")
        #expect(h.model.state.draft?.existingWedding == nil)
    }

    @Test func choosePhotosUsesThePanel() {
        let h = Harness(TestData.configuration(scanDuration: .seconds(5)))
        h.log.chooseItems = nil
        h.model.choosePhotos()
        #expect(h.model.state.draft == nil)
        h.log.chooseItems = [TestData.folder]
        h.model.choosePhotos()
        #expect(h.model.state.draft != nil)
    }
}

@MainActor @Suite struct ShellTests {
    @Test func closingTheWindowWhileRunningShowsTheStatusItem() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.004))
        #expect(!h.model.showsTransientStatusItem)
        let id = try await h.dropAndStart()
        #expect(h.model.isRunning)                                        // AppDelegate keeps the app alive
        #expect(!h.model.showsTransientStatusItem)                        // window still open
        h.model.windowDidDisappear()
        #expect(h.model.showsTransientStatusItem)
        h.model.showsTransientStatusItem = false                          // the user removed it
        #expect(!h.model.showsTransientStatusItem)
        try await waitUntil("finished") { h.phase(id) == .finished }
        #expect(!h.model.showsTransientStatusItem)                        // removed when the job ends
        #expect(!h.model.isRunning)                                       // idle: closing the window quits
        #expect(h.model.record(id)?.viewed == false)                      // finished while closed: Dock badge
        #expect(h.log.dock.last?.0 == nil && h.log.dock.last?.1 == 1)
        h.model.windowDidAppear()
        h.model.select(.wedding(id))
        #expect(h.log.dock.last?.1 == 0)
    }

    @Test func statusItemFollowsTheSetting() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.004))
        h.model.state.settings.menuBarWhileClosed = false
        _ = try await h.dropAndStart()
        h.model.windowDidDisappear()
        #expect(!h.model.showsTransientStatusItem)
    }

    @Test func quitWhileRunningAsksAndInterrupts() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.004))
        let id = try await h.dropAndStart()
        #expect(!h.model.requestQuit())
        #expect(h.model.state.alert == .quitWhileRunning(id))
        h.model.dismissAlert()                                            // Cancel
        #expect(h.log.terminateReplies == [false])
        #expect(h.phase(id) == .running)
        #expect(!h.model.requestQuit())
        h.model.confirmAlert()                                            // Quit
        try await waitUntil("reply") { h.log.terminateReplies.count == 2 }
        #expect(h.log.terminateReplies == [false, true])
        #expect(h.phase(id) == .interrupted)
        let saved = try #require(try await h.history.loadAll().first { $0.id == id })
        #expect(saved.phase == .interrupted)
    }

    @Test func idleQuitIsImmediate() {
        let h = Harness()
        #expect(h.model.requestQuit())
        #expect(h.model.state.alert == nil)
    }

    @Test func progressIsAnnouncedAndShownInTheDock() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.004))
        let id = try await h.dropAndStart()
        try await waitUntil("finished") { h.phase(id) == .finished }
        #expect(h.log.announcements.contains { $0.hasSuffix("percent done") })
        #expect(h.log.announcements.last == "Finn und Lissy is ready")
        #expect(h.log.dock.contains { ($0.0 ?? 0) > 0 })
    }

    @Test func sidebarSearchMatchesNameMonthYearPathAndCamera() {
        var state = AppState()
        state.records = Fixtures.history
        func titles(_ query: String) -> [String] {
            state.search = query
            let sections = SidebarSections(state, locale: Locale(identifier: "en_US"), timeZone: FixtureFactory.timeZone)
            return (sections.active + sections.months.flatMap(\.records)).map(\.name)
        }
        #expect(titles("lissy") == ["Finn und Lissy"])
        #expect(titles("LISSY") == ["Finn und Lissy"])
        #expect(titles("july 2026").contains("Finn und Lissy"))
        #expect(titles("x-h2").count > 0)
        #expect(titles("Hochzeit am See").isEmpty)
        state.search = "lissy"
        let groups = SidebarSections(state, locale: Locale(identifier: "en_US"), timeZone: FixtureFactory.timeZone).months
        #expect(groups.map(\.title) == ["July 2026"])                    // grouped by wedding date
    }

    @Test func sidebarGroupsAndLifetimeFooter() {
        var state = AppState()
        state.records = Fixtures.history
        let sections = SidebarSections(state, locale: Locale(identifier: "en_US"), timeZone: FixtureFactory.timeZone)
        #expect(sections.months.first?.title == "October 2026")
        #expect(sections.months.count == 14)
        #expect(sections.lifetimeWeddings == 38)
        #expect(Copy.Sidebar.lifetime(savedBytes: sections.lifetimeSaved, weddings: sections.lifetimeWeddings,
                                      locale: Locale(identifier: "en_US")) == "1.24 TB saved across 38 weddings")
        let empty = SidebarSections(AppState(), locale: Locale(identifier: "en_US"))
        #expect(empty.lifetimeWeddings == 0 && empty.isEmpty)            // footer hidden
    }

    @Test func catalogueBuildsEveryState() {
        for id in WP3StateCatalogue.ids {
            #expect(WP3StateCatalogue.model(id) != nil, "\(id)")
        }
        #expect(WP3StateCatalogue.model("nope") == nil)
        #expect(WP3StateCatalogue.model("done-missing-folder")?.missingFolders.contains(Fixtures.finnUndLissyID) == true)
    }
}
