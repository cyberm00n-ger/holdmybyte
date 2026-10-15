// The sidebar (§2.3): New Wedding, In Progress, month sections by wedding date, lifetime footer, search.
import HMBModel
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    /// What to keep scrolled into view: the selected wedding and the section it sits in (a finished job moves).
    struct RevealKey: Equatable { var id: WeddingID; var inProgress: Bool; var section: String? }

    private func revealKey(_ sections: SidebarSections) -> RevealKey? {
        guard case .wedding(let id) = model.state.selection, let record = model.record(id) else { return nil }
        let section = sections.months.first { $0.records.contains { $0.id == id } }?.title
        return RevealKey(id: id, inProgress: record.phase.isInProgress, section: section)
    }

    var body: some View {
        let sections = SidebarSections(model.state, locale: locale)
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                List(selection: model.selectionBinding) {
                    NewWeddingRow().tag(SidebarSelection.newWedding)
                    if !sections.active.isEmpty {
                        Section(Copy.Sidebar.inProgress) {
                            ForEach(sections.active) { record in
                                WeddingRow(record: record).tag(SidebarSelection.wedding(record.id))
                            }
                        }
                    }
                    ForEach(sections.months) { group in
                        Section(group.title) {
                            ForEach(group.records) { record in
                                WeddingRow(record: record).tag(SidebarSelection.wedding(record.id))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if sections.isSearching && sections.isEmpty {
                        ContentUnavailableView.search(text: model.state.search)
                    }
                }
                .contextMenu(forSelectionType: SidebarSelection.self) { items in
                    if let id = items.first?.weddingID, let record = model.record(id) {
                        WeddingContextMenu(record: record)
                    }
                }
                // The selected wedding is always on screen: when a job finishes or fails (its row moves from In Progress
                // to its month), when Create More selects it, and when it is selected from elsewhere (Dock, menus).
                .onChange(of: revealKey(sections), initial: true) { _, key in
                    guard let key else { return }
                    Task { @MainActor in
                        if isSnapshotRendering {
                            scroller.scrollTo(key.id)
                        } else {
                            withAnimation(Tokens.Motion.standard(reduceMotion: reduceMotion)) { scroller.scrollTo(key.id) }
                        }
                    }
                }
            }
            // Lifetime footer (§2.3): below the list rather than a safe-area inset, so rows never scroll under it.
            if sections.lifetimeWeddings > 0 && !sections.isSearching {
                Text(Copy.Sidebar.lifetime(savedBytes: sections.lifetimeSaved, weddings: sections.lifetimeWeddings, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.vertical, Tokens.Spacing.s12)
                    .padding(.horizontal, Tokens.Spacing.s16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            // §2.2: only while the sidebar is visible (a collapsed sidebar's items would stay in the title bar).
            if model.state.sidebarVisible {
                ToolbarItem {
                    Button { model.newWedding() } label: { Label(Copy.Toolbar.newWedding, systemImage: "plus") }
                        .help(Copy.Toolbar.newWeddingHelp)
                }
            }
        }
    }
}

/// The context menu of a wedding row (and the Done view's More menu shares its actions).
struct WeddingContextMenu: View {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        let finished = record.phase == .finished
        let missing = model.missingFolders.contains(record.id)
        let running = model.runningID == record.id
        Button(Copy.Toolbar.showInFinder) { model.revealInFinder(record.id, delivery: nil) }
            .disabled(missing || record.startedAt == nil)
        Button(Copy.Toolbar.comparePhotos) { model.select(.wedding(record.id)); model.compare(record, photo: nil) }
            .disabled(!model.canCompare(record))
        Button(Copy.Toolbar.createMore) { model.createMoreDeliveries(record.id) }
            .disabled(!finished || missing)
        Button(Copy.Toolbar.rename) { model.requestRename(record.id) }
        Divider()
        Button(Copy.Toolbar.removeFromHistory, role: .destructive) { model.requestRemoveFromHistory(record.id) }
            .disabled(running)
    }
}

struct NewWeddingRow: View {
    var body: some View {
        Label {
            Text(Copy.Sidebar.newWedding)
        } icon: {
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
        }
        .frame(minHeight: 28)
    }
}

/// 44 pt row: cover · name and meta · trailing accessory (§2.3).
struct WeddingRow: View {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @State private var rowWidth: CGFloat = 0
    @State private var subtitleWidth: CGFloat = 0
    @State private var nameWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(photo: record.coverPhoto, pixelSize: ThumbnailSize.small)
                .frame(width: 32, height: 32)
                .clipShape(Tokens.Radius.shape(Tokens.Radius.thumbnail))
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name).lineLimit(1).truncationMode(.middle)
                    .background(alignment: .leading) {
                        // The name's full width, measured, so the symbols give way before the name truncates.
                        Text(record.name).lineLimit(1).fixedSize().hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidth = $0 }
                    }
                // Numbers are never truncated (§2.9): the date and count keep their width; the name gives way.
                Text(Copy.Sidebar.rowSubtitle(date: record.weddingDate, photos: record.photos.count, locale: locale))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { subtitleWidth = $0 }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            accessory
        }
        .frame(height: Tokens.Layout.sidebarRowHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .help(record.name)
        .accessibilityElement(children: .combine)
    }

    /// Delivery symbols shown (at most 4): as many as fit beside the full name and the date and count. The name is
    /// what identifies the row, so the (tertiary) symbols give way first; a name longer than the row still
    /// middle-truncates.
    private var symbolCount: Int {
        guard rowWidth > 0, subtitleWidth > 0 else { return 4 }
        // thumbnail 32 + spacing 10 + text + spacing 10 + spacer ≥ 4 + spacing 10; an 11 pt symbol is up to 14 wide,
        // plus 3 between symbols.
        let free = rowWidth - 32 - 10 - max(subtitleWidth, nameWidth) - 10 - 4 - 10
        return max(0, min(4, Int((free + 3) / 17)))
    }

    @ViewBuilder private var accessory: some View {
        switch record.phase {
        case .running:
            ProgressView(value: model.state.live[record.id]?.fraction ?? 0)
                .progressViewStyle(.circular).controlSize(.small)
        case .queued:
            Text(Copy.Sidebar.queued).font(.caption).foregroundStyle(.tertiary)
        case .paused, .stopped, .interrupted:
            Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityLabel("Paused")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(Tokens.Typography.sidebarAccessory)
                .foregroundStyle(Tokens.Palette.warning).accessibilityLabel("Failed")
        case .finished:
            if record.issueCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").font(Tokens.Typography.sidebarAccessory)
                    .foregroundStyle(Tokens.Palette.warning).accessibilityLabel("Has issues")
            } else {
                HStack(spacing: 3) {
                    ForEach(record.deliveries.prefix(symbolCount)) { preset in
                        Image(systemName: preset.symbol)
                    }
                }
                .font(Tokens.Typography.sidebarAccessory)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(record.deliveries.map(\.name).joined(separator: ", "))
            }
        }
    }
}

/// The sidebar's content for a state: active weddings, month groups (filtered by the search), the lifetime stat.
@MainActor
struct SidebarSections {
    struct MonthGroup: Identifiable { var title: String; var records: [WeddingRecord]; var id: String { title } }

    var active: [WeddingRecord] = []
    var months: [MonthGroup] = []
    var isSearching = false
    var lifetimeSaved: Int64 = 0
    var lifetimeWeddings = 0
    var isEmpty: Bool { active.isEmpty && months.isEmpty }

    init(_ state: AppState, locale: Locale, timeZone: TimeZone = .current) {
        let query = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = !query.isEmpty
        let english = Locale(identifier: "en_US")
        func matches(_ record: WeddingRecord) -> Bool {
            guard isSearching else { return true }
            let date = record.weddingDate ?? record.createdAt
            var fields = [record.name, Copy.monthYear(date, locale: english, timeZone: timeZone),
                          Copy.monthYear(date, locale: locale, timeZone: timeZone)]
            fields += record.sourceRoots.map(\.path)
            if let camera = record.camera { fields.append(camera) }
            let haystack = fields.joined(separator: " ")
            return query.split(separator: " ").allSatisfy { term in
                haystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let queueOrder = Dictionary(uniqueKeysWithValues: state.queue.enumerated().map { ($1, $0) })
        active = state.records.filter { $0.phase.isInProgress && matches($0) }
            .sorted { (queueOrder[$0.id] ?? Int.max, $1.createdAt) < (queueOrder[$1.id] ?? Int.max, $0.createdAt) }
        let finished = state.records.filter { !$0.phase.isInProgress }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sorted = finished.filter(matches).sorted { ($0.weddingDate ?? $0.createdAt) > ($1.weddingDate ?? $1.createdAt) }
        var groups: [MonthGroup] = []
        for record in sorted {
            let title = Copy.monthYear(record.weddingDate ?? record.createdAt, locale: locale, timeZone: timeZone)
            if groups.last?.title == title { groups[groups.count - 1].records.append(record) } else {
                groups.append(MonthGroup(title: title, records: [record]))
            }
        }
        months = groups
        let done = finished.filter { $0.phase == .finished }
        lifetimeWeddings = done.count
        lifetimeSaved = done.reduce(Int64(0)) { $0 + LifetimeCache.saved($1) }
        if lifetimeSaved <= 0 { lifetimeWeddings = 0 }
    }
}

/// `savedBytesFullSize` is O(results); the sidebar asks for it on every state change, so finished records (which no
/// longer change) are memoised by id, result count and finish time.
@MainActor
enum LifetimeCache {
    private static var values: [WeddingID: (count: Int, finished: Date?, saved: Int64)] = [:]

    static func saved(_ record: WeddingRecord) -> Int64 {
        if let hit = values[record.id], hit.count == record.results.count, hit.finished == record.finishedAt { return hit.saved }
        let saved = record.savedBytesFullSize
        values[record.id] = (record.results.count, record.finishedAt, saved)
        return saved
    }
}
