// WP4's snapshot states (Docs/SPEC.md §5.5 catalogue ids for S6, S14 and S16), for the snapshot harness (WP5)
// and WP4's own render tests. Each id gives the AppState, the engine to build the model with, and the view.
import HMBFixtures
import HMBModel
import SwiftUI

public enum WP4StateCatalogue {
    public static let compareIDs = ["compare-split-fit", "compare-split-100", "compare-side", "compare-original-held",
                                    "compare-diff", "compare-no-original", "compare-spotcheck-toast"]
    public static let settingsIDs = ["settings-general", "settings-deliveries", "settings-advanced"]
    public static let ids = ["edit-delivery"] + compareIDs + settingsIDs

    /// The photo Compare opens on in the non-spot-check states (index 120, a landscape frame).
    public static let comparePhoto = PhotoID(120)

    public static func state(_ id: String) -> AppState? {
        var state = AppState()
        state.records = Fixtures.history
        state.sidebarVisible = true
        state.selection = .wedding(Fixtures.finnUndLissyID)
        switch id {
        case "edit-delivery":
            state.selection = .newWedding
            state.sheet = .editDelivery(DeliveryPreset.builtIns[0], isNew: false)
            return state
        case "settings-general":
            state.settingsTab = .general
            state.settings.saveLocation = .nextToOriginals
            return state
        case "settings-deliveries":
            state.settingsTab = .deliveries
            return state
        case "settings-advanced":
            state.settingsTab = .advanced
            return state
        default:
            break
        }
        guard compareIDs.contains(id) else { return nil }
        let spotCheck = id == "compare-spotcheck-toast"
        let record = Fixtures.finnUndLissy
        let lowest = CompareSequence.make(record, delivery: .couple, order: .lowestScore).first ?? comparePhoto
        let route = CompareRoute(wedding: record.id, delivery: .couple, start: spotCheck ? lowest : comparePhoto, spotCheck: spotCheck)
        guard var compare = AppModel.compareState(for: route, records: state.records) else { return nil }
        state.detailPath = [compare.route]
        switch id {
        case "compare-split-100":
            compare.zoom = .actual
            compare.zoomCenter = CGPoint(x: 0.42, y: 0.4)
            compare.showsInspector = true
        case "compare-side":
            compare.mode = .sideBySide
        case "compare-original-held":
            compare.showsOriginal = true
        case "compare-diff":
            compare.showsDifferences = true
        case "compare-no-original":
            compare.originalAvailable = false
        case "compare-spotcheck-toast":
            let k = CompareSequence.hardestCount(compare.sequence.count)
            compare.position = k
            compare.spotCheckToastShown = true
            state.toast = CompareCopy.spotCheckToast(k)
        default:
            break
        }
        compare.normalise()
        state.compare = compare
        return state
    }

    /// The engine to build the model with (the no-original state reports the source drive as disconnected).
    public static func engine(_ id: String) -> FixtureEngine {
        FixtureEngine(.init(compareUnavailableVolume: id == "compare-no-original" ? "Wedding SSD" : nil))
    }

    /// A side-effect-free model for `id` (in-memory stores, synthetic thumbnails).
    @MainActor public static func model(_ id: String) -> AppModel? {
        guard let state = state(id) else { return nil }
        return AppModel(state: state, engine: engine(id), history: InMemoryHistory(state.records),
                        presetsStore: InMemoryPresets(), settingsStore: InMemorySettings(),
                        thumbnails: FixtureThumbnails(photoFolder: nil))
    }

    /// The view to render for `id`. Compare states load their pair first (at `maxPixelSize`) and register it with
    /// `CompareView.preload`, so the first frame already shows the photos. Settings are 600 wide; the sheet 500 × 560.
    @MainActor public static func view(_ id: String, model: AppModel, maxPixelSize: Int = 2400) async -> AnyView? {
        switch id {
        case "edit-delivery":
            guard case .editDelivery(let preset, let isNew) = model.state.sheet else { return nil }
            return AnyView(EditDeliverySheet(model: model, preset: preset, isNew: isNew) {})
        case let id where settingsIDs.contains(id):
            return AnyView(SettingsView(model: model))
        case let id where compareIDs.contains(id):
            guard let compare = model.state.compare, let record = model.compareRecord, let photo = compare.currentPhoto,
                  let pair = try? await model.engine.comparePair(record: record, photo: photo, delivery: compare.route.delivery,
                                                                 maxPixelSize: maxPixelSize) else { return nil }
            CompareView.preload(pair, wedding: record.id, photo: photo, delivery: compare.route.delivery)
            return AnyView(NavigationStack { CompareView(model: model) })
        default:
            return nil
        }
    }
}
