// The app model (Docs/SPEC.md §5.0.3). WP3 owns this file: drop → setup → queue → run → done, history, the queue,
// persistence, volumes, the Dock and the transient status item. WP4 adds Compare and Settings in its extensions.
// Contract: `init` has no side effects (it never calls `bootstrap`), so any view can be rendered from
// `AppModel(state:…)` with fixtures — the snapshot harness relies on this.
import SwiftUI
import HMBModel

@MainActor @Observable
public final class AppModel {
    public var state: AppState
    public let engine: any EngineService
    public let history: any HistoryStoring
    public let presetsStore: any PresetStoring
    public let settingsStore: any SettingsStoring
    public let thumbnails: any ThumbnailProviding

    /// System side effects. `.inert` by default; the app installs `.system` plus its Dock and notification hooks.
    @ObservationIgnored public var platform: AppPlatform = .inert

    // MARK: Observable working state (not part of the frozen AppState)

    /// Setup notices the user dismissed with "Continue Anyway".
    public private(set) var acknowledgedNotices: Set<ScanNotice> = []
    /// "Compress Photos" was pressed while the scan was still running: the job starts when the scan ends.
    public private(set) var startPending = false
    /// Finished weddings whose delivery folder is gone (S12).
    public private(set) var missingFolders: Set<WeddingID> = []
    /// Names of the mounted volumes (enables Resume after a drive came back).
    public private(set) var mountedVolumes: Set<String> = []
    /// The user removed the transient status item from the menu bar for the current job.
    private var statusItemDismissed = false
    /// Incremented by Edit ▸ Find (⌘F); the root view focuses the sidebar search field.
    public private(set) var searchFocusRequest = 0

    // MARK: Plumbing

    @ObservationIgnored private var draftItems: [URL] = []
    @ObservationIgnored private var draftNameEdited = false
    @ObservationIgnored private var draftOutputBase: URL?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var estimateTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var preflightTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var dropErrorTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var runTasks: [WeddingID: Task<Void, Never>] = [:]
    @ObservationIgnored private var requests: [WeddingID: JobRequest] = [:]
    @ObservationIgnored private var retryQueue: [WeddingID: [JobRequest]] = [:]
    @ObservationIgnored private var retryContinues: Set<WeddingID> = []
    @ObservationIgnored private var activeRequest: [WeddingID: JobRequest] = [:]
    @ObservationIgnored private var resultIndex: [WeddingID: [ResultKey: Int]] = [:]
    @ObservationIgnored private var createMoreBackup: [WeddingID: WeddingRecord] = [:]
    @ObservationIgnored private var resumeWhenReachingHead: Set<WeddingID> = []
    @ObservationIgnored private var startNowTarget: WeddingID?
    @ObservationIgnored private var runStartedAt: [WeddingID: Date] = [:]
    @ObservationIgnored private var lastSaved: [WeddingID: Date] = [:]
    @ObservationIgnored private var announcedDecile: [WeddingID: Int] = [:]
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var observingVolumes = false

    static let sidebarDefaultsKey = "sidebarVisible"
    /// Records are saved on every phase change and at least this often while running (§5.3).
    static let saveInterval: TimeInterval = 5
    /// Edits to the name or the location are preflighted after this pause.
    static let preflightDebounce: Duration = .milliseconds(250)

    public init(state: AppState, engine: any EngineService, history: any HistoryStoring,
                presetsStore: any PresetStoring, settingsStore: any SettingsStoring, thumbnails: any ThumbnailProviding) {
        self.state = state
        self.engine = engine
        self.history = history
        self.presetsStore = presetsStore
        self.settingsStore = settingsStore
        self.thumbnails = thumbnails
    }

    // MARK: - Bootstrap

    /// Loads presets, settings and history; jobs with a journal but no finished marker become Interrupted (a job the
    /// user paused or stopped keeps that state); queued weddings are queued again and the queue starts.
    public func bootstrap() async {
        let loaded = presetsStore.load()
        state.presets = loaded.presets
        state.defaultOn = loaded.defaultOn
        state.settings = settingsStore.load()

        var records = (try? await history.loadAll()) ?? []
        let unfinished = await engine.unfinishedJobs()
        var changed = Set<WeddingID>()
        for job in unfinished {
            let id = job.request.wedding
            requests[id] = job.request
            changed.insert(id)
            if let i = records.firstIndex(where: { $0.id == id }) {
                var record = records[i]
                record.results = Self.merged(record.results, job.results)
                switch record.phase {
                case .paused, .stopped: break
                default: record.phase = .interrupted
                }
                records[i] = record
            } else {
                records.append(Self.record(from: job, now: platform.now()))
            }
        }
        for i in records.indices where records[i].phase == .running {
            records[i].phase = .interrupted                  // it ran, but the engine has no journal for it
            changed.insert(records[i].id)
        }
        state.records = records
        for record in records { rebuildIndex(record.id) }
        state.queue = records.filter { if case .queued = $0.phase { true } else { false } }
            .sorted { $0.createdAt < $1.createdAt }.map(\.id)
        updateQueuePositions()

        if platform.defaults.object(forKey: Self.sidebarDefaultsKey) != nil {
            state.sidebarVisible = platform.defaults.bool(forKey: Self.sidebarDefaultsKey)
        } else {
            state.sidebarVisible = !records.isEmpty
        }

        volumesChanged()
        if !observingVolumes {
            observingVolumes = true
            platform.observeVolumes { [weak self] in self?.volumesChanged() }
        }
        for id in changed { persist(id) }
        advanceQueue()
        updateDock()
    }

    static func record(from job: UnfinishedJob, now: Date) -> WeddingRecord {
        let request = job.request
        return WeddingRecord(
            id: request.wedding, name: request.name, createdAt: now, weddingDate: request.photos.compactMap(\.captureDate).min(),
            camera: request.photos.first?.camera, sourceRoots: request.sourceRoots, sourceBookmarks: [],
            photos: request.photos, deliveries: request.deliveries, deliveryCompletedAt: [:],
            outputFolder: request.outputFolder, outputBookmark: nil, naming: request.naming, phase: .interrupted,
            results: job.results, startedAt: now, finishedAt: nil, activeSeconds: 0, viewed: false)
    }

    // MARK: - Drop and choose

    /// Opens setup for the dropped items (or adds them to the setup on screen). Returns false for an empty drop.
    @discardableResult
    public func handleDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        dropErrorTask?.cancel()
        state.dropZone = .idle
        if var draft = state.draft, draft.existingWedding == nil, state.selection == .newWedding {
            // Over Setup: "Add to this wedding".
            draft.isDropTargeted = false
            let known = Set(draftItems.map(\.standardizedFileURL))
            draftItems += urls.filter { !known.contains($0.standardizedFileURL) }
            draft.scan = .scanning(found: 0)
            draft.estimates = [:]
            draft.preflight = nil
            state.draft = draft
            startScan()
            return true
        }
        newDraft(urls)
        return true
    }

    public func setDropTargeted(_ targeted: Bool, summary: DragSummary?) {
        if targeted { dropErrorTask?.cancel() }
        if state.selection == .newWedding, state.draft != nil, state.draft?.existingWedding == nil {
            state.draft?.isDropTargeted = targeted
            if !targeted { state.dropZone = .idle }
            return
        }
        if targeted {
            state.dropZone = .targeted(summary ?? .items(count: 1))
        } else if case .targeted = state.dropZone {
            state.dropZone = .idle
        }
    }

    public func choosePhotos() {
        guard let urls = platform.chooseItems(), !urls.isEmpty else { return }
        handleDrop(urls)
    }

    /// The drag summary for the drag-target title (S3): one folder, files only, or a mix.
    public func dragSummary(for urls: [URL]) -> DragSummary {
        let folders = urls.filter { platform.isDirectory($0) }
        if urls.count == 1, let folder = folders.first {
            return .folder(name: WeddingNaming.suggestedName(for: [folder]))
        }
        if folders.isEmpty { return .photos(count: urls.count) }
        return .items(count: urls.count)
    }

    private func newDraft(_ urls: [URL]) {
        cancelDraftWork()
        if state.compare != nil { closeCompare() }
        state.detailPath = []
        draftItems = urls
        draftNameEdited = false
        draftOutputBase = nil
        acknowledgedNotices = []
        startPending = false
        let folders = urls.map { platform.isDirectory($0) ? $0 : $0.deletingLastPathComponent() }
        state.draft = SetupDraft(name: WeddingNaming.suggestedName(for: folders), scan: .scanning(found: 0),
                                 enabled: Dictionary(uniqueKeysWithValues: state.presets.map { ($0.id, state.defaultOn.contains($0.id)) }),
                                 naming: state.settings.naming)
        state.selection = .newWedding
        startScan()
    }

    private func cancelDraftWork() {
        scanTask?.cancel(); scanTask = nil
        estimateTasks.forEach { $0.cancel() }; estimateTasks = []
        preflightTask?.cancel(); preflightTask = nil
        startTask?.cancel(); startTask = nil
    }

    private func startScan() {
        scanTask?.cancel()
        estimateTasks.forEach { $0.cancel() }; estimateTasks = []
        guard let draftID = state.draft?.wedding else { return }
        let stream = engine.scan(draftItems)
        scanTask = Task { [weak self] in
            do {
                for try await update in stream {
                    guard let self, self.state.draft?.wedding == draftID else { return }
                    switch update {
                    case .progress(let found): self.state.draft?.scan = .scanning(found: found)
                    case .finished(let result): self.scanFinished(result)
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.state.draft?.wedding == draftID else { return }
                self.showDropError(.noPhotos)
            }
        }
    }

    private func scanFinished(_ result: ScanResult) {
        guard state.draft != nil else { return }
        if result.photos.isEmpty {
            let name = state.draft?.name ?? result.suggestedName
            showDropError(result.rawCount > 0 ? .onlyRaw(folderName: name, count: result.rawCount) : .noPhotos)
            return
        }
        state.draft?.scan = .ready(result)
        if !draftNameEdited { state.draft?.name = result.suggestedName }
        requestEstimates(nil)
        schedulePreflight(after: .zero)
        if startPending { startDraft() }
    }

    private func showDropError(_ error: DropError) {
        cancelDraftWork()
        startPending = false
        state.draft = nil
        state.selection = .newWedding
        state.dropZone = .error(error)
        dropErrorTask?.cancel()
        dropErrorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Copy.DropError.resetAfter))
            guard let self, !Task.isCancelled, case .error = self.state.dropZone else { return }
            self.state.dropZone = .idle
        }
    }

    // MARK: - Setup

    /// The presets shown as rows: the library order, plus deliveries of the existing wedding that are no longer in it.
    public var draftPresets: [DeliveryPreset] {
        guard let existing = state.draft?.existingWedding, let record = record(existing) else { return state.presets }
        var presets = state.presets.map { preset in
            record.deliveryCompletedAt[preset.id.rawValue] != nil ? (record.deliveries.first { $0.id == preset.id } ?? preset) : preset
        }
        let known = Set(presets.map(\.id))
        presets += record.deliveries.filter { !known.contains($0.id) }
        return presets
    }

    /// Checked deliveries that will be made (completed ones excluded).
    public var draftSelectedPresets: [DeliveryPreset] {
        guard let draft = state.draft else { return [] }
        return draftPresets.filter { draft.enabled[$0.id] == true && draft.completedDeliveries[$0.id] == nil }
    }

    /// Scan notices and preflight notices, without the dismissed ones (and without "folder exists" in Create More).
    public var draftNotices: [ScanNotice] {
        guard let draft = state.draft else { return [] }
        var notices: [ScanNotice] = []
        if case .ready(let result) = draft.scan { notices += result.notices }
        notices += draft.preflight?.notices ?? []
        var seen = Set<ScanNotice>()
        return notices.filter { notice in
            if draft.existingWedding != nil, case .outputFolderExists = notice { return false }
            return !acknowledgedNotices.contains(notice) && seen.insert(notice).inserted
        }
    }

    public var draftIsBlocked: Bool { draftNotices.contains { $0.severity == .block } }
    public var draftCanStart: Bool { !draftSelectedPresets.isEmpty && !draftIsBlocked }

    /// The folder the deliveries go to: the preflight's answer, else the requested one.
    public var draftOutputFolder: URL? {
        if let folder = state.draft?.preflight?.outputFolder { return folder }
        return requestedOutputFolder()
    }

    /// Σ estimates over the selected deliveries; nil until all of them are known.
    public var draftEstimatedBytes: Int64? {
        guard let draft = state.draft, !draftSelectedPresets.isEmpty else { return nil }
        var total: Int64 = 0
        for preset in draftSelectedPresets {
            guard case .ready(let estimate) = draft.estimates[preset.id] else { return nil }
            total += estimate.bytes
        }
        return total
    }

    /// Wall time estimate: Σ seconds per photo over the selected deliveries × photos.
    public var draftEstimatedSeconds: Double? {
        guard let draft = state.draft, case .ready(let result) = draft.scan else { return nil }
        var perPhoto = 0.0
        for preset in draftSelectedPresets {
            guard case .ready(let estimate) = draft.estimates[preset.id] else { return nil }
            perPhoto += estimate.secondsPerPhoto
        }
        return perPhoto * Double(result.photos.count)
    }

    public func toggleDelivery(_ id: DeliveryID) {
        guard var draft = state.draft, draft.completedDeliveries[id] == nil else { return }
        let on = !(draft.enabled[id] ?? false)
        draft.enabled[id] = on
        state.draft = draft
        if on {
            switch draft.estimates[id] {
            case nil, .unavailable?: requestEstimates([id])
            default: break
            }
        }
        schedulePreflight(after: Self.preflightDebounce)
    }

    /// ⌘1…⌘9 (1-based row).
    public func toggleDelivery(atRow row: Int) {
        let presets = draftPresets
        guard row >= 1, row <= presets.count else { return }
        toggleDelivery(presets[row - 1].id)
    }

    public func renameDraft(_ name: String) {
        guard state.draft != nil, state.draft?.name != name else { return }
        state.draft?.name = name
        draftNameEdited = true
        if state.draft?.existingWedding == nil { schedulePreflight(after: Self.preflightDebounce) }
    }

    public func setDraftRenaming(_ on: Bool) {
        state.draft?.naming.renameByCaptureTime = on
    }

    public func chooseOutputFolder() {
        guard let draft = state.draft, draft.existingWedding == nil else { return }
        let start = draftOutputFolder?.deletingLastPathComponent()
        guard let folder = platform.chooseFolder("Choose", start) else { return }
        draftOutputBase = folder
        state.draft?.preflight = nil
        schedulePreflight(after: .zero)
    }

    /// "Continue Anyway" on a warning.
    public func acknowledge(_ notice: ScanNotice) {
        acknowledgedNotices.insert(notice)
    }

    /// "Use Archive Only" on the already-compressed warning.
    public func useArchiveOnly(_ notice: ScanNotice) {
        guard var draft = state.draft else { return }
        for preset in draftPresets where draft.completedDeliveries[preset.id] == nil {
            draft.enabled[preset.id] = preset.format == .jxlLossless
        }
        state.draft = draft
        acknowledgedNotices.insert(notice)
        if let archive = draftPresets.first(where: { $0.format == .jxlLossless }), draft.estimates[archive.id] == nil {
            requestEstimates([archive.id])
        }
        schedulePreflight(after: .zero)
    }

    public func cancelSetup() {
        cancelDraftWork()
        startPending = false
        state.draft = nil
        state.dropZone = .idle
    }

    /// Return / ⌘↩ in setup: queues the wedding (or starts it when nothing runs). While the scan still runs, the
    /// wedding starts as soon as it ends.
    public func startDraft() {
        guard let draft = state.draft, draftCanStart else { return }
        guard case .ready(let scan) = draft.scan else {
            startPending = true
            return
        }
        startPending = false
        if let preflight = draft.preflight {
            commit(draft, scan: scan, preflight: preflight)
            return
        }
        let request = draftRequest(draft, scan: scan)
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            let preflight = await self.engine.preflight(request)
            guard !Task.isCancelled, self.state.draft?.wedding == draft.wedding else { return }
            self.state.draft?.preflight = preflight
            if let current = self.state.draft, self.draftCanStart { self.commit(current, scan: scan, preflight: preflight) }
        }
    }

    private func requestEstimates(_ only: [DeliveryID]?) {
        guard let draft = state.draft, case .ready(let scan) = draft.scan else { return }
        let presets = draftPresets.filter { preset in
            draft.completedDeliveries[preset.id] == nil
                && (only?.contains(preset.id) ?? (draft.enabled[preset.id] == true))
        }
        guard !presets.isEmpty else { return }
        for preset in presets { state.draft?.estimates[preset.id] = .estimating }
        let draftID = draft.wedding
        let engine = engine
        let task = Task { [weak self] in
            let result = try? await engine.estimate(photos: scan.photos, deliveries: presets)
            guard let self, !Task.isCancelled, self.state.draft?.wedding == draftID else { return }
            for preset in presets {
                self.state.draft?.estimates[preset.id] = result?[preset.id].map(EstimateState.ready) ?? .unavailable
            }
            self.schedulePreflight(after: .zero)
        }
        estimateTasks.append(task)
    }

    private func requestedOutputFolder() -> URL? {
        guard let draft = state.draft else { return nil }
        if let existing = draft.existingWedding, let record = record(existing) { return record.outputFolder }
        guard case .ready(let scan) = draft.scan,
              let root = scan.sourceRoots.first ?? scan.photos.first?.url.deletingLastPathComponent() else { return nil }
        let base: URL
        if let chosen = draftOutputBase {
            base = chosen
        } else if case .folder(let folder) = state.settings.saveLocation {
            base = folder
        } else {
            base = root.deletingLastPathComponent()
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = HMBFormat.folderName(pattern: state.settings.folderNamePattern,
                                              wedding: name.isEmpty ? scan.suggestedName : name, date: scan.weddingDate)
        return base.appending(path: folderName, directoryHint: .isDirectory)
    }

    private func draftRequest(_ draft: SetupDraft, scan: ScanResult) -> JobRequest {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return JobRequest(wedding: draft.wedding, name: name.isEmpty ? scan.suggestedName : name, photos: scan.photos,
                          sourceRoots: scan.sourceRoots, deliveries: draftSelectedPresets,
                          outputFolder: requestedOutputFolder() ?? scan.sourceRoots.first ?? URL(fileURLWithPath: "/"),
                          naming: draft.naming, processorUse: state.settings.processorUse,
                          appendToExistingFolder: draft.existingWedding != nil)
    }

    private func schedulePreflight(after delay: Duration) {
        guard let draft = state.draft, case .ready(let scan) = draft.scan else { return }
        preflightTask?.cancel()
        let draftID = draft.wedding
        preflightTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, let current = self.state.draft, current.wedding == draftID else { return }
            var request = self.draftRequest(current, scan: scan)
            if request.deliveries.isEmpty { request.deliveries = self.draftPresets.filter { current.enabled[$0.id] == true } }
            let preflight = await self.engine.preflight(request)
            guard !Task.isCancelled, self.state.draft?.wedding == draftID else { return }
            self.state.draft?.preflight = preflight
        }
    }

    private func commit(_ draft: SetupDraft, scan: ScanResult, preflight: Preflight) {
        let presets = draftSelectedPresets
        guard !presets.isEmpty else { return }
        cancelDraftWork()
        let now = platform.now()
        let id = draft.wedding
        var request = draftRequest(draft, scan: scan)
        request.outputFolder = preflight.outputFolder
        request.deliveries = presets

        if let existingID = draft.existingWedding, var record = record(existingID) {
            createMoreBackup[existingID] = record
            let newIDs = Set(presets.map(\.id))
            record.deliveries = record.deliveries.filter { !newIDs.contains($0.id) } + presets
            record.results.removeAll { newIDs.contains($0.delivery) }
            record.phase = .queued(position: state.queue.count)
            record.viewed = false
            request.outputFolder = record.outputFolder
            request.appendToExistingFolder = true
            request.name = record.name
            replace(record)
            rebuildIndex(existingID)
        } else {
            let record = WeddingRecord(
                id: id, name: request.name, createdAt: now, weddingDate: scan.weddingDate, camera: scan.camera,
                sourceRoots: scan.sourceRoots, sourceBookmarks: scan.sourceRoots.compactMap { try? $0.bookmarkData() },
                photos: scan.photos, deliveries: presets, deliveryCompletedAt: [:], outputFolder: preflight.outputFolder,
                outputBookmark: nil, naming: draft.naming, phase: .queued(position: state.queue.count), results: [],
                startedAt: nil, finishedAt: nil, activeSeconds: 0, viewed: false)
            state.records.insert(record, at: 0)
            resultIndex[id] = [:]
            rememberDefaultDeliveries(draft)
        }
        requests[id] = request
        state.queue.append(id)
        updateQueuePositions()
        state.draft = nil
        state.dropZone = .idle
        state.selection = .wedding(id)
        if !state.sidebarVisible, platform.defaults.object(forKey: Self.sidebarDefaultsKey) == nil {
            state.sidebarVisible = true                       // the sidebar animates in when the first job starts
            platform.defaults.set(true, forKey: Self.sidebarDefaultsKey)
        }
        persist(id)
        advanceQueue()
    }

    /// The deliveries checked for a new wedding become the remembered default set (principle 2).
    private func rememberDefaultDeliveries(_ draft: SetupDraft) {
        for preset in state.presets {
            let on = draft.enabled[preset.id] == true
            if on != state.defaultOn.contains(preset.id) { setDefaultOn(preset.id, on) }
        }
    }

    // MARK: - Queue and job control

    /// The wedding that owns the engine right now.
    public var runningID: WeddingID? {
        guard let head = state.queue.first, let record = record(head), record.phase == .running else { return nil }
        return head
    }

    public var isRunning: Bool { runningID != nil }

    private func updateQueuePositions() {
        for (position, id) in state.queue.enumerated() {
            guard let i = index(id), case .queued = state.records[i].phase else { continue }
            state.records[i].phase = .queued(position: position)
        }
    }

    /// Starts the head of the queue when nothing runs. A paused head blocks the queue (pause means pause), unless it
    /// was paused by "Start Now Instead", in which case it resumes when it is back at the head.
    private func advanceQueue() {
        guard !quitting, let head = state.queue.first, runTasks[head] == nil, let record = record(head) else { return }
        switch record.phase {
        case .queued:
            start(head)
        case .paused where resumeWhenReachingHead.contains(head):
            resumeWhenReachingHead.remove(head)
            start(head)
        case .paused:
            return
        default:
            state.queue.removeFirst()
            updateQueuePositions()
            advanceQueue()
        }
    }

    private func jobRequest(for record: WeddingRecord) -> JobRequest {
        if let request = requests[record.id] { return request }
        let pending = record.deliveries.filter { record.deliveryCompletedAt[$0.id.rawValue] == nil }
        let request = JobRequest(wedding: record.id, name: record.name, photos: record.photos, sourceRoots: record.sourceRoots,
                                 deliveries: pending.isEmpty ? record.deliveries : pending, outputFolder: record.outputFolder,
                                 naming: record.naming, processorUse: state.settings.processorUse,
                                 appendToExistingFolder: !record.deliveryCompletedAt.isEmpty)
        requests[record.id] = request
        return request
    }

    private func start(_ id: WeddingID) {
        guard runTasks[id] == nil, let record = record(id) else { return }
        let request: JobRequest
        let resume: Bool
        if let retry = retryQueue[id]?.first {
            request = retry
            resume = false
        } else {
            request = jobRequest(for: record)
            resume = record.startedAt != nil
        }
        activeRequest[id] = request
        statusItemDismissed = false
        if let i = index(id) { state.records[i].phase = .running }
        let stream = engine.run(request, resume: resume)
        runTasks[id] = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
            self?.runEnded(id)
        }
        updateDock()
    }

    private func apply(_ event: EngineEvent) {
        switch event {
        case .phase(let id, let phase): applyPhase(phase, to: id)
        case .results(let id, let results): merge(results, into: id)
        case .progress(let progress): applyProgress(progress)
        }
    }

    private func applyPhase(_ phase: JobPhase, to id: WeddingID) {
        guard let i = index(id) else { return }
        let now = platform.now()
        var record = state.records[i]
        if phase == .finished, var batch = retryQueue[id], !batch.isEmpty {
            // One retry batch finished; the next one starts in `runEnded`, the job stays running.
            batch.removeFirst()
            if !batch.isEmpty {
                retryQueue[id] = batch
                retryContinues.insert(id)
                return
            }
            retryQueue[id] = nil
        } else if phase == .finished {
            for preset in activeRequest[id]?.deliveries ?? record.deliveries {
                record.deliveryCompletedAt[preset.id.rawValue] = now
            }
        }
        if let started = runStartedAt[id], phase != .running {
            record.activeSeconds += now.timeIntervalSince(started)
            runStartedAt[id] = nil
        }
        switch phase {
        case .running:
            record.startedAt = record.startedAt ?? now
            runStartedAt[id] = now
        case .finished:
            record.finishedAt = now
            record.viewed = state.windowOpen && state.selection == .wedding(id)
        case .paused(let reason):
            if case .sourceUnavailable(let volume) = reason, state.settings.notifyWhenFinished {
                platform.post(.pausedByDrive(id, Copy.Notification.pausedByDrive(volume: volume)))
            }
            platform.announce(Copy.Announcement.paused(record.name))
        default:
            break
        }
        record.phase = phase
        state.records[i] = record
        if phase == .finished {
            state.live[id] = nil
            createMoreBackup[id] = nil
            requests[id] = nil
            announcedDecile[id] = nil
            if state.settings.notifyWhenFinished || state.settings.playSound {
                var text = Copy.Notification.finished(record)
                if !state.settings.notifyWhenFinished { text.body = nil }
                platform.post(.finished(id, text, playSound: state.settings.playSound))
            }
            platform.announce(Copy.Announcement.finished(record.name))
            refreshMissingFolder(id)
        }
        persist(id)
        updateDock()
    }

    private func merge(_ results: [PhotoResult], into id: WeddingID) {
        guard let i = index(id) else { return }
        var index = resultIndex[id] ?? [:]
        var all = state.records[i].results
        for result in results {
            let key = ResultKey(photo: result.photo, delivery: result.delivery)
            if let at = index[key] { all[at] = result } else { index[key] = all.count; all.append(result) }
        }
        state.records[i].results = all
        resultIndex[id] = index
        persistIfDue(id)
    }

    private func applyProgress(_ progress: JobProgress) {
        let id = progress.wedding
        state.live[id] = progress
        let decile = Int(progress.fraction * 10)
        if decile > (announcedDecile[id] ?? 0), decile < 10, let record = record(id) {
            announcedDecile[id] = decile
            platform.announce(Copy.Announcement.progress(decile * 10, name: record.name))
        }
        persistIfDue(id)
        updateDock()
    }

    private func runEnded(_ id: WeddingID) {
        runTasks[id] = nil
        activeRequest[id] = nil
        guard let i = index(id) else { advanceQueue(); return }
        if retryContinues.remove(id) != nil, !quitting {
            start(id)
            return
        }
        if state.records[i].phase == .running {
            // The stream ended without a final phase: treat it like a crash of the job.
            applyPhase(.interrupted, to: id)
        }
        if quitting { return }
        switch state.records[i].phase {
        case .paused:
            if let target = startNowTarget {
                startNowTarget = nil
                state.queue.removeAll { $0 == target }
                state.queue.insert(target, at: 0)
                updateQueuePositions()
            }
        case .queued:
            break           // re-queued (Try Again, Create More) between the final phase and the end of the stream
        default:
            state.queue.removeAll { $0 == id }
            updateQueuePositions()
            if state.records[i].phase == .finished { Task { await engine.discardJournal(id) } }
        }
        advanceQueue()
        updateDock()
    }

    public func pause(_ id: WeddingID) {
        guard runTasks[id] != nil else { return }
        Task { await engine.pause(id) }
    }

    /// Resumes a paused, stopped or interrupted wedding: now if nothing runs, else at the end of the queue.
    public func resume(_ id: WeddingID) {
        guard let record = record(id), canResume(record) else { return }
        if runTasks.isEmpty {
            state.queue.removeAll { $0 == id }
            state.queue.insert(id, at: 0)
            updateQueuePositions()
            start(id)
        } else {
            state.queue.removeAll { $0 == id }
            state.queue.append(id)
            if let i = index(id) { state.records[i].phase = .queued(position: state.queue.count - 1) }
            updateQueuePositions()
            persist(id)
        }
        updateDock()
    }

    /// Resume is possible unless the source drive is still missing.
    public func canResume(_ record: WeddingRecord) -> Bool {
        switch record.phase {
        case .paused(.sourceUnavailable(let volume)): mountedVolumes.contains(volume)
        case .paused, .stopped, .interrupted: true
        default: false
        }
    }

    /// ⌥⌘P and the menu-bar extra: pause the running job, or resume the selected one.
    public func togglePause(_ id: WeddingID) {
        guard let record = record(id) else { return }
        if record.phase == .running { pause(id) } else { resume(id) }
    }

    public func requestStop(_ id: WeddingID) {
        guard let record = record(id) else { return }
        switch record.phase {
        case .running, .paused, .interrupted: state.alert = .stop(id)
        default: return
        }
    }

    /// "Stop Here" on the Interrupted banner: nothing is running, so no alert is needed.
    public func stopHere(_ id: WeddingID) {
        guard let record = record(id), record.phase == .interrupted else { return }
        finishStop(id)
    }

    private func finishStop(_ id: WeddingID) {
        if runTasks[id] != nil {
            Task { await engine.stop(id) }
            return
        }
        guard let i = index(id) else { return }
        state.records[i].phase = .stopped
        resumeWhenReachingHead.remove(id)
        state.queue.removeAll { $0 == id }
        updateQueuePositions()
        persist(id)
        advanceQueue()
        updateDock()
    }

    public func confirmAlert() {
        guard let alert = state.alert else { return }
        state.alert = nil
        switch alert {
        case .stop(let id): finishStop(id)
        case .quitWhileRunning(let id): quit(stopping: id)
        case .removeFromHistory(let id): removeFromHistory(id)
        case .clearHistory: clearHistory()
        }
    }

    public func dismissAlert() {
        guard let alert = state.alert else { return }
        state.alert = nil
        if case .quitWhileRunning = alert { platform.replyToTerminate(false) }
    }

    public func removeFromQueue(_ id: WeddingID) {
        guard let record = record(id), case .queued = record.phase else { return }
        state.queue.removeAll { $0 == id }
        requests[id] = nil
        retryQueue[id] = nil
        if let backup = createMoreBackup.removeValue(forKey: id) {
            replace(backup)
            rebuildIndex(id)
            persist(id)
        } else if record.startedAt != nil {
            // It had run before (resumed or retried into the queue): its work stays; it goes back to stopped.
            if let i = index(id) { state.records[i].phase = record.finishedAt != nil ? .finished : .stopped }
            persist(id)
        } else {
            state.records.removeAll { $0.id == id }
            resultIndex[id] = nil
            Task { [history] in try? await history.remove(id) }
            if state.selection == .wedding(id) { state.selection = .newWedding }
        }
        updateQueuePositions()
        advanceQueue()
        updateDock()
    }

    /// "Start Now Instead": pauses the running job (it resumes once this one is done) and starts this one.
    public func startNow(_ id: WeddingID) {
        guard let record = record(id), case .queued = record.phase else { return }
        if let running = runningID, running != id {
            startNowTarget = id
            resumeWhenReachingHead.insert(running)
            pause(running)
        } else {
            state.queue.removeAll { $0 == id }
            state.queue.insert(id, at: 0)
            updateQueuePositions()
            advanceQueue()
        }
    }

    /// Try Again (issues) for `photos` (nil: every retryable failure), or the whole job of a failed wedding.
    public func retry(_ id: WeddingID, photos: [PhotoID]?) {
        guard let record = record(id), record.phase == .finished || Self.isFailed(record.phase) else { return }
        if Self.isFailed(record.phase) {
            requests[id] = nil
            if let i = index(id) {
                state.records[i].results = []
                state.records[i].startedAt = nil
                state.records[i].phase = .queued(position: state.queue.count)
            }
            rebuildIndex(id)
            enqueue(id)
            return
        }
        let wanted = photos.map(Set.init)
        var latest: [ResultKey: PhotoResult] = [:]
        for result in record.results { latest[ResultKey(photo: result.photo, delivery: result.delivery)] = result }
        var photosByDelivery: [DeliveryID: Set<PhotoID>] = [:]
        for (key, result) in latest {
            guard case .failed(let failure) = result.status, failure.isRetryable || wanted != nil,
                  wanted?.contains(key.photo) ?? true else { continue }
            photosByDelivery[key.delivery, default: []].insert(key.photo)
        }
        guard !photosByDelivery.isEmpty else { return }
        // One request per distinct photo set, so a photo is never redone in a delivery where it already succeeded.
        var groups: [Set<PhotoID>: [DeliveryPreset]] = [:]
        for preset in record.deliveries {
            guard let set = photosByDelivery[preset.id] else { continue }
            groups[set, default: []].append(preset)
        }
        let base = jobRequest(for: record)
        retryQueue[id] = groups.sorted { ($0.key.count, $0.value.count) > ($1.key.count, $1.value.count) }.map { set, presets in
            var request = base
            request.deliveries = presets
            request.onlyPhotos = set
            request.appendToExistingFolder = true
            request.outputFolder = record.outputFolder
            return request
        }
        if let i = index(id) { state.records[i].phase = .queued(position: state.queue.count) }
        enqueue(id)
    }

    private func enqueue(_ id: WeddingID) {
        state.queue.removeAll { $0 == id }
        state.queue.append(id)
        updateQueuePositions()
        persist(id)
        advanceQueue()
        updateDock()
    }

    static func isFailed(_ phase: JobPhase) -> Bool { if case .failed = phase { true } else { false } }

    // MARK: - History actions

    /// Reopens setup with the wedding's sources: completed deliveries are checked, disabled and marked "Done <date>".
    public func createMoreDeliveries(_ id: WeddingID) {
        guard let record = record(id), record.phase == .finished, !missingFolders.contains(id) else { return }
        cancelDraftWork()
        if state.compare != nil { closeCompare() }
        state.detailPath = []
        draftItems = record.sourceRoots
        draftNameEdited = true
        draftOutputBase = nil
        acknowledgedNotices = []
        startPending = false
        var completed: [DeliveryID: Date] = [:]
        for (key, date) in record.deliveryCompletedAt { completed[DeliveryID(rawValue: key)] = date }
        var enabled: [DeliveryID: Bool] = [:]
        for preset in state.presets { enabled[preset.id] = false }
        for id in completed.keys { enabled[id] = true }
        let scan = ScanResult(photos: record.photos, sourceRoots: record.sourceRoots, suggestedName: record.name,
                              weddingDate: record.weddingDate, camera: record.camera, totalBytes: record.sourceBytes,
                              rawCount: 0, notices: [])
        state.draft = SetupDraft(wedding: id, name: record.name, scan: .ready(scan), enabled: enabled, naming: record.naming,
                                 existingWedding: id, completedDeliveries: completed)
        state.selection = .wedding(id)
    }

    /// Accepts `folder` as the wedding's delivery folder when at least 90 % of the recorded outputs exist in it.
    @discardableResult
    public func relink(_ id: WeddingID, to folder: URL) -> Bool {
        guard let i = index(id) else { return false }
        let paths = Set(state.records[i].results.compactMap { result -> String? in
            switch result.status {
            case .done, .keptOriginal: result.outRelativePath
            default: nil
            }
        })
        guard !paths.isEmpty else { return false }
        let found = paths.filter { platform.fileExists(folder.appending(path: $0, directoryHint: .notDirectory)) }.count
        guard Double(found) >= 0.9 * Double(paths.count) else { return false }
        state.records[i].outputFolder = folder
        state.records[i].outputBookmark = try? folder.bookmarkData()
        missingFolders.remove(id)
        persist(id)
        return true
    }

    /// Locate… (S12): asks for the folder and relinks it, or explains why not.
    public func locateFolder(_ id: WeddingID) {
        guard let record = record(id) else { return }
        guard let folder = platform.chooseFolder("Locate", record.outputFolder.deletingLastPathComponent()) else { return }
        if !relink(id, to: folder) { showToast(Copy.MissingFolder.locateFailed, seconds: 4) }
    }

    /// Removes the entry only; the delivered files stay where they are.
    public func removeFromHistory(_ id: WeddingID) {
        guard let record = record(id), runTasks[id] == nil else { return }
        if case .queued = record.phase { removeFromQueue(id); return }
        state.records.removeAll { $0.id == id }
        state.queue.removeAll { $0 == id }
        state.live[id] = nil
        resultIndex[id] = nil
        requests[id] = nil
        missingFolders.remove(id)
        if state.selection == .wedding(id) {
            if state.compare != nil { closeCompare() }
            state.selection = .newWedding
            state.detailPath = []
        }
        if state.draft?.existingWedding == id { cancelSetup() }
        let engine = engine, history = history
        let previous = saveChain
        saveChain = Task {
            await previous?.value
            await engine.discardJournal(id)
            try? await history.remove(id)
        }
        updateQueuePositions()
        advanceQueue()
        updateDock()
    }

    public func requestRemoveFromHistory(_ id: WeddingID) {
        guard let record = record(id), runTasks[id] == nil else { return }
        if case .queued = record.phase { removeFromQueue(id); return }
        state.alert = .removeFromHistory(id)
    }

    public func requestRename(_ id: WeddingID) {
        guard record(id) != nil else { return }
        state.sheet = .renameWedding(id)
    }

    public func renameWedding(_ id: WeddingID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index(id) else { return }
        state.records[i].name = trimmed
        persist(id)
    }

    /// Show in Finder: the delivery folder (with `delivery == nil`, the first delivery folder inside the wedding's
    /// Deliveries folder, so Finder opens on the deliveries, F1 step 6).
    public func revealInFinder(_ id: WeddingID, delivery: DeliveryID?) {
        guard let record = record(id) else { return }
        let folder = record.outputFolder
        if let delivery, let preset = record.deliveries.first(where: { $0.id == delivery }) {
            let url = folder.appending(path: preset.folderName, directoryHint: .isDirectory)
            platform.reveal([platform.fileExists(url) ? url : folder])
            return
        }
        let first = record.deliveries.lazy.map { folder.appending(path: $0.folderName, directoryHint: .isDirectory) }
            .first { self.platform.fileExists($0) }
        platform.reveal([first ?? folder])
    }

    /// Reveals the original of `photo` (issues: Show Original).
    public func revealOriginal(_ id: WeddingID, photo: PhotoID) {
        guard let source = record(id)?.photos.first(where: { $0.id == photo }) else { return }
        platform.reveal([source.url])
    }

    public func markViewed(_ id: WeddingID) {
        guard let i = index(id), !state.records[i].viewed, state.records[i].phase == .finished else { return }
        state.records[i].viewed = true
        persist(id)
        updateDock()
    }

    // MARK: - Selection, window and status item

    public func select(_ selection: SidebarSelection) {
        guard selection != state.selection else { return }
        if state.compare != nil { closeCompare() }
        state.detailPath = []
        state.selection = selection
        state.selectedPhoto = nil
        state.gridDelivery = nil
        state.issuesOnly = false
        state.gridSort = .captureTime
        if state.draft?.existingWedding != nil, state.draft?.existingWedding != selection.weddingID { cancelSetup() }
        if case .wedding(let id) = selection {
            refreshMissingFolder(id)
            if state.windowOpen { markViewed(id) }
        }
    }

    /// Edit ▸ Find (⌘F): shows the sidebar and focuses its search field.
    public func focusSearch() {
        if !state.sidebarVisible {
            state.sidebarVisible = true
            platform.defaults.set(true, forKey: Self.sidebarDefaultsKey)
        }
        searchFocusRequest += 1
    }

    /// File ▸ New Wedding (⌘N).
    public func newWedding() {
        select(.newWedding)
    }

    public func windowDidAppear() {
        state.windowOpen = true
        if case .wedding(let id) = state.selection { markViewed(id) }
    }

    public func windowDidDisappear() {
        state.windowOpen = false
    }

    /// Inserted only while a job runs, the main window is closed and the setting is on (S17).
    public var showsTransientStatusItem: Bool {
        get { state.settings.menuBarWhileClosed && !state.windowOpen && isRunning && !statusItemDismissed }
        set { statusItemDismissed = !newValue && isRunning }
    }

    public var overallFraction: Double {
        guard let running = state.queue.first, let progress = state.live[running] else { return 0 }
        return progress.fraction
    }

    /// `applicationShouldTerminate`: true → quit now; false → the quit alert is shown and the answer comes later
    /// through `platform.replyToTerminate`.
    public func requestQuit() -> Bool {
        guard let running = runningID else { return true }
        state.alert = .quitWhileRunning(running)
        platform.openMainWindow()
        return false
    }

    private func quit(stopping id: WeddingID) {
        quitting = true
        let task = runTasks[id]
        Task { [weak self] in
            guard let self else { return }
            await self.engine.pause(id)
            await Self.waitWithTimeout(task, seconds: 5)
            if let i = self.index(id) {
                self.state.records[i].phase = .interrupted
                self.persist(id)
            }
            await self.saveChain?.value
            self.platform.replyToTerminate(true)
        }
    }

    static func waitWithTimeout(_ task: Task<Void, Never>?, seconds: Double) async {
        guard let task else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Volumes and folders

    public func volumesChanged() {
        mountedVolumes = platform.mountedVolumeNames()
        for record in state.records where record.phase == .finished { refreshMissingFolder(record.id) }
    }

    private func refreshMissingFolder(_ id: WeddingID) {
        guard let record = record(id), record.phase == .finished else { return }
        if platform.fileExists(record.outputFolder) { missingFolders.remove(id) } else { missingFolders.insert(id) }
    }

    // MARK: - Toast

    public func showToast(_ text: String, seconds: Double = 2.5) {
        state.toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.state.toast == text else { return }
            self.state.toast = nil
        }
    }

    // MARK: - Persistence and Dock

    private func persist(_ id: WeddingID) {
        guard let record = record(id) else { return }
        lastSaved[id] = platform.now()
        let previous = saveChain
        let history = history
        saveChain = Task {
            await previous?.value
            try? await history.save(record)
        }
    }

    private func persistIfDue(_ id: WeddingID) {
        guard let last = lastSaved[id] else { persist(id); return }
        if platform.now().timeIntervalSince(last) >= Self.saveInterval { persist(id) }
    }

    /// Waits until every pending save has reached the history store (tests, quit).
    public func flushSaves() async {
        await saveChain?.value
    }

    private func updateDock() {
        let badge = state.records.filter { $0.phase == .finished && !$0.viewed }.count
        platform.dock(runningID.map { _ in overallFraction }, badge)
    }

    // MARK: - Lookup helpers

    public func record(_ id: WeddingID) -> WeddingRecord? { state.records.first { $0.id == id } }
    private func index(_ id: WeddingID) -> Int? { state.records.firstIndex { $0.id == id } }

    private func replace(_ record: WeddingRecord) {
        if let i = index(record.id) { state.records[i] = record } else { state.records.insert(record, at: 0) }
    }

    private func rebuildIndex(_ id: WeddingID) {
        guard let record = record(id) else { resultIndex[id] = nil; return }
        var index: [ResultKey: Int] = [:]
        for (i, result) in record.results.enumerated() { index[ResultKey(photo: result.photo, delivery: result.delivery)] = i }
        resultIndex[id] = index
    }

    /// `base` with `newer` applied (the last result per photo and delivery wins).
    static func merged(_ base: [PhotoResult], _ newer: [PhotoResult]) -> [PhotoResult] {
        var all = base
        var index: [ResultKey: Int] = [:]
        for (i, result) in all.enumerated() { index[ResultKey(photo: result.photo, delivery: result.delivery)] = i }
        for result in newer {
            let key = ResultKey(photo: result.photo, delivery: result.delivery)
            if let at = index[key] { all[at] = result } else { index[key] = all.count; all.append(result) }
        }
        return all
    }
}

extension SidebarSelection {
    public var weddingID: WeddingID? { if case .wedding(let id) = self { id } else { nil } }
}
