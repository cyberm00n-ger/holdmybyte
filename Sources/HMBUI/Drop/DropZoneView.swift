// S1 empty · S2 nothing usable dropped · S3 drag target. The drop zone is never glass.
import HMBModel
import SwiftUI

struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering
    @Environment(\.locale) private var locale

    var body: some View {
        GeometryReader { proxy in
            zoneBody
                .frame(width: max(0, proxy.size.width - 2 * Tokens.Spacing.s20), height: max(0, proxy.size.height - 2 * Tokens.Spacing.s20))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .navigationTitle("holdmybyte")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Empty.accessibilityLabel)
        .accessibilityHint(Copy.Empty.accessibilityHint)
        .accessibilityAction(named: Copy.Empty.accessibilityAction) { model.choosePhotos() }
    }

    private var zoneBody: some View {
        let zone = model.state.dropZone
        let targeted = zone.isTargeted
        return ZStack {
            Tokens.Radius.shape(Tokens.Radius.dropZone)
                .fill(targeted ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.fill.quinary))
            stroke(targeted: targeted)
            VStack(spacing: 0) {
                symbol(zone)
                Spacer().frame(height: 20)
                Text(title(zone))
                    .font(Tokens.Typography.dropTitle)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .id(title(zone))
                Spacer().frame(height: 6)
                Text(subtitle(zone))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
                Spacer().frame(height: 22)
                Button(zone.isError ? Copy.DropError.chooseOther : Copy.Empty.choosePhotos) { model.choosePhotos() }
                    .hmbGlassButtonStyle()
                    .controlSize(.extraLarge)
                    .opacity(targeted ? 0 : 1)
                Spacer().frame(height: 28)
                DeliveryPreviewLine()
                    .opacity(targeted ? 0 : 1)
            }
            .padding(.horizontal, Tokens.Spacing.s32)
            .scaleEffect(targeted && !reduceMotion ? Tokens.Motion.dragTargetScale : 1)
            .animation(reduceMotion ? Tokens.Motion.reducedCrossfade : .spring(response: 0.3, dampingFraction: 0.8), value: targeted)
            VStack {
                Spacer()
                FooterNote().padding(.bottom, Tokens.Spacing.s16)
            }
        }
    }

    @ViewBuilder private func stroke(targeted: Bool) -> some View {
        let shape = Tokens.Radius.shape(Tokens.Radius.dropZone)
        if targeted {
            shape.strokeBorder(.tint, lineWidth: 2)
        } else if contrast == .increased {
            shape.strokeBorder(.secondary, lineWidth: 2)
        } else {
            shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func symbol(_ zone: DropZoneState) -> some View {
        if zone.isError {
            Image(systemName: "photo.badge.exclamationmark")
                .font(Tokens.Typography.dropSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tokens.Palette.warning)
        } else {
            Image(systemName: "photo.stack")
                .font(Tokens.Typography.dropSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(zone.isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion || isSnapshotRendering ? false : zone.isTargeted)
        }
    }

    private func title(_ zone: DropZoneState) -> String {
        switch zone {
        case .idle: Copy.Empty.title
        case .targeted(let summary): Copy.DragTarget.title(summary, locale: locale)
        case .error: Copy.DropError.title
        }
    }

    private func subtitle(_ zone: DropZoneState) -> String {
        switch zone {
        case .idle: Copy.Empty.subtitle
        case .targeted: Copy.DragTarget.subtitle
        case .error(.onlyRaw(let name, let count)): Copy.DropError.onlyRaw(folderName: name, count: count, locale: locale)
        case .error(.noPhotos): Copy.DropError.noPhotos
        }
    }
}

extension DropZoneState {
    var isTargeted: Bool { if case .targeted = self { true } else { false } }
    var isError: Bool { if case .error = self { true } else { false } }
}

/// "Creates: Couple’s Package · Website ⌄" — a popover with one checkbox per preset and Edit Deliveries….
struct DeliveryPreviewLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showsPopover = false

    var body: some View {
        let names = model.state.presets.filter { model.state.defaultOn.contains($0.id) }.map(\.name)
        Button { showsPopover.toggle() } label: {
            HStack(spacing: 4) {
                Text(Copy.Empty.creates(names))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s8) {
                ForEach(model.state.presets) { preset in
                    Toggle(isOn: Binding(get: { model.state.defaultOn.contains(preset.id) },
                                         set: { model.setDefaultOn(preset.id, $0) })) {
                        Label(preset.name, systemImage: preset.symbol)
                    }
                    .toggleStyle(.checkbox)
                }
                Divider()
                Button(Copy.Empty.editDeliveries) {
                    showsPopover = false
                    model.state.settingsTab = .deliveries
                    openSettings()
                }
                .buttonStyle(.borderless)
            }
            .padding(Tokens.Spacing.s16)
            .frame(width: 280, alignment: .leading)
        }
    }
}

struct FooterNote: View {
    var body: some View {
        Label {
            Text(Copy.Empty.footerNote)
        } icon: {
            Image(systemName: "lock.fill").font(.system(size: 10))
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

/// The centred glass capsule shown while dragging over Setup ("Add to this wedding") or over Running, Done and
/// history ("Start a new wedding") (§2.4 S3).
struct DropCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body.weight(.semibold))
            .padding(.horizontal, Tokens.Spacing.s20)
            .frame(height: 40)
            .hmbGlass(.regular, in: Capsule())
            .allowsHitTesting(false)
    }
}
