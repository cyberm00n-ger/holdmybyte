// The photo grid (S8, S10): adaptive 116–168 pt square cells, colour as photos finish, hover caption, selection,
// double-click / Space / ⌘Y to compare. Must scroll at 120 fps with 2000 cells: cells are Equatable and cheap.
import HMBModel
import SwiftUI

struct PhotoGrid: View {
    let record: WeddingRecord
    let cells: [GridCell]
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool

    static let columns = [GridItem(.adaptive(minimum: Tokens.Layout.gridCellMinimum, maximum: Tokens.Layout.gridCellMaximum),
                                   spacing: Tokens.Layout.gridSpacing)]

    var body: some View {
        let selected = model.state.selectedPhoto
        let comparable = model.canCompare(record)
        LazyVGrid(columns: Self.columns, spacing: Tokens.Layout.gridSpacing) {
            ForEach(cells) { cell in
                PhotoCell(cell: cell, isSelected: selected == cell.id, locale: locale)
                    .equatable()
                    .onTapGesture(count: 2) {
                        model.state.selectedPhoto = cell.id
                        if comparable && (cell.status == .done || cell.status == .keptOriginal) { model.compare(record, photo: cell.id) }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        model.state.selectedPhoto = cell.id
                        focused = true
                    })
                    .accessibilityAction(named: Copy.Toolbar.compare) {
                        if comparable { model.compare(record, photo: cell.id) }
                    }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard comparable, let photo = selected else { return .ignored }
            model.compare(record, photo: photo)
            return .handled
        }
        .onKeyPress(.escape) {
            guard selected != nil else { return .ignored }
            model.state.selectedPhoto = nil
            return .handled
        }
    }
}

struct PhotoCell: View, Equatable {
    let cell: GridCell
    let isSelected: Bool
    let locale: Locale
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (l: PhotoCell, r: PhotoCell) -> Bool {
        l.cell == r.cell && l.isSelected == r.isSelected && l.locale == r.locale
    }

    var body: some View {
        let colour = cell.status == .done || cell.status == .keptOriginal || cell.status == .failed
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbnailView(photo: cell.photo, monochrome: !colour) }
            .saturation(colour ? 1 : 0)
            .opacity(opacity)
            .animation(reduceMotion ? nil : Tokens.Motion.photoDone, value: colour)
            .overlay(alignment: .bottom) {
                if hovering, colour {
                    let caption = Copy.Done.cellCaption(fraction: cell.savedFraction, score: cell.score, locale: locale)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    }
                }
            }
            .overlay(alignment: .topTrailing) { badge.padding(5) }
            .clipShape(Tokens.Radius.shape(Tokens.Radius.thumbnail))
            .overlay {
                if isSelected { Tokens.Radius.shape(Tokens.Radius.thumbnail).strokeBorder(.tint, lineWidth: 2) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(cell.photo.relativePath)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.Done.cellAccessibility(fileName: fileStem, status: statusWord,
                                                            fraction: cell.savedFraction, score: cell.score))
            .accessibilityAddTraits(isSelected ? [.isSelected, .isImage] : .isImage)
    }

    private var opacity: Double {
        switch cell.status {
        case .queued: 0.45
        case .working: 0.85
        case .failed: 0.6
        case .done, .keptOriginal: 1
        }
    }

    @ViewBuilder private var badge: some View {
        switch cell.status {
        case .working:
            ProgressView().controlSize(.mini)
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
        case .keptOriginal:
            Image(systemName: "equal.circle.fill").font(Tokens.Typography.statusBadge)
                .foregroundStyle(.secondary).background(Circle().fill(.background).padding(2))
        case .failed:
            Image(systemName: "xmark.octagon.fill").font(Tokens.Typography.statusBadge)
                .foregroundStyle(Tokens.Palette.failure).background(Circle().fill(.white).padding(3))
        case .done where cell.hasIssue:
            Image(systemName: "exclamationmark.triangle.fill").font(Tokens.Typography.statusBadge)
                .foregroundStyle(Tokens.Palette.warning)
        default:
            EmptyView()
        }
    }

    private var fileStem: String { (cell.photo.relativePath as NSString).lastPathComponent.components(separatedBy: ".").first ?? "" }

    private var statusWord: String {
        switch cell.status {
        case .queued: "waiting"
        case .working: "in progress"
        case .done: "done"
        case .keptOriginal: "kept as original"
        case .failed: "failed"
        }
    }
}
