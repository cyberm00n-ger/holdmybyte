// S4 preparing → setup-ready / setup-estimating, S5 notices, Create More Deliveries mode, drop over setup.
import HMBModel
import SwiftUI

struct SetupView: View {
    let draft: SetupDraft
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section { SetupHeader(draft: draft, editable: true) }
                // Notices sit right under the header (the spec lists them last): a block or a warning must be visible
                // without scrolling, also at the 780 × 560 minimum (Docs/DECISIONS.md).
                let notices = model.draftNotices
                if !notices.isEmpty {
                    Section {
                        ForEach(notices, id: \.self) { NoticeRow(notice: $0, draft: draft) }
                    }
                }
                Section {
                    ForEach(model.draftPresets) { preset in
                        DeliveryRow(preset: preset, draft: draft)
                    }
                    Button { model.addDelivery() } label: { Label(Copy.Setup.addDelivery, systemImage: "plus") }
                        .buttonStyle(.borderless)
                } header: {
                    Text(Copy.Setup.deliveriesHeader)
                } footer: {
                    Text(Copy.Setup.deliveriesFooter).font(.caption).foregroundStyle(.secondary)
                }
                Section(Copy.Setup.saveTo) {
                    LocationRow(draft: draft)
                    RenameRow(draft: draft)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: Tokens.Layout.setupColumnMaxWidth)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SetupBottomBar(draft: draft) }
        .overlay {
            if draft.isDropTargeted {
                ZStack {
                    Rectangle().strokeBorder(.tint, lineWidth: 2)
                    DropCapsule(text: Copy.DragTarget.addToThisWedding)
                }
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(draft.name.isEmpty ? Copy.Setup.namePlaceholder : draft.name)
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard case .ready(let scan) = draft.scan else { return "" }
        return Copy.Toolbar.subtitle(photos: scan.photos.count, bytes: scan.totalBytes, locale: locale)
    }
}

/// Mosaic · name field · meta line (88 pt). Read-only in the Queued view.
struct SetupHeader: View {
    let draft: SetupDraft
    var editable: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.s16) {
            ThumbnailMosaic(photos: photos)
            VStack(alignment: .leading, spacing: 4) {
                if editable && draft.existingWedding == nil {
                    TextField("", text: Binding(get: { draft.name }, set: { model.renameDraft($0) }),
                              prompt: Text(Copy.Setup.namePlaceholder))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .accessibilityLabel(Copy.Setup.namePlaceholder)
                        .font(Tokens.Typography.title)
                        .focused($nameFocused)
                } else {
                    Text(draft.name).font(Tokens.Typography.title).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    if case .scanning = draft.scan { ProgressView().controlSize(.small) }
                    Text(metaLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Tokens.Layout.setupHeaderHeight)
    }

    private var photos: [SourcePhoto] {
        if case .ready(let scan) = draft.scan { return Array(scan.photos.prefix(4)) }
        return []
    }

    private var metaLine: String {
        switch draft.scan {
        case .scanning(let found): Copy.Setup.scanning(found: found, locale: locale)
        case .ready(let scan):
            Copy.Setup.meta(photos: scan.photos.count, bytes: scan.totalBytes, date: scan.weddingDate, camera: scan.camera, locale: locale)
        }
    }
}

/// One delivery (min height 56); clicking anywhere on the row toggles it.
struct DeliveryRow: View {
    let preset: DeliveryPreset
    let draft: SetupDraft
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.locale) private var locale
    @State private var hovering = false

    var body: some View {
        let completed = draft.completedDeliveries[preset.id]
        let on = completed != nil || draft.enabled[preset.id] == true
        HStack(spacing: Tokens.Spacing.s12) {
            Toggle("", isOn: Binding(get: { on }, set: { _ in model.toggleDelivery(preset.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(completed != nil)
            Image(systemName: preset.symbol)
                .font(Tokens.Typography.deliverySymbol)
                .frame(width: 30, height: 30)
                .background(on ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.fill.tertiary),
                            in: Tokens.Radius.shape(Tokens.Radius.iconWell))
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.body.weight(.medium)).lineLimit(1)
                Text(preset.specLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: Tokens.Spacing.s8)
            estimateColumn(on: on, completed: completed)
            Button(Copy.Setup.edit) { model.editDelivery(preset) }
                .buttonStyle(.borderless)
                .opacity(hovering || contrast == .increased ? 1 : 0)
                .disabled(completed != nil)
        }
        .frame(minHeight: Tokens.Layout.deliveryRowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleDelivery(preset.id) }
        .onHover { hovering = $0 }
        .opacity(completed != nil ? 0.75 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Setup.rowAccessibility(preset: preset, estimate: readyEstimate, isOn: on, completed: completed, locale: locale))
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { model.toggleDelivery(preset.id) }
        .accessibilityAction(named: Copy.Setup.edit) { model.editDelivery(preset) }
    }

    private var readyEstimate: DeliveryEstimate? {
        if case .ready(let estimate)? = draft.estimates[preset.id] { return estimate }
        return nil
    }

    @ViewBuilder private func estimateColumn(on: Bool, completed: Date?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let completed {
                Text(Copy.Setup.done(completed, locale: locale)).font(.body).monospacedDigit().foregroundStyle(.secondary)
            } else if !on {
                Text(Copy.Setup.estimateOff).font(.body).foregroundStyle(.tertiary)
            } else {
                switch draft.estimates[preset.id] {
                case .ready(let estimate)?:
                    Text(Copy.Setup.estimate(estimate.bytes, locale: locale)).font(.body).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(detail(estimate)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                case .unavailable?:
                    Text(Copy.Setup.estimateUnavailable).font(.body).foregroundStyle(.tertiary)
                case .estimating?, nil:
                    Text(Copy.Setup.estimating).font(.body).foregroundStyle(.secondary)
                        .redacted(reason: .placeholder).shimmering(active: true)
                    Text(staticDetail).font(.callout).foregroundStyle(.secondary).redacted(reason: .placeholder)
                }
            }
        }
        .fixedSize()
    }

    private func detail(_ estimate: DeliveryEstimate) -> String {
        if preset.format == .jxlLossless { return Copy.Setup.byteExact }
        if let edge = preset.size.longEdge { return Copy.Setup.longEdge(edge) }
        return HMBFormat.savedPercent(1 - estimate.fractionOfSource, locale: locale)
    }

    private var staticDetail: String {
        if preset.format == .jxlLossless { return Copy.Setup.byteExact }
        if let edge = preset.size.longEdge { return Copy.Setup.longEdge(edge) }
        return "−00 %"
    }
}

struct LocationRow: View {
    let draft: SetupDraft
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(Copy.Setup.folder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(model.draftOutputFolder.map(Copy.Setup.breadcrumb) ?? "–")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.draftOutputFolder?.path ?? "")
                    Button(Copy.Setup.change) { model.chooseOutputFolder() }
                        .disabled(draft.existingWedding != nil)
                }
            }
            Text(Copy.Setup.subfolders(model.draftSelectedPresets.map(\.folderName)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct RenameRow: View {
    let draft: SetupDraft
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(Copy.Setup.renameToggle, isOn: Binding(get: { draft.naming.renameByCaptureTime },
                                                         set: { model.setDraftRenaming($0) }))
                .disabled(draft.existingWedding != nil)
            Group {
                if draft.naming.renameByCaptureTime {
                    Text(Copy.Setup.renamePreview(pattern: draft.naming.pattern, wedding: draft.name, count: photoCount))
                        .font(Tokens.Typography.fileName)
                } else {
                    Text(Copy.Setup.renameOff).font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    private var photoCount: Int {
        switch draft.scan {
        case .ready(let scan): scan.photos.count
        case .scanning(let found): max(found, 1)
        }
    }
}

/// A setup notice (S5): symbol by kind, optional bold title, body, trailing actions. A block disables the start.
struct NoticeRow: View {
    let notice: ScanNotice
    let draft: SetupDraft
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @State private var showsList = false

    var body: some View {
        let text = Copy.Notice.text(notice, kinds: kinds, locale: locale)
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = text.title { Text(title).font(.body.weight(.semibold)) }
                    Text(text.body).font(text.title == nil ? .body : .callout)
                        .foregroundStyle(text.title == nil ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                symbol
            }
            Spacer(minLength: Tokens.Spacing.s8)
            actions
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var symbol: some View {
        switch notice.severity {
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Palette.warning)
        case .block: Image(systemName: "xmark.octagon.fill").foregroundStyle(Tokens.Palette.failure)
        }
    }

    @ViewBuilder private var actions: some View {
        switch notice {
        case .skippedNonPhotos(let count, let extensions):
            Button(Copy.Notice.showList) { showsList = true }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsList) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(extensions, id: \.self) { Text(".\($0.lowercased())").font(Tokens.Typography.fileName) }
                        if extensions.isEmpty { Text(Copy.photos(count, locale: locale)) }
                    }
                    .padding(Tokens.Spacing.s12)
                    .frame(minWidth: 160, alignment: .leading)
                }
        case .alreadyCompressed:
            HStack(spacing: 6) {
                Button(Copy.Notice.useArchiveOnly) { model.useArchiveOnly(notice) }
                Button(Copy.Notice.continueAnyway) { model.acknowledge(notice) }
            }
        case .holdMyByteOutput:
            Button(Copy.Notice.continueAnyway) { model.acknowledge(notice) }
        case .notEnoughSpace, .notWritable, .outputInsideSource:
            Button(Copy.Notice.chooseAnotherLocation) { model.chooseOutputFolder() }
                .disabled(draft.existingWedding != nil)
        default:
            EmptyView()
        }
    }

    private var kinds: [SourceKind] {
        guard case .ready(let scan) = draft.scan else { return [] }
        var seen: [SourceKind] = []
        for photo in scan.photos where photo.kind != .jpeg && !seen.contains(photo.kind) { seen.append(photo.kind) }
        return seen.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Summary · Cancel · primary (64 tall, `.bar`, top divider).
struct SetupBottomBar: View {
    let draft: SetupDraft
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Tokens.Spacing.s12) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                Spacer(minLength: Tokens.Spacing.s8)
                Button(Copy.Setup.cancel) { model.cancelSetup() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(primaryTitle) { model.startDraft() }
                    .hmbGlassButtonStyle(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.draftCanStart)
                    .fixedSize()
            }
            .padding(.horizontal, Tokens.Spacing.s20)
            .frame(height: Tokens.Layout.bottomBarHeight)
        }
        // `.bar` is a backdrop material, which offscreen rendering cannot show: the form would show through.
        .background(isSnapshotRendering ? AnyShapeStyle(.windowBackground) : AnyShapeStyle(.bar))
    }

    private var summary: String {
        let count = model.draftSelectedPresets.count
        if count > 0, model.startPending { return Copy.Setup.startsWhenRead }
        return Copy.Setup.summary(deliveries: count, totalBytes: model.draftEstimatedBytes,
                                  seconds: model.draftEstimatedSeconds, locale: locale)
    }

    private var primaryTitle: String {
        if model.isRunning || !model.state.queue.isEmpty { return Copy.Setup.addToQueue }
        if case .ready(let scan) = draft.scan { return Copy.Setup.compress(scan.photos.count, locale: locale) }
        return Copy.Setup.compressWhileScanning
    }
}
