// WP0 stub (Docs/SPEC.md §5.0.3); WP3 owns this file and implements every body.
// Contract: `init` has no side effects (it never calls `bootstrap`), so any view can be rendered from
// `AppModel(state:…)` with fixtures — the snapshot harness relies on this.
import SwiftUI
import HMBModel

@MainActor @Observable
public final class AppModel {
    public var state: AppState
    public let engine: any EngineService
    public let history: any HistoryStoring
    public let presetsStore: any PresetStoring
    public let settingsStore: any SettingsStoring
    public let thumbnails: any ThumbnailProviding

    public init(state: AppState, engine: any EngineService, history: any HistoryStoring,
                presetsStore: any PresetStoring, settingsStore: any SettingsStoring, thumbnails: any ThumbnailProviding) {
        self.state = state
        self.engine = engine
        self.history = history
        self.presetsStore = presetsStore
        self.settingsStore = settingsStore
        self.thumbnails = thumbnails
    }

    // WP3 (AppModel.swift)
    public func bootstrap() async {}                              // load history, presets, settings, unfinished jobs → interrupted
    public func handleDrop(_ urls: [URL]) -> Bool { false }
    public func setDropTargeted(_ targeted: Bool, summary: DragSummary?) {}
    public func choosePhotos() {}
    public func toggleDelivery(_ id: DeliveryID) {}
    public func renameDraft(_ name: String) {}
    public func chooseOutputFolder() {}
    public func cancelSetup() {}
    public func startDraft() {}
    public func pause(_ id: WeddingID) {}
    public func resume(_ id: WeddingID) {}
    public func requestStop(_ id: WeddingID) {}
    public func confirmAlert() {}
    public func dismissAlert() {}
    public func removeFromQueue(_ id: WeddingID) {}
    public func startNow(_ id: WeddingID) {}
    public func retry(_ id: WeddingID, photos: [PhotoID]?) {}
    public func createMoreDeliveries(_ id: WeddingID) {}
    public func relink(_ id: WeddingID, to folder: URL) -> Bool { false }
    public func removeFromHistory(_ id: WeddingID) {}
    public func revealInFinder(_ id: WeddingID, delivery: DeliveryID?) {}
    public func markViewed(_ id: WeddingID) {}
    public var showsTransientStatusItem: Bool = false
    public var overallFraction: Double {
        guard let running = state.queue.first, let progress = state.live[running] else { return 0 }
        return progress.fraction
    }
}
