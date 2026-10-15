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
            Button(Copy.Empty.choosePhotos) { model.choosePhotos() }
                .keyboardShortcut("o")
            Divider()
            Button(Copy.Toolbar.showInFinder) { if let record = selected { model.revealInFinder(record.id, delivery: nil) } }
                .keyboardShortcut("r")
                .disabled(!canReveal)
        }

        CommandGroup(after: .textEditing) {
            Button("Find") { model.focusSearch() }
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
        guard let record = selected, model.state.draft == nil else { return false }
        return record.phase != .running
    }
}

/// View ▸ Comparison (§2.8). Calls WP4's Compare API; enabled only while Compare is open.
struct ComparisonMenu: View {
    let model: AppModel

    var body: some View {
        let active = model.state.compare != nil
        Menu("Comparison") {
            Button("Split") { model.updateCompare { $0.mode = .split } }
            Button("Side by Side") { model.updateCompare { $0.mode = .sideBySide } }
            Button("Toggle Split / Side by Side") {
                model.updateCompare { $0.mode = $0.mode == .split ? .sideBySide : .split }
            }
            .keyboardShortcut("y", modifiers: [])
            Divider()
            // `\` is not a key equivalent here: holding it is handled by Compare itself (key down/up).
            Button("Show Original (hold \\)") {
                model.updateCompare { $0.originalLatched.toggle(); $0.showsOriginal = $0.originalLatched }
            }
            Button("Fit / 100 %") { model.updateCompare { $0.zoom = $0.zoom == .fit ? .actual : .fit } }
                .keyboardShortcut("z", modifiers: [])
            Button("Zoom In") { model.updateCompare { $0.zoom = .actual } }
                .keyboardShortcut("+")
            Button("Zoom Out") { model.updateCompare { $0.zoom = .fit } }
                .keyboardShortcut("-")
            Button("Show Differences") { model.updateCompare { $0.showsDifferences.toggle() } }
                .keyboardShortcut("d", modifiers: [])
            Button("Inspector") { model.updateCompare { $0.showsInspector.toggle() } }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Next Photo") { model.stepCompare(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Previous Photo") { model.stepCompare(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Divider()
            Button("Back") { model.closeCompare() }
                .keyboardShortcut("[")
        }
        .disabled(!active)
    }
}
