// Settings (Docs/SPEC.md §2.4 S16): toolbar-style tabs, 600 wide, every tab a Form(.grouped), height fits content.
// The selected tab is `state.settingsTab` (the snapshot harness picks it there).
import AppKit
import HMBModel
import SwiftUI

public struct SettingsView: View {
    @Bindable public var model: AppModel

    public init(model: AppModel) { self.model = model }

    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    public var body: some View {
        if isSnapshotRendering {
            // The offscreen harness cannot draw the Settings window's toolbar tabs; it shows the selected tab alone.
            Group {
                switch model.state.settingsTab {
                case .general: GeneralSettingsTab(model: model)
                case .deliveries: DeliveriesSettingsTab(model: model)
                case .advanced: AdvancedSettingsTab(model: model)
                }
            }
            .frame(width: Tokens.Layout.settingsWidth)
            .hmbAccent()
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $model.state.settingsTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsTab(model: model)
            }
            Tab("Deliveries", systemImage: "square.stack", value: SettingsTab.deliveries) {
                DeliveriesSettingsTab(model: model)
            }
            Tab("Advanced", systemImage: "wrench.and.screwdriver", value: SettingsTab.advanced) {
                AdvancedSettingsTab(model: model)
            }
        }
        .frame(width: Tokens.Layout.settingsWidth)
        .hmbAccent()
    }
}

/// Lets a grouped form report its content height, so the Settings window fits it (no scrolling, no empty space).
struct SettingsTabHeight: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Tokens.Layout.settingsWidth)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Bindable var model: AppModel
    @Environment(\.locale) private var locale

    private enum LocationChoice: Hashable { case nextToOriginals, folder }

    var body: some View {
        let settings = model.state.settings
        Form {
            Section {
                LabeledContent("Save deliveries") {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s6) {
                        HStack(alignment: .lastTextBaseline, spacing: Tokens.Spacing.s8) {
                            Picker("Save deliveries", selection: locationChoice) {
                                Text("Next to the originals").tag(LocationChoice.nextToOriginals)
                                Text("In this folder:").tag(LocationChoice.folder)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            Button("Choose…") { model.chooseSaveLocation() }
                        }
                        if case .folder(let url) = settings.saveLocation {
                            Label(Self.breadcrumb(url), systemImage: "folder")
                                .font(.callout).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(url.path)
                        }
                    }
                }
                LabeledContent("Folder name") {
                    TextField("Folder name", text: binding(\.folderNamePattern), prompt: Text(AppSettings().folderNamePattern))
                        .labelsHidden()
                }
            } footer: {
                Text("Tokens: {wedding}, {date}, {year}").font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Rename photos") {
                    VStack(alignment: .trailing, spacing: Tokens.Spacing.s6) {
                        Toggle("By capture time", isOn: binding(\.naming.renameByCaptureTime))
                        TextField("Pattern", text: binding(\.naming.pattern), prompt: Text(NamingScheme.default.pattern))
                            .labelsHidden()
                            .disabled(!settings.naming.renameByCaptureTime)
                    }
                }
            } footer: {
                Text(settings.naming.renameByCaptureTime ? Self.namingPreview(settings.naming.pattern) : "Original file names are kept.")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("When finished") {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s6) {
                        Toggle("Show a notification", isOn: binding(\.notifyWhenFinished))
                        Toggle("Play a sound", isOn: binding(\.playSound))
                    }
                }
                LabeledContent("Menu bar") {
                    Toggle("Show progress in the menu bar while the window is closed", isOn: binding(\.menuBarWhileClosed))
                }
            }
            Section {
                Picker("Processor use", selection: binding(\.processorUse)) {
                    Text("Automatic").tag(ProcessorUse.automatic)
                    Text("Gentle").tag(ProcessorUse.gentle)
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Automatic leaves room for Lightroom: it uses all but two cores. Gentle uses two cores at low priority.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(SettingsTabHeight())
    }

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.state.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private var locationChoice: Binding<LocationChoice> {
        Binding(get: {
            if case .folder = model.state.settings.saveLocation { .folder } else { .nextToOriginals }
        }, set: { choice in
            switch choice {
            case .nextToOriginals: model.updateSettings { $0.saveLocation = .nextToOriginals }
            case .folder: if case .folder = model.state.settings.saveLocation {} else { model.chooseSaveLocation() }
            }
        })
    }

    /// "Weddings › Deliveries" (the last three path components).
    static func breadcrumb(_ url: URL) -> String {
        url.pathComponents.filter { $0 != "/" }.suffix(3).joined(separator: " › ")
    }

    /// "Finn-und-Lissy-0001.jpg"
    nonisolated static func namingPreview(_ pattern: String) -> String {
        HMBFormat.fileName(pattern: pattern.isEmpty ? NamingScheme.default.pattern : pattern, wedding: "Finn und Lissy",
                           number: 1, count: 535, ext: "jpg")
    }
}

// MARK: - Deliveries

struct DeliveriesSettingsTab: View {
    @Bindable var model: AppModel
    @State private var selection: DeliveryID?
    @State private var editing: EditingPreset?

    struct EditingPreset: Identifiable {
        let preset: DeliveryPreset
        let isNew: Bool
        var id: String { preset.id.rawValue }
    }

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(model.state.presets) { preset in
                        DeliverySettingsRow(preset: preset, isDefault: Binding(
                            get: { model.state.defaultOn.contains(preset.id) },
                            set: { model.setDefaultOn(preset.id, $0) }))
                            .tag(preset.id)
                            .contextMenu {
                                Button("Edit…") { editing = EditingPreset(preset: preset, isNew: false) }
                                if !preset.isBuiltIn { Button("Delete", role: .destructive) { model.deletePreset(preset.id) } }
                            }
                    }
                    .onMove { model.movePresets(from: $0, to: $1) }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)
                .frame(height: CGFloat(max(4, model.state.presets.count)) * 49 + 10)
                .contextMenu(forSelectionType: DeliveryID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let preset = model.state.presets.first(where: { $0.id == id }) {
                        editing = EditingPreset(preset: preset, isNew: false)
                    }
                }
                HStack(spacing: Tokens.Spacing.s8) {
                    ControlGroup {
                        Button { editing = EditingPreset(preset: AppModel.newCustomPreset(existing: model.state.presets), isNew: true) } label: {
                            Image(systemName: "plus").frame(width: 16)
                        }
                        .help("Add a delivery")
                        .accessibilityLabel("Add Delivery")
                        Button { if let selected { model.deletePreset(selected.id); selection = nil } } label: {
                            Image(systemName: "minus").frame(width: 16)
                        }
                        .disabled(selected == nil || selected?.isBuiltIn == true)
                        .help("Delete the selected delivery (built-in deliveries can’t be deleted)")
                        .accessibilityLabel("Delete Delivery")
                    }
                    .fixedSize()
                    Button("Edit…") { if let selected { editing = EditingPreset(preset: selected, isNew: false) } }
                        .disabled(selected == nil)
                    Spacer()
                    Button("Restore Default Deliveries") { model.restoreDefaultDeliveries() }
                }
            } footer: {
                Text("Checked deliveries are used for new weddings. Drag to reorder; the order sets ⌘1…⌘9.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .modifier(SettingsTabHeight())
        .sheet(item: $editing) { editing in
            EditDeliverySheet(model: model, preset: editing.preset, isNew: editing.isNew) { self.editing = nil }
        }
    }

    private var selected: DeliveryPreset? {
        selection.flatMap { id in model.state.presets.first { $0.id == id } }
    }
}

/// A preset row: default-set checkbox, symbol well, name and spec line.
struct DeliverySettingsRow: View {
    let preset: DeliveryPreset
    @Binding var isDefault: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.s12) {
            Toggle("Use for new weddings", isOn: $isDefault)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: preset.symbol)
                .font(Tokens.Typography.deliverySymbol)
                .frame(width: 30, height: 30)
                .background(isDefault ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.fill.tertiary),
                            in: Tokens.Radius.shape(Tokens.Radius.iconWell))
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(preset.specLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, Tokens.Spacing.s4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDefault ? "used for new weddings" : "not used for new weddings")
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @Bindable var model: AppModel
    @State private var confirmingClear = false
    @State private var estimatesReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep detailed logs", isOn: Binding(get: { model.state.settings.detailedLogs },
                                                           set: { value in model.updateSettings { $0.detailedLogs = value } }))
                LabeledContent("Logs") {
                    Button("Show Logs in Finder") { model.showLogsInFinder() }
                }
            }
            Section {
                LabeledContent("Estimates") {
                    HStack(spacing: Tokens.Spacing.s8) {
                        if estimatesReset {
                            Label("Reset", systemImage: "checkmark").labelStyle(.iconOnly).foregroundStyle(.secondary)
                                .accessibilityLabel("Learned estimates were reset")
                        }
                        Button("Reset Learned Estimates") {
                            model.resetLearnedEstimates()
                            estimatesReset = true
                        }
                    }
                }
            } footer: {
                Text("holdmybyte learns how large deliveries turn out on your photos and refines its estimates.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("History") {
                    Button("Clear History…") { confirmingClear = true }
                        .disabled(model.clearableHistoryCount == 0)
                }
            }
        }
        .modifier(SettingsTabHeight())
        .alert(SettingsCopy.clearHistoryTitle(model.clearableHistoryCount), isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsCopy.clearHistoryMessage)
        }
    }
}

enum SettingsCopy {
    /// "Clear the history of all 38 weddings?" ("of 1 wedding" for one).
    static func clearHistoryTitle(_ count: Int) -> String {
        count == 1 ? "Clear the history of 1 wedding?" : "Clear the history of all \(count) weddings?"
    }

    static let clearHistoryMessage = "Delivered photos are not touched."
}
