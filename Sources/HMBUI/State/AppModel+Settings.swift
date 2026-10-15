// WP4 (Docs/SPEC.md §5.0.3, §2.4 S6/S16): deliveries, settings and history maintenance.
// Every change is applied to `state` first (the UI never waits for disk) and then persisted through the stores.
import AppKit
import SwiftUI
import HMBModel

extension AppModel {
    // MARK: Frozen API

    /// Opens the Edit Delivery sheet (S6) for `preset` in the main window (`state.sheet`).
    public func editDelivery(_ preset: DeliveryPreset) {
        state.sheet = .editDelivery(preset, isNew: false)
    }

    /// Opens the Edit Delivery sheet for a new custom delivery ("Add Delivery…" in Setup).
    public func addDelivery() {
        state.sheet = .editDelivery(Self.newCustomPreset(existing: state.presets), isNew: true)
    }

    /// Inserts or replaces `preset` (by id) and persists. Invalid presets are refused (the sheet never offers them).
    /// A new preset is appended. One added from Setup ("Add Delivery…", the main window's sheet) is also checked in
    /// the open setup; one added in Settings is not. Closes the sheet if it shows this preset.
    public func savePreset(_ preset: DeliveryPreset) {
        guard preset.validationError == nil else { return }
        if let index = state.presets.firstIndex(where: { $0.id == preset.id }) {
            state.presets[index] = preset
        } else {
            state.presets.append(preset)
            if case .editDelivery(let shown, true) = state.sheet, shown.id == preset.id,
               state.draft != nil, state.draft?.completedDeliveries[preset.id] == nil {
                state.draft?.enabled[preset.id] = true
            }
        }
        if case .editDelivery(let shown, _) = state.sheet, shown.id == preset.id { state.sheet = nil }
        persistPresets()
        draftPresetChanged(preset.id)
    }

    /// Deletes a custom preset (built-ins cannot be deleted) from the list, the default set and an open setup.
    public func deletePreset(_ id: DeliveryID) {
        guard let preset = state.presets.first(where: { $0.id == id }), !preset.isBuiltIn else { return }
        state.presets.removeAll { $0.id == id }
        state.defaultOn.removeAll { $0 == id }
        state.draft?.enabled[id] = nil
        state.draft?.estimates[id] = nil
        persistPresets()
    }

    /// Reorders presets (Settings ▸ Deliveries drag); the order defines ⌘1…⌘9.
    public func movePresets(from: IndexSet, to: Int) {
        state.presets.move(fromOffsets: from, toOffset: to)
        state.defaultOn = Self.ordered(state.defaultOn, by: state.presets)
        persistPresets()
    }

    /// Whether `id` is used for new weddings (the remembered default set).
    public func setDefaultOn(_ id: DeliveryID, _ on: Bool) {
        guard state.presets.contains(where: { $0.id == id }) else { return }
        var set = state.defaultOn.filter { $0 != id }
        if on { set.append(id) }
        state.defaultOn = Self.ordered(set, by: state.presets)
        persistPresets()
    }

    /// Restores the four built-ins to their shipped definitions and order, and the default set to
    /// Couple’s Package + Website. Custom deliveries are kept (after the built-ins, unchecked); nothing is deleted.
    public func restoreDefaultDeliveries() {
        let custom = state.presets.filter { !$0.isBuiltIn }
        state.presets = DeliveryPreset.builtIns + custom
        state.defaultOn = DeliveryPreset.defaultOnIDs
        persistPresets()
    }

    public func updateSettings(_ body: (inout AppSettings) -> Void) {
        var settings = state.settings
        body(&settings)
        guard settings != state.settings else { return }
        state.settings = settings
        settingsStore.save(settings)
    }

    /// Removes every finished (or failed) wedding from the history. Weddings in progress stay. Delivered photos
    /// are never touched: only the history entries go.
    public func clearHistory() {
        let removed = state.records.filter(\.isHistoryEntry).map(\.id)
        guard !removed.isEmpty else { return }
        let gone = Set(removed)
        state.records.removeAll { gone.contains($0.id) }
        if case .wedding(let id) = state.selection, gone.contains(id) { state.selection = .newWedding }
        if let compare = state.compare, gone.contains(compare.route.wedding) { closeCompare() }
        state.detailPath.removeAll { gone.contains($0.wedding) }
        if state.alert == .clearHistory { state.alert = nil }
        forgetRemoved(gone)
        removeFromStore(removed)                              // through the save chain: quit waits for it
    }

    /// Clears the learned estimate corrections (§3.10): every UserDefaults key starting with
    /// `AppModel.learnedEstimatesKeyPrefix`, then posts `AppModel.learnedEstimatesResetNotification` so a running
    /// engine can drop its in-memory copy.
    public func resetLearnedEstimates() {
        Self.wp4RemoveLearnedEstimates(from: .standard)
        NotificationCenter.default.post(name: Self.learnedEstimatesResetNotification, object: nil)
    }

    // MARK: Additions (WP4)

    /// The UserDefaults key prefix of learned estimates (κ and time EMAs, §3.10): the engine's
    /// `LearnedEstimates.keyPrefix` (HMBEngine, which HMBUI cannot import). The engine reads its defaults on every
    /// estimate, so removing the keys takes effect at once (Docs/DECISIONS.md).
    public nonisolated static let learnedEstimatesKeyPrefix = "holdmybyte.estimate."
    public nonisolated static let learnedEstimatesResetNotification = Notification.Name("holdmybyte.learnedEstimatesReset")

    nonisolated static func wp4RemoveLearnedEstimates(from defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(learnedEstimatesKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Weddings that Settings ▸ Advanced ▸ Clear History… would remove.
    public var clearableHistoryCount: Int { state.records.filter(\.isHistoryEntry).count }

    /// A new custom delivery: full-size JPEG at High, keeping everything, with a unique name ("New Delivery 2", …).
    public nonisolated static func newCustomPreset(existing: [DeliveryPreset]) -> DeliveryPreset {
        let taken = Set(existing.map { $0.name.lowercased() } + existing.map { $0.folderName.lowercased() })
        var name = "New Delivery"
        var n = 2
        while taken.contains(name.lowercased()) { name = "New Delivery \(n)"; n += 1 }
        return DeliveryPreset(id: .newCustom(), name: name, symbol: "photo", format: .jpeg, size: .full, quality: .high,
                              colour: .keepProfile, metadata: .keepAll, folderName: name)
    }


    /// Reveals (and creates, if needed) the log folder `~/Library/Logs/holdmybyte`.
    public func showLogsInFinder() {
        let folder = URL.libraryDirectory.appending(path: "Logs/holdmybyte", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Lets the user pick the fixed delivery location (Settings ▸ General). Returns false when cancelled.
    @discardableResult
    public func chooseSaveLocation() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where holdmybyte saves deliveries."
        if case .folder(let url) = state.settings.saveLocation { panel.directoryURL = url }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        updateSettings { $0.saveLocation = .folder(url) }
        return true
    }

    // MARK: Private

    private func persistPresets() {
        presetsStore.save(presets: state.presets, defaultOn: state.defaultOn)
    }

    fileprivate static func ordered(_ ids: [DeliveryID], by presets: [DeliveryPreset]) -> [DeliveryID] {
        let wanted = Set(ids)
        return presets.map(\.id).filter { wanted.contains($0) }
    }
}

extension WeddingRecord {
    /// Finished or failed: listed under its month in the sidebar, as opposed to In Progress.
    fileprivate var isHistoryEntry: Bool {
        switch phase {
        case .finished, .failed: true
        case .queued, .running, .paused, .stopped, .interrupted: false
        }
    }
}
