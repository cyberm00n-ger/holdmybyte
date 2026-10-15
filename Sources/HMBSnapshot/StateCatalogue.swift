// The snapshot state catalogue (Docs/SPEC.md §5.5). It must contain exactly the ids listed in §5.5; adding a state
// to §2 means adding it here. `Tests/HMBBenchTests/CatalogueTests.swift` checks this file against the spec text.
import CoreGraphics
import Foundation
import HMBFixtures
import HMBModel
import HMBUI

/// What the harness hosts for an entry.
enum SnapshotSurface: Equatable, Sendable {
    /// `RootView` in an offscreen main window (sheets presented by it are composited on top).
    case window
    /// `SettingsView` at 600 wide, height fitting its content.
    case settings
    /// `StatusMenu` content (the transient menu-bar extra).
    case menuBar
    /// A real `NSAlert` laid out from the alert copy.
    case alert(AppAlert)
}

/// Everything one render needs: the UI state plus the fixture engine's script.
struct SnapshotScenario: Sendable {
    var state: AppState
    var engine = FixtureEngine.Configuration()
    /// Output folders that do not exist (S12). Every other path exists, so no other done state shows the banner.
    var missingFolders: Set<URL> = []
}

struct CatalogueEntry: Sendable {
    let id: String
    /// Spec section, e.g. "§2.4 S8".
    let section: String
    let surface: SnapshotSurface
    /// Additional window sizes rendered besides the run size (§6.3: the 780×560 minimum).
    let extraSizes: [CGSize]
    let make: @Sendable () -> SnapshotScenario

    init(_ id: String, _ section: String, surface: SnapshotSurface = .window, extraSizes: [CGSize] = [],
         make: @escaping @Sendable () -> SnapshotScenario) {
        self.id = id; self.section = section; self.surface = surface; self.extraSizes = extraSizes; self.make = make
    }
}

enum StateCatalogue {
    static let minimumSize = CGSize(width: 780, height: 560)

    /// Exactly the §5.5 ids, in spec order.
    static let entries: [CatalogueEntry] = [
        // Empty and drop
        CatalogueEntry("empty", "§2.4 S1") { Scenarios.empty() },
        CatalogueEntry("empty-error-raw", "§2.4 S2") { Scenarios.empty(.error(.onlyRaw(folderName: "Finn und Lissy", count: 535))) },
        CatalogueEntry("empty-error-none", "§2.4 S2") { Scenarios.empty(.error(.noPhotos)) },
        CatalogueEntry("drag-target", "§2.4 S3") { Scenarios.empty(.targeted(.folder(name: "Finn und Lissy"))) },

        // Setup
        CatalogueEntry("preparing", "§2.4 S4") { Scenarios.setup(scan: .scanning(found: 212), estimates: .estimating) },
        CatalogueEntry("setup-ready", "§2.4 S4", extraSizes: [minimumSize]) { Scenarios.setup() },
        CatalogueEntry("setup-estimating", "§2.4 S4") { Scenarios.setup(estimates: .estimating) },
        CatalogueEntry("setup-warn-precompressed", "§2.4 S5") {
            Scenarios.setup(scanNotices: [.alreadyCompressed(count: 312, of: 535)])
        },
        CatalogueEntry("setup-blocked-disk", "§2.4 S5") {
            Scenarios.setup(preflightNotices: [.notEnoughSpace(volume: "Macintosh HD", needed: 1_900_000_000, available: 800_000_000)])
        },
        CatalogueEntry("setup-create-more", "§2.4 S4, §1.2 F3") { Scenarios.createMore() },
        CatalogueEntry("drop-on-setup", "§2.4 S3") {
            var scenario = Scenarios.setup()
            scenario.state.draft?.isDropTargeted = true
            scenario.state.dropZone = .targeted(.photos(count: 24))
            return scenario
        },
        CatalogueEntry("edit-delivery", "§2.4 S6") {
            var scenario = Scenarios.setup()
            scenario.state.sheet = .editDelivery(DeliveryPreset.builtIns[0], isNew: false)
            return scenario
        },

        // Job states
        CatalogueEntry("queued", "§2.4 S7") { Scenarios.queued() },
        CatalogueEntry("running-early", "§2.4 S8") { Scenarios.job(done: 6) },
        CatalogueEntry("running-mid", "§2.4 S8", extraSizes: [minimumSize]) { Scenarios.job(done: 312) },
        CatalogueEntry("paused-user", "§2.4 S9") { Scenarios.job(done: 312, phase: .paused(.user)) },
        CatalogueEntry("paused-drive", "§2.4 S9") { Scenarios.job(done: 312, phase: .paused(.sourceUnavailable(volume: "Wedding SSD"))) },
        CatalogueEntry("paused-disk", "§2.4 S9") {
            Scenarios.job(done: 312, phase: .paused(.diskFull(volume: "Macintosh HD", neededBytes: 600_000_000)))
        },
        CatalogueEntry("stopped", "§2.4 S9") { Scenarios.job(done: 312, phase: .stopped) },
        CatalogueEntry("interrupted", "§2.4 S9") { Scenarios.job(done: 312, phase: .interrupted) },

        // Results
        CatalogueEntry("done-single", "§2.4 S10") { Scenarios.done(Fixtures.only([.couple], of: Fixtures.finnUndLissy)) },
        CatalogueEntry("done-three", "§2.4 S10", extraSizes: [minimumSize]) {
            Scenarios.done(Fixtures.only([.couple, .website, .social], of: Fixtures.finnUndLissy))
        },
        CatalogueEntry("done-issues", "§2.4 S11") {
            Scenarios.done(Fixtures.withIssues(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy)))
        },
        CatalogueEntry("done-kept-original", "§2.4 S10") {
            Scenarios.done(Fixtures.only([.couple, .website], of: Fixtures.keptOriginal(7)))
        },
        CatalogueEntry("done-missing-folder", "§2.4 S12") {
            var scenario = Scenarios.done(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy))
            scenario.missingFolders = [Fixtures.finnUndLissy.outputFolder]
            return scenario
        },
        CatalogueEntry("failed", "§2.4 S13") { Scenarios.done(Fixtures.failed(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy))) },

        // Compare
        CatalogueEntry("compare-split-fit", "§2.4 S14", extraSizes: [minimumSize]) { Scenarios.compare() },
        CatalogueEntry("compare-split-100", "§2.4 S14") {
            Scenarios.compare { $0.zoom = .actual; $0.zoomCenter = CGPoint(x: 0.42, y: 0.38); $0.showsInspector = true }
        },
        CatalogueEntry("compare-side", "§2.4 S14") { Scenarios.compare { $0.mode = .sideBySide } },
        CatalogueEntry("compare-original-held", "§2.4 S14") { Scenarios.compare { $0.showsOriginal = true } },
        CatalogueEntry("compare-diff", "§2.4 S14") { Scenarios.compare { $0.showsDifferences = true } },
        CatalogueEntry("compare-no-original", "§2.4 S14") { Scenarios.compare(originalUnavailable: "Wedding SSD") { $0.originalAvailable = false } },
        CatalogueEntry("compare-spotcheck-toast", "§2.4 S14, §1.2 F2") { Scenarios.spotCheckToast() },

        // History
        CatalogueEntry("history-search", "§2.4 S15, §2.3") { Scenarios.historySearch("lissy") },
        CatalogueEntry("history-empty-search", "§2.4 S15") { Scenarios.historySearch("Amsterdam") },

        // Settings
        CatalogueEntry("settings-general", "§2.4 S16", surface: .settings) { Scenarios.settings(.general) },
        CatalogueEntry("settings-deliveries", "§2.4 S16", surface: .settings) { Scenarios.settings(.deliveries) },
        CatalogueEntry("settings-advanced", "§2.4 S16", surface: .settings) { Scenarios.settings(.advanced) },

        // Other surfaces
        CatalogueEntry("menubar-extra", "§2.4 S17", surface: .menuBar) {
            var scenario = Scenarios.job(done: 312)
            scenario.state.windowOpen = false
            return scenario
        },
        CatalogueEntry("alert-stop", "§2.4 S9, S18", surface: .alert(.stop(Fixtures.finnUndLissyID))) { Scenarios.job(done: 312) },
        CatalogueEntry("alert-quit", "§2.4 S18", surface: .alert(.quitWhileRunning(Fixtures.finnUndLissyID))) { Scenarios.job(done: 312) },
        CatalogueEntry("alert-remove", "§2.3, §2.4 S18", surface: .alert(.removeFromHistory(Fixtures.finnUndLissyID))) {
            Scenarios.done(Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy))
        },
    ]

    static func entry(_ id: String) -> CatalogueEntry? { entries.first { $0.id == id } }
}

/// Builders for the catalogue's states. Everything comes from `HMBFixtures`; nothing touches the file system.
enum Scenarios {
    static let finn = Fixtures.finnUndLissy
    static let coupleAndWebsite: [DeliveryID] = [.couple, .website]

    /// History without Finn und Lissy (used while Finn und Lissy is still being processed).
    static var historyWithoutFinn: [WeddingRecord] { Fixtures.history.filter { $0.id != Fixtures.finnUndLissyID } }

    /// History with `record` in Finn und Lissy's place (or appended), newest wedding first.
    static func history(replacingWith record: WeddingRecord) -> [WeddingRecord] {
        (historyWithoutFinn + [record]).sorted { ($0.weddingDate ?? .distantPast) > ($1.weddingDate ?? .distantPast) }
    }

    static func baseState() -> AppState {
        var state = AppState()
        state.presets = DeliveryPreset.builtIns
        state.defaultOn = DeliveryPreset.defaultOnIDs
        return state
    }

    // MARK: Empty and setup

    /// First launch: empty history, sidebar hidden (`.detailOnly`), the drop zone in `zone`.
    static func empty(_ zone: DropZoneState = .idle) -> SnapshotScenario {
        var state = baseState()
        state.dropZone = zone
        return SnapshotScenario(state: state)
    }

    enum EstimateMode { case ready, estimating }

    static func setup(scan: ScanState? = nil, estimates: EstimateMode = .ready, scanNotices: [ScanNotice] = [],
                      preflightNotices: [ScanNotice] = []) -> SnapshotScenario {
        var state = baseState()
        var result = Fixtures.scanResult
        result.notices = scanNotices
        let enabled = Dictionary(uniqueKeysWithValues: DeliveryPreset.builtIns.map { ($0.id, DeliveryPreset.defaultOnIDs.contains($0.id)) })
        let estimateStates: [DeliveryID: EstimateState] = Dictionary(uniqueKeysWithValues: DeliveryPreset.builtIns.map { preset in
            switch estimates {
            case .estimating: (preset.id, EstimateState.estimating)
            case .ready: (preset.id, Fixtures.estimates[preset.id].map(EstimateState.ready) ?? .unavailable)
            }
        })
        let output = finn.outputFolder
        let estimatedBytes = estimates == .ready
            ? coupleAndWebsite.compactMap { Fixtures.estimates[$0]?.bytes }.reduce(0, +) : nil
        state.draft = SetupDraft(
            wedding: FixtureFactory.weddingID(90), name: "Finn und Lissy", scan: scan ?? .ready(result), enabled: enabled,
            estimates: estimateStates, naming: .default,
            preflight: Preflight(outputFolder: output, estimatedBytes: estimatedBytes, notices: preflightNotices))
        state.selection = .newWedding
        return SnapshotScenario(state: state, engine: FixtureEngine.Configuration(scanResult: result, preflightNotices: preflightNotices))
    }

    /// F3: Create More Deliveries for Finn und Lissy, whose Couple’s Package and Website were made on July 14.
    static func createMore() -> SnapshotScenario {
        let record = Fixtures.only(coupleAndWebsite, of: finn)
        var scenario = setup()
        let completedAt = record.finishedAt ?? FixtureFactory.date(2026, 7, 14)
        scenario.state.records = history(replacingWith: record)
        scenario.state.sidebarVisible = true
        scenario.state.selection = .wedding(record.id)          // Create More reopens setup in the wedding's own row
        scenario.state.draft?.wedding = record.id
        scenario.state.draft?.existingWedding = record.id
        scenario.state.draft?.completedDeliveries = [.couple: completedAt, .website: completedAt]
        scenario.state.draft?.enabled[.archive] = true
        scenario.state.draft?.preflight = Preflight(outputFolder: record.outputFolder,
                                                     estimatedBytes: Fixtures.estimates[.archive]?.bytes, notices: [])
        return scenario
    }

    // MARK: Jobs

    /// Finn und Lissy (Couple’s Package + Website) with `done` photos finished, in `phase`; history in the sidebar.
    static func job(done: Int, phase: JobPhase = .running) -> SnapshotScenario {
        var state = baseState()
        let (record, progress) = Fixtures.inProgress(Fixtures.only(coupleAndWebsite, of: finn), done: done, phase: phase)
        state.records = [record] + historyWithoutFinn
        state.live = [record.id: progress]
        switch phase {
        case .running, .paused: state.queue = [record.id]
        default: state.queue = []
        }
        state.selection = .wedding(record.id)
        state.sidebarVisible = true
        state.gridDelivery = .couple
        return SnapshotScenario(state: state)
    }

    /// Anna und Ben waits behind the running Finn und Lissy.
    static func queued() -> SnapshotScenario {
        var scenario = job(done: 312)
        let anna = Fixtures.annaUndBen
        scenario.state.records.insert(anna, at: 1)
        scenario.state.queue = [Fixtures.finnUndLissyID, anna.id]
        scenario.state.selection = .wedding(anna.id)
        return scenario
    }

    // MARK: Results

    static func done(_ record: WeddingRecord) -> SnapshotScenario {
        var state = baseState()
        state.records = history(replacingWith: record)
        state.selection = .wedding(record.id)
        state.sidebarVisible = true
        state.gridDelivery = record.deliveries.first { $0.isLossy }?.id ?? record.deliveries.first?.id
        return SnapshotScenario(state: state)
    }

    // MARK: Compare

    static let compareStart = PhotoID(41)

    static func compare(originalUnavailable: String? = nil, _ adjust: (inout CompareState) -> Void = { _ in }) -> SnapshotScenario {
        let record = Fixtures.only(coupleAndWebsite, of: finn)
        var scenario = done(record)
        let route = CompareRoute(wedding: record.id, delivery: .couple, start: compareStart, spotCheck: false)
        var compare = CompareState(route: route, order: .captureTime, sequence: record.photos.map(\.id), position: compareStart.index)
        adjust(&compare)
        scenario.state.detailPath = [route]
        scenario.state.compare = compare
        scenario.engine = FixtureEngine.Configuration(compareUnavailableVolume: originalUnavailable)
        return scenario
    }

    /// F2: the 12th hardest photo was just reached; the one-time toast shows.
    static func spotCheckToast() -> SnapshotScenario {
        let record = Fixtures.only(coupleAndWebsite, of: finn)
        var scenario = done(record)
        let lowest = record.results
            .filter { $0.delivery == .couple && $0.status == .done }
            .sorted { ($0.score ?? 0, $0.photo.index) < ($1.score ?? 0, $1.photo.index) }
            .map(\.photo)
        let k = min(12, max(5, Int((0.03 * Double(record.photos.count)).rounded(.up))))
        let route = CompareRoute(wedding: record.id, delivery: .couple, start: lowest[0], spotCheck: true)
        var compare = CompareState(route: route, order: .lowestScore, sequence: lowest, position: k - 1)
        compare.spotCheckToastShown = true
        scenario.state.detailPath = [route]
        scenario.state.compare = compare
        scenario.state.toast = "You’ve checked the \(k) hardest photos. Everything else scored higher."
        return scenario
    }

    // MARK: History and settings

    static func historySearch(_ text: String) -> SnapshotScenario {
        var scenario = done(finn)
        scenario.state.search = text
        return scenario
    }

    static func settings(_ tab: SettingsTab) -> SnapshotScenario {
        var state = baseState()
        state.records = Fixtures.history
        state.settingsTab = tab
        return SnapshotScenario(state: state)
    }
}
