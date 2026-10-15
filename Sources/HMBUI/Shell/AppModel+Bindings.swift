// SwiftUI bindings into the model (§5.0.3 allows owners to add these in their own files).
import HMBModel
import SwiftUI

extension AppModel {
    /// `.detailOnly` until the first job starts (empty history), then the user's ⌃⌘S choice, remembered.
    public var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { self.state.sidebarVisible ? .all : .detailOnly },
            set: { visibility in
                let visible = visibility != .detailOnly
                guard visible != self.state.sidebarVisible else { return }
                self.state.sidebarVisible = visible
                self.platform.defaults.set(visible, forKey: AppModel.sidebarDefaultsKey)
            })
    }

    /// The detail NavigationStack path (Compare is pushed onto it). Popping it (Back, Esc) closes Compare.
    public var detailPathBinding: Binding<[CompareRoute]> {
        Binding(
            get: { self.state.detailPath },
            set: { path in
                if path.count < self.state.detailPath.count, self.state.compare != nil { self.closeCompare() }
                self.state.detailPath = path
            })
    }

    public var searchBinding: Binding<String> {
        Binding(get: { self.state.search }, set: { self.state.search = $0 })
    }

    public var selectionBinding: Binding<SidebarSelection?> {
        Binding(get: { self.state.selection }, set: { selection in
            if let selection { self.select(selection) }
        })
    }

    /// The record of the selected wedding, if any.
    public var selectedRecord: WeddingRecord? {
        guard case .wedding(let id) = state.selection else { return nil }
        return record(id)
    }

    /// Opens Compare for `record` at `photo` (or the first photo) in the grid's delivery.
    public func compare(_ record: WeddingRecord, photo: PhotoID?, delivery chosen: DeliveryID? = nil, spotCheck: Bool = false) {
        let presentation = WeddingPresentation(record)
        guard let delivery = presentation.compareDelivery(chosen ?? state.gridDelivery), !missingFolders.contains(record.id) else { return }
        var start = photo ?? state.selectedPhoto ?? record.photos.first?.id ?? PhotoID(0)
        if spotCheck, let hardest = presentation.lowest(1, delivery: delivery).first { start = hardest.photo.id }
        openCompare(CompareRoute(wedding: record.id, delivery: delivery.id, start: start, spotCheck: spotCheck))
    }

    /// Compare is available: a finished wedding with a lossy delivery and its folder present.
    public func canCompare(_ record: WeddingRecord) -> Bool {
        record.phase == .finished && record.deliveries.contains(where: \.isLossy) && !missingFolders.contains(record.id)
    }
}
