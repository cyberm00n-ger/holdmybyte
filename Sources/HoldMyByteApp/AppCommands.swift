// Menus and keyboard shortcuts (§2.8). Single-letter Compare keys are enabled only while Compare is shown, so they
// never steal typing elsewhere.
import HMBModel
import HMBUI
import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(Copy.Toolbar.newWedding) {
                openWindow(id: WindowID.main)
                model.newWedding()
            }
            .keyboardShortcut("n")
            Button(Copy.Empty.choosePhotos) {
                openWindow(id: WindowID.main)                    // the setup needs a window to show in
                model.choosePhotos()
            }
                .keyboardShortcut("o")
            Divider()
            Button(Copy.Toolbar.showInFinder) { if let record = selected { model.revealInFinder(record.id, delivery: nil) } }
                .keyboardShortcut("r")
                .disabled(!canReveal)
        }

        // Replaces the text-editing group (Find submenu, spelling, substitutions): its own ⌘F "Find…" would compete
        // with this one, and the app has no text documents.
        CommandGroup(replacing: .textEditing) {
            Button("Find") {
                openWindow(id: WindowID.main)
                model.focusSearch()
            }
            .keyboardShortcut("f")
        }

        SidebarCommands()

        CommandMenu("Wedding") {
            Button(model.isRunning || !model.state.queue.isEmpty ? Copy.Setup.addToQueue : "Start") { model.startDraft() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.state.draft == nil || !model.draftCanStart)
            Menu("Toggle Delivery") {
                ForEach(Array(model.draftPresets.prefix(9).enumerated()), id: \.offset) { index, preset in
                    Button(preset.name) { model.toggleDelivery(atRow: index + 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            .disabled(model.state.draft == nil)
            Divider()
            Button(pauseTitle) { if let id = jobTarget { model.togglePause(id) } }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!canTogglePause)
            Button("Stop…") { if let id = jobTarget { model.requestStop(id) } }
                .keyboardShortcut(".")
                .disabled(!canStop)
            Divider()
            Button(Copy.Toolbar.comparePhotos) { if let record = selected { model.compare(record, photo: nil) } }
                .keyboardShortcut("y")
                .disabled(!canCompare)
            Button(Copy.Toolbar.spotCheck) { if let record = selected { model.compare(record, photo: nil, spotCheck: true) } }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(!canCompare)
            Button(Copy.Toolbar.createMore) { if let record = selected { model.createMoreDeliveries(record.id) } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!canCreateMore)
            Button(Copy.Toolbar.rename) { if let record = selected { model.requestRename(record.id) } }
                .disabled(selected == nil || model.state.draft != nil)
            Divider()
            Button(Copy.Toolbar.removeFromHistory) { if let record = selected { model.requestRemoveFromHistory(record.id) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canRemove)
        }

        CommandGroup(after: .sidebar) {
            Menu("Sort Photos") {
                ForEach([GridSort.captureTime, .lowestScore, .largestSavings, .smallestSavings], id: \.self) { sort in
                    Toggle(Copy.Done.sortName(sort), isOn: Binding(get: { model.state.gridSort == sort },
                                                                     set: { if $0 { model.state.gridSort = sort } }))
                }
            }
            .disabled(selected?.phase != .finished)
            ComparisonMenu(model: model)
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button(Copy.Help.qualityMenuItem) { openWindow(id: WindowID.quality) }
        }
    }

    // MARK: State

    private var selected: WeddingRecord? {
        guard model.state.draft?.existingWedding == nil || model.state.draft == nil else { return nil }
        return model.selectedRecord
    }

    /// The selected in-progress wedding, else the running one.
    private var jobTarget: WeddingID? {
        if let record = model.selectedRecord, record.phase.isInProgress { return record.id }
        return model.runningID
    }

    private var pauseTitle: String {
        guard let id = jobTarget, let record = model.record(id), record.phase != .running else { return "Pause" }
        return "Resume"
    }

    private var canTogglePause: Bool {
        guard let id = jobTarget, let record = model.record(id) else { return false }
        return record.phase == .running || model.canResume(record)
    }

    private var canStop: Bool {
        guard let id = jobTarget, let record = model.record(id) else { return false }
        switch record.phase {
        case .running, .paused, .interrupted: return true
        default: return false
        }
    }

    private var canReveal: Bool {
        guard let record = selected else { return false }
        return record.startedAt != nil && !model.missingFolders.contains(record.id)
    }

    private var canCompare: Bool { selected.map(model.canCompare) ?? false }

    private var canCreateMore: Bool {
        guard let record = selected else { return false }
        return record.phase == .finished && !model.missingFolders.contains(record.id)
    }

    private var canRemove: Bool {
        // ⌘⌫ also deletes to the start of the line in the search field: never take it from there.
        guard let record = selected, model.state.draft == nil, !model.textInputActive else { return false }
        return record.phase != .running
    }
}

/// View ▸ Comparison (§2.8). Calls WP4's Compare API (which keeps Compare's rules: no Split, Show Original or
/// Differences without the original). The single-letter and arrow keys are enabled only while Compare has the keys
/// (`compareKeysActive`), so they never take typing from a text field, a sheet or another window; when Compare has
/// them, its own key handling sees them first and these items are what the menu shows.
struct ComparisonMenu: View {
    let model: AppModel

    var body: some View {
        let open = model.state.compare != nil
        let keys = model.compareKeysActive
        let compare = model.state.compare
        Menu("Comparison") {
            Button("Split") { if compare?.mode != .split { model.toggleCompareMode() } }
                .disabled(compare?.canSplit != true)
            Button("Side by Side") { if compare?.mode != .sideBySide { model.toggleCompareMode() } }
                .disabled(compare?.canSplit != true)
            Button("Toggle Split / Side by Side") { model.toggleCompareMode() }
                .keyboardShortcut("y", modifiers: [])
                .disabled(!keys || compare?.canSplit != true)
            Divider()
            // `\` is not a key equivalent here: holding it is handled by Compare itself (key down/up).
            Button("Show Original (hold \\)") { model.toggleCompareOriginalLatch() }
                .disabled(compare?.canShowOriginal != true)
            Button("Fit / 100 %") { model.toggleCompareZoom() }
                .keyboardShortcut("z", modifiers: [])
                .disabled(!keys)
            Button("Zoom In") { if compare?.zoom == .fit { model.toggleCompareZoom() } }
                .keyboardShortcut("+")
                .disabled(!open || compare?.zoom != .fit)
            Button("Zoom Out") { if compare?.zoom != .fit { model.toggleCompareZoom() } }
                .keyboardShortcut("-")
                .disabled(!open || compare?.zoom == .fit)
            Button("Show Differences") { model.toggleCompareDifferences() }
                .keyboardShortcut("d", modifiers: [])
                .disabled(!keys || compare?.canShowDifferences != true)
            Button("Inspector") { model.toggleCompareInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Next Photo") { model.stepCompare(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!keys)
            Button("Previous Photo") { model.stepCompare(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!keys)
            Divider()
            Button("Back") { model.closeCompare() }
                .keyboardShortcut("[")
        }
        .disabled(!open)
    }
}
