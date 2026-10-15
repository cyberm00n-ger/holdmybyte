// Every WP3 snapshot state (§5.5 catalogue ids) as a ready `AppModel` built from fixtures, with no side effects.
// WP5's harness can build its catalogue entries from these; WP3's own render test uses them for visual review.
import Foundation
import HMBFixtures
import HMBModel

public enum WP3StateCatalogue {
    /// The ids this catalogue renders (WP4 owns edit-delivery, compare-* and settings-*).
    public static let ids: [String] = [
        "empty", "empty-error-raw", "empty-error-none", "drag-target",
        "preparing", "setup-ready", "setup-estimating", "setup-warn-precompressed", "setup-blocked-disk",
        "setup-create-more", "drop-on-setup",
        "queued", "running-early", "running-mid", "paused-user", "paused-drive", "paused-disk", "stopped", "interrupted",
        "done-single", "done-three", "done-issues", "done-kept-original", "done-missing-folder", "failed",
        "history-search", "history-empty-search",
        "menubar-extra", "alert-stop", "alert-quit", "alert-remove",
    ]

    /// The model for `id`, or nil for an unknown id. `thumbnails` defaults to synthetic fixture images.
    @MainActor
    public static func model(_ id: String, thumbnails: any ThumbnailProviding = FixtureThumbnails()) -> AppModel? {
        guard let state = state(id) else { return nil }
        let model = AppModel(state: state, engine: FixtureEngine(), history: InMemoryHistory(state.records),
                             presetsStore: InMemoryPresets(), settingsStore: InMemorySettings(), thumbnails: thumbnails)
        if id == "done-missing-folder" {
            var platform = AppPlatform.inert
            let missing = Fixtures.finnUndLissy.outputFolder
            platform.fileExists = { $0 != missing }
            model.platform = platform
            model.volumesChanged()
        }
        return model
    }

    /// The `AppState` for `id`.
    public static func state(_ id: String) -> AppState? {
        var state = AppState()
        state.sidebarVisible = true
        state.records = Fixtures.history
        let finn = Fixtures.finnUndLissyID

        func setup(_ scan: ScanState, estimates: [DeliveryID: EstimateState]? = nil, preflight: [ScanNotice] = []) {
            var draft = SetupDraft(wedding: FixtureFactory.weddingID(900), name: "Finn und Lissy", scan: scan,
                                   enabled: [.couple: true, .website: true, .social: false, .archive: false],
                                   naming: .default)
            if case .ready = scan {
                draft.estimates = estimates ?? Fixtures.estimates.mapValues(EstimateState.ready)
                draft.preflight = Preflight(outputFolder: Fixtures.finnUndLissy.outputFolder, estimatedBytes: 1_561_000_000,
                                            notices: preflight)
            } else {
                draft.estimates = [.couple: .estimating, .website: .estimating]
            }
            state.records = Fixtures.history.filter { $0.id != finn }
            state.draft = draft
            state.selection = .newWedding
        }

        func running(_ done: Int, phase: JobPhase = .running) {
            let (record, progress) = Fixtures.inProgress(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy),
                                                         done: done, phase: phase)
            state.records = [record] + Fixtures.history.filter { $0.id != finn }
            state.live[finn] = phase == .running ? progress : nil
            state.queue = phase == .running || isPaused(phase) ? [finn] : []
            state.selection = .wedding(finn)
        }

        func done(_ record: WeddingRecord) {
            state.records = [record] + Fixtures.history.filter { $0.id != finn }
            state.selection = .wedding(finn)
        }

        switch id {
        case "empty":
            state = AppState()
        case "empty-error-raw":
            state = AppState()
            state.dropZone = .error(.onlyRaw(folderName: "Finn und Lissy", count: 535))
        case "empty-error-none":
            state = AppState()
            state.dropZone = .error(.noPhotos)
        case "drag-target":
            state = AppState()
            state.dropZone = .targeted(.folder(name: "Finn und Lissy"))
        case "preparing":
            setup(.scanning(found: 212))
        case "setup-ready":
            setup(.ready(Fixtures.scanResult))
        case "setup-estimating":
            setup(.ready(Fixtures.scanResult), estimates: [.couple: .estimating, .website: .estimating])
        case "setup-warn-precompressed":
            var scan = Fixtures.scanResult
            scan.notices = [.alreadyCompressed(count: 312, of: 535), .skippedNonPhotos(count: 14, extensions: ["xmp", "mov"])]
            setup(.ready(scan))
        case "setup-blocked-disk":
            setup(.ready(Fixtures.scanResult),
                  preflight: [.notEnoughSpace(volume: "Macintosh HD", needed: 1_900_000_000, available: 800_000_000)])
        case "setup-create-more":
            let record = Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy)
            done(record)
            var completed: [DeliveryID: Date] = [:]
            for (key, date) in record.deliveryCompletedAt { completed[DeliveryID(rawValue: key)] = date }
            let scan = ScanResult(photos: record.photos, sourceRoots: record.sourceRoots, suggestedName: record.name,
                                  weddingDate: record.weddingDate, camera: record.camera, totalBytes: record.sourceBytes,
                                  rawCount: 0, notices: [])
            state.draft = SetupDraft(wedding: finn, name: record.name, scan: .ready(scan),
                                     enabled: [.couple: true, .website: true, .social: false, .archive: true],
                                     estimates: [.archive: .ready(Fixtures.estimates[.archive]!)], naming: record.naming,
                                     preflight: Preflight(outputFolder: record.outputFolder, estimatedBytes: 8_560_000_000, notices: []),
                                     existingWedding: finn, completedDeliveries: completed)
        case "drop-on-setup":
            setup(.ready(Fixtures.scanResult))
            state.draft?.isDropTargeted = true
        case "queued":
            running(312)
            state.records.insert(Fixtures.annaUndBen, at: 1)
            state.queue = [finn, Fixtures.annaUndBenID]
            state.selection = .wedding(Fixtures.annaUndBenID)
        case "running-early":
            running(6)
        case "running-mid":
            running(312)
        case "paused-user":
            running(312, phase: .paused(.user))
        case "paused-drive":
            running(312, phase: .paused(.sourceUnavailable(volume: "Wedding SSD")))
        case "paused-disk":
            running(312, phase: .paused(.diskFull(volume: "Macintosh HD", neededBytes: 600_000_000)))
        case "stopped":
            running(312, phase: .stopped)
        case "interrupted":
            running(312, phase: .interrupted)
        case "done-single":
            done(Fixtures.only([.couple], of: Fixtures.finnUndLissy))
        case "done-three":
            done(Fixtures.only([.couple, .website, .archive], of: Fixtures.finnUndLissy))
        case "done-issues":
            done(Fixtures.withIssues(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy)))
        case "done-kept-original":
            done(Fixtures.keptOriginal(7))
        case "done-missing-folder":
            done(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy))
        case "failed":
            done(Fixtures.failed(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy)))
        case "history-search":
            state.search = "lissy"
            state.selection = .wedding(finn)
        case "history-empty-search":
            state.search = "Hochzeit am See"
            state.selection = .newWedding
        case "menubar-extra":
            running(312)
            state.windowOpen = false
        case "alert-stop":
            running(312)
            state.alert = .stop(finn)
        case "alert-quit":
            running(312)
            state.alert = .quitWhileRunning(finn)
        case "alert-remove":
            done(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy))
            state.alert = .removeFromHistory(finn)
        default:
            return nil
        }
        return state
    }

    static func isPaused(_ phase: JobPhase) -> Bool { if case .paused = phase { true } else { false } }
}
