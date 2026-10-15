// S10 done (the result story), S11 issues, S12 missing folder.
import Charts
import HMBModel
import SwiftUI

struct DoneView: View {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model
    /// The scroll view's width (the viewport, independent of the content), for the proof card's layout.
    @State private var viewportWidth: CGFloat = Tokens.Layout.windowDefault.width - 260

    var body: some View {
        let presentation = WeddingPresentation.of(record)
        let missing = model.missingFolders.contains(record.id)
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s24) {
                Group {
                    ResultHeader(record: record, presentation: presentation)
                    if presentation.issuePhotoCount > 0 { IssuesCard(record: record, presentation: presentation) }
                    if missing { MissingFolderBanner(record: record) }
                    DeliveryTiles(record: record, presentation: presentation, folderMissing: missing)
                    // Wide: text and histogram side by side (card content ≥ 420 + 24 + 300).
                    ProofCard(record: record, presentation: presentation, folderMissing: missing,
                              wide: min(viewportWidth - 2 * Tokens.Spacing.s32, Tokens.Layout.doneHeaderMaxWidth)
                                  - 2 * Tokens.Layout.tilePadding >= 744)
                }
                .frame(maxWidth: Tokens.Layout.doneHeaderMaxWidth, alignment: .leading)
                GridHeader(record: record, presentation: presentation)
                PhotoGrid(record: record, cells: presentation.cells(delivery: model.state.gridDelivery, sort: model.state.gridSort,
                                                                    issuesOnly: model.state.issuesOnly && presentation.issuePhotoCount > 0))
            }
            .padding(.horizontal, Tokens.Spacing.s32)
            .padding(.vertical, Tokens.Spacing.s24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .toolbar { DoneToolbar(record: record) }
    }
}

struct DoneToolbar: ToolbarContent {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        let missing = model.missingFolders.contains(record.id)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.compare(record, photo: nil) } label: { Label(Copy.Toolbar.compare, systemImage: "square.split.2x1") }
                .help(Copy.Toolbar.compareHelp)
                .disabled(!model.canCompare(record))
            Button { model.revealInFinder(record.id, delivery: nil) } label: { Label(Copy.Toolbar.showInFinder, systemImage: "folder") }
                .help(Copy.Toolbar.showInFinderHelp)
                .disabled(missing)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(Copy.Toolbar.createMore) { model.createMoreDeliveries(record.id) }.disabled(missing)
                Button(Copy.Toolbar.rename) { model.requestRename(record.id) }
                Divider()
                Button(Copy.Toolbar.removeFromHistory, role: .destructive) { model.requestRemoveFromHistory(record.id) }
            } label: {
                Label(Copy.Toolbar.more, systemImage: "ellipsis")
            }
            .help(Copy.Toolbar.moreHelp)
        }
    }
}

// MARK: - Header

struct ResultHeader: View {
    let record: WeddingRecord
    let presentation: WeddingPresentation
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering
    @State private var appeared = false

    var body: some View {
        let issues = presentation.issuePhotoCount
        HStack(spacing: 14) {
            if issues > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Tokens.Typography.doneSeal)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Tokens.Palette.warning)
            } else if appeared || skipsAnimation {
                Image(systemName: "checkmark.seal.fill")
                    .font(Tokens.Typography.doneSeal)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .transition(.symbolEffect(.drawOn))
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.Done.title(record.name, issues: issues, locale: locale))
                    .font(Tokens.Typography.doneTitle)
                    .lineLimit(2)
                Text(subtitle(issues: issues))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .onAppear {
            if skipsAnimation { appeared = true; return }
            DoneAnimations.played.insert(record.id)
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
    }

    /// The seal draws on once per wedding and session; never under Reduce Motion or in snapshots.
    private var skipsAnimation: Bool {
        reduceMotion || isSnapshotRendering || DoneAnimations.played.contains(record.id)
    }

    private func subtitle(issues: Int) -> String {
        if issues > 0 {
            return Copy.Done.subtitleWithIssues(photos: record.photos.count, deliveries: record.deliveries.count,
                                                verified: record.photos.count - issues, issues: issues, locale: locale)
        }
        return Copy.Done.subtitle(photos: record.photos.count, deliveries: record.deliveries.count,
                                  seconds: record.activeSeconds, locale: locale)
    }
}

/// The seal draw-on and the tile count-down play once per wedding and app session (§2.7).
@MainActor
enum DoneAnimations {
    static var played: Set<WeddingID> = []
    static var countedDown: Set<String> = []
}

// MARK: - S11 issues

struct IssuesCard: View {
    let record: WeddingRecord
    let presentation: WeddingPresentation
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        let groups = presentation.issueGroups
        VStack(alignment: .leading, spacing: Tokens.Spacing.s12) {
            ForEach(groups) { group in
                IssueGroupView(record: record, group: group)
            }
            if groups.contains(where: { $0.failure.isRetryable }) {
                HStack {
                    Spacer()
                    Button(Copy.Issues.tryAgainForAll) { model.retry(record.id, photos: nil) }
                }
            }
        }
        .cardSurface()
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.tile, bottomLeadingRadius: Tokens.Radius.tile, style: .continuous)
                .fill(Tokens.Palette.warning)
                .frame(width: 3)
        }
    }
}

struct IssueGroupView: View {
    let record: WeddingRecord
    let group: IssueGroup
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @State private var expanded: Bool

    init(record: WeddingRecord, group: IssueGroup) {
        self.record = record
        self.group = group
        _expanded = State(initialValue: group.photos.count <= 5)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.photos) { photo in
                    HStack(spacing: Tokens.Spacing.s8) {
                        Text(photo.relativePath).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text(Copy.Issues.reason(group.failure)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: Tokens.Spacing.s8)
                        Button(Copy.Issues.showOriginal) { model.revealOriginal(record.id, photo: photo.id) }
                            .buttonStyle(.borderless)
                        if group.failure.isRetryable {
                            Button(Copy.Issues.tryAgain) { model.retry(record.id, photos: [photo.id]) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label {
                Text(Copy.Issues.heading(group.failure, count: group.photos.count, delivery: group.delivery?.name, locale: locale))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Palette.warning)
            }
        }
    }
}

// MARK: - S12 missing folder

struct MissingFolderBanner: View {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        StatusBanner(symbol: "folder.badge.questionmark", title: Copy.MissingFolder.title,
                     message: Copy.MissingFolder.message(record.outputFolder)) {
            Button(Copy.MissingFolder.locate) { model.locateFolder(record.id) }
            Button(Copy.MissingFolder.removeFromHistory) { model.requestRemoveFromHistory(record.id) }
        }
    }
}

// MARK: - Tiles

struct DeliveryTiles: View {
    let record: WeddingRecord
    let presentation: WeddingPresentation
    let folderMissing: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Tokens.Spacing.s12)], spacing: Tokens.Spacing.s12) {
            ForEach(record.deliveries) { preset in
                DeliveryTile(record: record, preset: preset, summary: presentation.summary(preset), folderMissing: folderMissing)
            }
        }
    }
}

struct DeliveryTile: View {
    let record: WeddingRecord
    let preset: DeliveryPreset
    let summary: DeliverySummary
    let folderMissing: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering
    @State private var shownBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(preset.name, systemImage: preset.symbol).font(.headline).lineLimit(1)
            Text(HMBFormat.bytes(shownBytes ?? summary.outputBytes, locale: locale))
                .font(Tokens.Typography.tileHero)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sizeLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if preset.isFullSize { SizeBar(source: summary.sourceBytes, output: summary.outputBytes) }
            if summary.keptOriginal > 0, preset.isLossy {
                Text(Copy.Done.keptOriginal(summary.keptOriginal, locale: locale))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                proofLabel
                Spacer(minLength: Tokens.Spacing.s8)
                Button(Copy.Done.showInFinder) { model.revealInFinder(record.id, delivery: preset.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(folderMissing)
            }
        }
        .frame(minHeight: Tokens.Layout.tileMinHeight - 2 * Tokens.Layout.tilePadding, alignment: .top)
        .cardSurface()
        .onAppear(perform: countDown)
    }

    @ViewBuilder private var proofLabel: some View {
        if summary.failed > 0 {
            Label {
                Text(Copy.Done.deliveredLine(delivered: summary.delivered, total: summary.total, locale: locale))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption).foregroundStyle(Tokens.Palette.warning)
        } else {
            Label {
                Text(proofLine).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.seal").foregroundStyle(.tint)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var proofLine: String {
        if preset.format == .jxlLossless { return Copy.Done.archiveProofLine }
        return Copy.Done.proofLine(quality: preset.quality, lowest: summary.minScore)
    }

    private var sizeLine: String {
        if let edge = preset.size.longEdge {
            return Copy.Done.resizedLine(longEdge: edge, format: preset.format, bytes: summary.outputBytes,
                                         photos: summary.delivered, locale: locale)
        }
        return Copy.Done.fromLine(source: summary.sourceBytes, fraction: summary.savedFraction, locale: locale)
    }

    /// Hero numbers count down from the source size to the output size over 0.6 s, on first appearance only.
    private func countDown() {
        let key = record.id.description + preset.id.rawValue
        guard !reduceMotion, !isSnapshotRendering, !DoneAnimations.countedDown.contains(key), preset.isFullSize,
              record.finishedAt.map({ Date().timeIntervalSince($0) < 30 }) == true else { return }
        DoneAnimations.countedDown.insert(key)
        shownBytes = summary.sourceBytes
        withAnimation(Tokens.Motion.countDown) { shownBytes = summary.outputBytes }
    }
}

// MARK: - Proof card

struct ProofCard: View {
    let record: WeddingRecord
    let presentation: WeddingPresentation
    let folderMissing: Bool
    var wide = true
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @State private var chosen: DeliveryID?
    @State private var showsExplainer = false

    var body: some View {
        let lossy = presentation.lossyDeliveries
        Group {
            if let delivery = lossy.first(where: { $0.id == chosen }) ?? lossy.first {
                lossyCard(delivery, lossy: lossy)
            } else if let archive = record.deliveries.first {
                let summary = presentation.summary(archive)
                Label(Copy.Done.archiveOnly(byteExact: summary.byteExactCount, total: summary.total, locale: locale),
                      systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .symbolRenderingMode(.hierarchical)
                    .labelStyle(TintedIconLabelStyle())
            }
        }
        .cardSurface()
    }

    @ViewBuilder private func lossyCard(_ delivery: DeliveryPreset, lossy: [DeliveryPreset]) -> some View {
        let summary = presentation.summary(delivery)
        let scores = presentation.scores(delivery)
        let canCompare = model.canCompare(record)
        VStack(alignment: .leading, spacing: 14) {
            if wide {
                HStack(alignment: .top, spacing: Tokens.Spacing.s24) {
                    proofText(delivery, summary: summary, canCompare: canCompare)
                        .frame(maxWidth: 420, alignment: .leading)
                    Spacer(minLength: 0)
                    chart(delivery, summary: summary, scores: scores, lossy: lossy)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    proofText(delivery, summary: summary, canCompare: canCompare)
                    chart(delivery, summary: summary, scores: scores, lossy: lossy)
                }
            }
            Text(Copy.Done.lowestFive).font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
            HStack(spacing: Tokens.Spacing.s8) {
                ForEach(presentation.lowest(5, delivery: delivery), id: \.photo.id) { item in
                    Button {
                        model.compare(record, photo: item.photo.id, delivery: delivery.id)
                    } label: {
                        ProofThumb(photo: item.photo, score: item.score)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCompare)
                    .help(item.photo.relativePath)
                }
            }
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
    }

    @ViewBuilder private func proofText(_ delivery: DeliveryPreset, summary: DeliverySummary, canCompare: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.Done.proofTitle(met: presentation.metTarget(delivery), total: summary.total, locale: locale))
                .font(.headline)
            if let lo = summary.minScore, let median = summary.medianScore, let hi = summary.maxScore {
                Text(Copy.Done.proofDetail(lowest: lo, median: median, highest: hi))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(Copy.Done.spotCheck) { model.compare(record, photo: nil, delivery: delivery.id, spotCheck: true) }
                    .hmbGlassButtonStyle()
                    .disabled(!canCompare)
                Button { showsExplainer.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help(Copy.Done.explainerTitle)
                    .accessibilityLabel(Copy.Done.explainerTitle)
                    .popover(isPresented: $showsExplainer) { QualityExplainer().frame(width: 320) }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private func chart(_ delivery: DeliveryPreset, summary: DeliverySummary, scores: [Double], lossy: [DeliveryPreset]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if lossy.count > 1 {
                Picker(selection: Binding(get: { delivery.id }, set: { chosen = $0 })) {
                    ForEach(lossy) { preset in
                        Image(systemName: preset.symbol).accessibilityLabel(preset.name).tag(preset.id)
                    }
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(delivery.name)
            }
            ScoreHistogram(scores: scores, floor: delivery.quality.floor, band: summary.targetRange, median: summary.medianScore)
                .frame(width: 300, height: 84)
        }
    }
}

struct TintedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Tokens.Spacing.s8) {
            configuration.icon.foregroundStyle(.tint)
            configuration.title
        }
    }
}

/// 96×64 thumbnail with a score capsule (bottom-trailing).
struct ProofThumb: View {
    let photo: SourcePhoto
    let score: Double

    var body: some View {
        ThumbnailView(photo: photo)
            .frame(width: Tokens.Layout.proofThumb.width, height: Tokens.Layout.proofThumb.height)
            .clipShape(Tokens.Radius.shape(Tokens.Radius.thumbnail))
            .overlay(alignment: .bottomTrailing) {
                Text(HMBFormat.score(score))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(4)
            }
            .accessibilityLabel("\(photo.relativePath), score \(HMBFormat.score(score))")
    }
}

/// Swift Charts: 0.5-point bins, the floor rule (or the Balanced target band), three X ticks, no Y axis.
struct ScoreHistogram: View {
    let scores: [Double]
    let floor: Double?
    let band: ClosedRange<Double>?
    let median: Double?

    struct Bin: Identifiable { let start: Double; let count: Int; var id: Double { start } }

    var body: some View {
        let bins = Self.bins(scores)
        let lo = min(floor ?? band?.lowerBound ?? .infinity, bins.first?.start ?? 0) - 0.5
        let hi = max(band?.upperBound ?? -.infinity, (bins.last?.start ?? 0) + 0.5) + 0.5
        Chart {
            if let band, floor == nil {
                RectangleMark(xStart: .value("Target from", band.lowerBound), xEnd: .value("Target to", band.upperBound))
                    .foregroundStyle(.tint.opacity(0.12))
            }
            ForEach(bins) { bin in
                RectangleMark(xStart: .value("From", bin.start + 0.03), xEnd: .value("To", bin.start + 0.47),
                              yStart: .value("Zero", 0), yEnd: .value("Photos", bin.count))
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
            if let floor {
                RuleMark(x: .value("Floor", floor))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(.tint)
                    .annotation(position: .top, alignment: .leading) {
                        Text(HMBFormat.score(floor)).font(.caption).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: lo...hi)
        .chartXAxis {
            AxisMarks(values: Self.ticks(lo: lo, hi: hi)) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel { if let v = value.as(Double.self) { Text(HMBFormat.score(v)).monospacedDigit() } }
            }
        }
        .chartYAxis(.hidden)
        .accessibilityChartDescriptor(HistogramDescriptor(scores: scores, floor: floor, median: median))
    }

    nonisolated static func bins(_ scores: [Double]) -> [Bin] {
        var counts: [Double: Int] = [:]
        for score in scores { counts[(score * 2).rounded(.down) / 2, default: 0] += 1 }
        return counts.keys.sorted().map { Bin(start: $0, count: counts[$0] ?? 0) }
    }

    static func ticks(lo: Double, hi: Double) -> [Double] {
        let a = (lo + 0.5).rounded(), c = (hi - 0.5).rounded()
        return [a, ((a + c) / 2).rounded(), c]
    }
}

/// VoiceOver chart summary: "535 photos, lowest 85.0, median 85.5, all at or above 85".
struct HistogramDescriptor: AXChartDescriptorRepresentable {
    let scores: [Double]
    let floor: Double?
    let median: Double?

    func makeChartDescriptor() -> AXChartDescriptor {
        var counts: [Double: Int] = [:]
        for score in scores { counts[(score * 2).rounded(.down) / 2, default: 0] += 1 }
        let bins = counts.keys.sorted().map { (start: $0, count: counts[$0] ?? 0) }
        let lowest = scores.min() ?? 0
        let summary = Copy.Done.histogramSummary(photos: scores.count, lowest: lowest, median: median ?? lowest, floor: floor)
        let x = AXNumericDataAxisDescriptor(title: "Score", range: (bins.first?.start ?? 0)...((bins.last?.start ?? 0) + 0.5),
                                            gridlinePositions: []) { HMBFormat.score($0) }
        let y = AXNumericDataAxisDescriptor(title: "Photos", range: 0...Double(bins.map(\.count).max() ?? 1),
                                            gridlinePositions: []) { "\(Int($0)) photos" }
        let series = AXDataSeriesDescriptor(name: "Scores", isContinuous: false,
                                            dataPoints: bins.map { AXDataPoint(x: $0.start, y: Double($0.count)) })
        return AXChartDescriptor(title: "Quality scores", summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

/// The QualityExplainer popover (320 wide): SSIMULACRA2 in one paragraph and the four levels.
public struct QualityExplainer: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s12) {
            Text(Copy.Done.explainerIntro).fixedSize(horizontal: false, vertical: true)
            ForEach([QualityLevel.highest, .high, .balanced, .web], id: \.self) { level in
                VStack(alignment: .leading, spacing: 2) {
                    Text(level.displayName + (level.floor.map { " · ≥ \(Int($0))" } ?? "")).font(.headline)
                    Text(level.levelDescription).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Tokens.Spacing.s16)
    }
}

// MARK: - Grid header

struct GridHeader: View {
    let record: WeddingRecord
    let presentation: WeddingPresentation
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var model = model
        let current = presentation.gridDelivery(model.state.gridDelivery)
        HStack(spacing: Tokens.Spacing.s12) {
            Text(Copy.Done.gridTitle(record.photos.count, locale: locale)).font(.headline)
            Spacer()
            if record.deliveries.count > 1, let current {
                Picker(selection: Binding(get: { current.id }, set: { model.state.gridDelivery = $0 })) {
                    ForEach(record.deliveries) { preset in
                        Label(preset.name, systemImage: preset.symbol).tag(preset.id)
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Menu {
                Picker(selection: $model.state.gridSort) {
                    ForEach([GridSort.captureTime, .lowestScore, .largestSavings, .smallestSavings], id: \.self) { sort in
                        Text(Copy.Done.sortName(sort)).tag(sort)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } label: {
                Label(Copy.Done.sortName(model.state.gridSort), systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .fixedSize()
            .help(Copy.Done.sortHelp)
            if presentation.issuePhotoCount > 0 {
                Toggle(Copy.Done.issuesOnly, isOn: $model.state.issuesOnly).toggleStyle(.checkbox)
            }
        }
    }
}
