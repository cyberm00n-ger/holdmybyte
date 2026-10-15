// Edit Delivery (Docs/SPEC.md §2.4 S6): 500 × 560, Form(.grouped). Cancel (Esc) · Save (Return, glass prominent);
// built-ins also get Restore Default, bottom-left. Save is disabled with the validation message shown while the
// combination is invalid.
import HMBModel
import SwiftUI

public struct EditDeliverySheet: View {
    @Bindable var model: AppModel
    let isNew: Bool
    let onFinish: () -> Void
    @State private var form: EditDeliveryForm
    @FocusState private var nameFocused: Bool
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    public static let size = CGSize(width: 500, height: 560)

    /// `onFinish` runs after Save (the preset is saved through `model.savePreset`) and after Cancel.
    public init(model: AppModel, preset: DeliveryPreset, isNew: Bool, onFinish: @escaping () -> Void) {
        self.model = model
        self.isNew = isNew
        self.onFinish = onFinish
        _form = State(initialValue: EditDeliveryForm(preset))
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $form.name, prompt: Text("Couple’s Package"))
                        .focused($nameFocused)
                    Picker("Symbol", selection: $form.symbol) {
                        ForEach(EditDeliveryForm.symbols, id: \.self) { symbol in
                            Label(symbol, systemImage: symbol).labelStyle(.iconOnly).tag(symbol)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    Picker("Format", selection: $form.format) {
                        ForEach(OutputFormat.allCases, id: \.self) { Text(EditDeliveryCopy.formatTitle($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    HStack(alignment: .lastTextBaseline, spacing: Tokens.Spacing.s6) {
                        Picker("Size", selection: $form.sizeChoice) {
                            Text("Full size").tag(EditDeliveryForm.SizeChoice.full)
                            Text("Long edge:").tag(EditDeliveryForm.SizeChoice.longEdge)
                                .selectionDisabled(!form.isLongEdgeEnabled)
                        }
                        .pickerStyle(.radioGroup)
                        TextField("Long edge", value: $form.longEdge, format: .number.grouping(.never))
                            .labelsHidden()
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .disabled(form.sizeChoice != .longEdge || !form.isLongEdgeEnabled)
                            .accessibilityLabel("Long edge in pixels")
                        Text("px").foregroundStyle(.secondary)
                    }
                    Picker("Quality", selection: Binding(get: { form.quality }, set: { if $0 != .lossless { form.lossyQuality = $0 } })) {
                        ForEach(form.qualityOptions, id: \.self) { level in
                            Text(level.displayName).tag(level).selectionDisabled(!form.isEnabled(level))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!form.isQualityPickerEnabled)
                } footer: {
                    Text(form.quality.levelDescription).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    LabeledContent("Colour") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Picker("Colour", selection: $form.colour) {
                                Text(EditDeliveryCopy.colourTitle(.keepProfile)).tag(ColourHandling.keepProfile)
                                Text(EditDeliveryCopy.colourTitle(.convertToSRGB)).tag(ColourHandling.convertToSRGB)
                                    .selectionDisabled(!form.isConvertToSRGBEnabled)
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            .labelsHidden()
                            Text(EditDeliveryCopy.colourFooter).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Metadata", selection: $form.metadata) {
                        ForEach([MetadataPolicy.keepAll, .removeLocation, .removeAll], id: \.self) { policy in
                            Text(EditDeliveryCopy.metadataTitle(policy)).tag(policy)
                                .selectionDisabled(policy != .keepAll && !form.isMetadataRemovalEnabled)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    TextField("Folder name", text: $form.folderName, prompt: Text("Couple"))
                }
            }
            .formStyle(.grouped)
            .scrollEdgeEffectStyle(isSnapshotRendering ? .hard : .soft, for: .bottom)

            bottomBar
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // A real sheet draws its own (glass) background; the offscreen snapshot has none behind the bottom bar.
        .background(isSnapshotRendering ? AnyShapeStyle(.windowBackground) : AnyShapeStyle(.clear))
        .onAppear { if isNew { nameFocused = true } }
    }

    private var bottomBar: some View {
        HStack(spacing: Tokens.Spacing.s12) {
            if form.canRestoreDefault {
                Button("Restore Default") { form.restoreDefault() }
                    .buttonStyle(.borderless)
                    .disabled(form.isAtDefault)
            }
            Spacer(minLength: Tokens.Spacing.s8)
            if let message = form.validationError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Tokens.Palette.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Can’t save: \(message)")
            }
            Button("Cancel") { onFinish() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button("Save") {
                model.savePreset(form.preset)
                onFinish()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .hmbGlassButtonStyle(prominent: true)
            .disabled(!form.canSave)
        }
        .padding(.horizontal, Tokens.Spacing.s20)
        .padding(.vertical, Tokens.Spacing.s16)
    }
}

extension View {
    /// Presents the Edit Delivery sheet whenever `model.state.sheet` is `.editDelivery` (Setup's Edit… and
    /// Add Delivery…). Attach once, to the main window's root view (WP3).
    public func editDeliverySheet(model: AppModel) -> some View {
        modifier(EditDeliverySheetPresenter(model: model))
    }
}

private struct EditDeliverySheetPresenter: ViewModifier {
    @Bindable var model: AppModel

    private struct Editing: Identifiable {
        let preset: DeliveryPreset
        let isNew: Bool
        var id: String { preset.id.rawValue }
    }

    func body(content: Content) -> some View {
        content.sheet(item: Binding<Editing?>(
            get: {
                if case .editDelivery(let preset, let isNew) = model.state.sheet { Editing(preset: preset, isNew: isNew) } else { nil }
            },
            set: { if $0 == nil, case .editDelivery = model.state.sheet { model.state.sheet = nil } })) { editing in
            EditDeliverySheet(model: model, preset: editing.preset, isNew: editing.isNew) {
                if case .editDelivery = model.state.sheet { model.state.sheet = nil }
            }
        }
    }
}
