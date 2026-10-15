// Integration (lead) fixes: the merged packages wired together, and the flow gaps found walking §1.2 and §6.4.
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Testing

@MainActor @Suite struct IntegrationTests {
    // MARK: Done view layout helpers

    @Test func histogramShowsThreeTicksInsideItsDomain() {
        // The domain of Finn und Lissy's Couple’s Package (scores 74.0–76.2, Balanced band): rounding to nearest put
        // the last tick on the domain's edge, where Charts dropped it (two ticks instead of three).
        #expect(ScoreHistogram.ticks(lo: 73.5, hi: 77.0) == [74, 75, 76])
        let narrow = ScoreHistogram.ticks(lo: 84.5, hi: 86.5)
        #expect(narrow == [85, 85.5, 86])
        for (lo, hi) in [(69.5, 80.0), (73.5, 77.0), (84.5, 90.5), (84.5, 86.5)] {
            let ticks = ScoreHistogram.ticks(lo: lo, hi: hi)
            #expect(ticks.count == 3)
            #expect(ticks.allSatisfy { $0 > lo && $0 < hi })
        }
    }

    @Test func deliveryTilesFillTheRowInBalancedRows() {
        #expect(DeliveryTiles.columnCount(tiles: 1, width: 900) == 1)       // a single delivery spans the width
        #expect(DeliveryTiles.columnCount(tiles: 2, width: 900) == 2)       // two share it (no empty third column)
        #expect(DeliveryTiles.columnCount(tiles: 3, width: 900) == 3)
        #expect(DeliveryTiles.columnCount(tiles: 4, width: 900) == 2)       // 2 × 2, never 3 + 1
        #expect(DeliveryTiles.columnCount(tiles: 4, width: 1300) == 4)
        #expect(DeliveryTiles.columnCount(tiles: 3, width: 456) == 2)       // the 780 × 560 window
        #expect(DeliveryTiles.columnCount(tiles: 2, width: 200) == 1)       // narrower than one tile: one column
    }

    @Test func presentationIsNotSharedBetweenDifferentOutcomesOfOneWedding() {
        // Same id, result count, finish time, deliveries and name; different outcomes. The memo keyed on those alone
        // showed done-issues' issues in the kept-original and missing-folder states.
        let clean = Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy)
        let issues = Fixtures.withIssues(clean)
        #expect(WeddingPresentation.of(issues).failedPhotos.count == 3)
        #expect(WeddingPresentation.of(clean).failedPhotos.isEmpty)
        #expect(WeddingPresentation.of(issues).failedPhotos.count == 3)
    }

    // MARK: Settings and the stores

    @Test func clearHistoryGoesThroughTheSaveChainAndUpdatesTheDock() async throws {
        let unviewed = { () -> WeddingRecord in var r = Fixtures.finnUndLissy; r.viewed = false; return r }()
        let history = [unviewed] + Fixtures.history.filter { $0.id != Fixtures.finnUndLissyID }
        let h = Harness(records: [Fixtures.annaUndBen] + history)
        h.model.createMoreDeliveries(Fixtures.finnUndLissyID)
        #expect(h.model.state.draft?.existingWedding == Fixtures.finnUndLissyID)

        h.model.clearHistory()
        #expect(h.model.state.records.map(\.id) == [Fixtures.annaUndBenID])   // in progress stays
        #expect(h.model.state.draft == nil)                                   // its Create More setup is gone
        #expect(h.log.dock.last?.1 == 0)                                      // no unviewed finished wedding left
        await h.model.flushSaves()                                            // what quit waits for
        #expect(try await h.history.loadAll().map(\.id) == [Fixtures.annaUndBenID])
    }

    @Test func editingADeliveryDuringSetupReestimatesIt() async throws {
        let h = Harness(TestData.configuration())
        h.model.handleDrop([TestData.folder])
        try await waitUntil("estimates") { h.model.draftEstimatedBytes != nil }
        guard case .ready? = h.model.state.draft?.estimates[.couple] else { Issue.record("no estimate"); return }

        var smaller = try #require(h.model.state.presets.first { $0.id == .couple })
        smaller.size = .longEdge(2048)
        smaller.quality = .web
        h.model.editDelivery(smaller)
        h.model.savePreset(smaller)
        #expect(h.model.state.sheet == nil)
        #expect(h.model.state.draft?.estimates[.couple] == .estimating)       // the old number is never shown again
        try await waitUntil("re-estimated") {
            if case .ready? = h.model.state.draft?.estimates[.couple] { true } else { false }
        }
    }

    @Test func addingADeliveryFromSetupChecksAndEstimatesIt() async throws {
        let h = Harness(TestData.configuration())
        h.model.handleDrop([TestData.folder])
        try await waitUntil("estimates") { h.model.draftEstimatedBytes != nil }
        h.model.addDelivery()
        guard case .editDelivery(let preset, true)? = h.model.state.sheet else { Issue.record("no sheet"); return }
        h.model.savePreset(preset)
        #expect(h.model.state.draft?.enabled[preset.id] == true)
        try await waitUntil("estimated") {
            if case .ready? = h.model.state.draft?.estimates[preset.id] { true } else { false }
        }
    }

    // MARK: Alerts, quit and the keyboard

    @Test func quitWhileRunningClosesASheetSoTheAlertCanShow() async throws {
        let h = Harness(TestData.configuration(secondsPerPhoto: 0.05))
        let id = try await h.dropAndStart()
        try await waitUntil("running") { h.phase(id) == .running }
        h.model.requestRename(id)
        #expect(h.model.state.sheet == .renameWedding(id))
        #expect(h.model.requestQuit() == false)
        #expect(h.model.state.sheet == nil)
        #expect(h.model.state.alert == .quitWhileRunning(id))
        h.model.dismissAlert()                                                // Cancel: the app keeps running
        #expect(h.log.terminateReplies == [false])
        h.model.requestStop(id)
        h.model.confirmAlert()
        try await waitUntil("stopped") { h.phase(id) == .stopped }
    }

    @Test func compareKeysStayAwayFromTextFieldsSheetsAndOtherWindows() throws {
        let record = Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy)
        let h = Harness(records: [record])
        h.model.select(.wedding(record.id))
        #expect(!h.model.compareKeysActive)                                   // Compare is not open
        h.model.compare(record, photo: nil)
        #expect(h.model.compareKeysActive)
        h.model.textInputActive = true                                        // typing in the sidebar search
        #expect(!h.model.compareKeysActive)
        h.model.textInputActive = false
        h.model.requestRename(record.id)
        #expect(!h.model.compareKeysActive)                                   // a sheet has the keys
        h.model.state.sheet = nil
        h.model.compareWindowIsKey = false                                    // Settings is the key window
        #expect(!h.model.compareKeysActive)
        h.model.compareWindowIsKey = true
        h.model.closeCompare()
        #expect(!h.model.compareKeysActive)
        #expect(h.model.state.detailPath.isEmpty)
    }

    // MARK: Wiring

    @Test func learnedEstimatesPrefixIsTheEngines() {
        // HMBEngine's `LearnedEstimates.keyPrefix` (HMBUI cannot import the engine).
        #expect(AppModel.learnedEstimatesKeyPrefix == "holdmybyte.estimate.")
    }

    @Test func alertCopyIsTheSingleSourceForEveryAlert() {
        var state = AppState()
        state.records = Fixtures.history
        for alert: AppAlert in [.stop(Fixtures.finnUndLissyID), .quitWhileRunning(Fixtures.finnUndLissyID),
                                .removeFromHistory(Fixtures.finnUndLissyID), .clearHistory] {
            let copy = alert.copy(in: state, locale: Locale(identifier: "en_DE"))
            #expect(copy.buttons.count == 2)
            #expect(copy.buttons.indices.contains(alert.defaultButtonIndex))
            #expect(!copy.title.isEmpty && !copy.message.isEmpty)
        }
        #expect(AppAlert.clearHistory.copy(in: state).title == "Clear the history of all 38 weddings?")
    }
}
