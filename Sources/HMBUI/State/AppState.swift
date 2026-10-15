// UI state (Docs/SPEC.md §5.0.2), verbatim. Frozen after WP0.
import Foundation
import CoreGraphics
import HMBModel

public enum SidebarSelection: Hashable, Sendable { case newWedding, wedding(WeddingID) }
public enum DragSummary: Equatable, Sendable { case folder(name: String), photos(count: Int), items(count: Int) }
public enum DropError: Equatable, Sendable { case onlyRaw(folderName: String, count: Int), noPhotos }
public enum DropZoneState: Equatable, Sendable { case idle, targeted(DragSummary), error(DropError) }
public enum EstimateState: Equatable, Sendable { case estimating, ready(DeliveryEstimate), unavailable }
public enum ScanState: Equatable, Sendable { case scanning(found: Int), ready(ScanResult) }

public struct SetupDraft: Equatable, Sendable {
    public var wedding: WeddingID
    public var name: String
    public var scan: ScanState
    public var enabled: [DeliveryID: Bool]
    public var estimates: [DeliveryID: EstimateState]
    public var naming: NamingScheme
    public var preflight: Preflight?
    public var existingWedding: WeddingID?          // Create More Deliveries
    public var completedDeliveries: [DeliveryID: Date]
    public var isDropTargeted: Bool
    public init(wedding: WeddingID = WeddingID(), name: String, scan: ScanState, enabled: [DeliveryID: Bool],
                estimates: [DeliveryID: EstimateState] = [:], naming: NamingScheme, preflight: Preflight? = nil,
                existingWedding: WeddingID? = nil, completedDeliveries: [DeliveryID: Date] = [:], isDropTargeted: Bool = false) {
        self.wedding = wedding; self.name = name; self.scan = scan; self.enabled = enabled; self.estimates = estimates
        self.naming = naming; self.preflight = preflight; self.existingWedding = existingWedding
        self.completedDeliveries = completedDeliveries; self.isDropTargeted = isDropTargeted
    }
}

public enum CompareMode: String, Sendable { case split, sideBySide }
public enum CompareZoom: Equatable, Sendable { case fit, actual }
public enum CompareOrder: String, Sendable { case captureTime, lowestScore, largestSavings }

public struct CompareRoute: Hashable, Sendable {
    public var wedding: WeddingID
    public var delivery: DeliveryID
    public var start: PhotoID
    public var spotCheck: Bool
    public init(wedding: WeddingID, delivery: DeliveryID, start: PhotoID, spotCheck: Bool) {
        self.wedding = wedding; self.delivery = delivery; self.start = start; self.spotCheck = spotCheck
    }
}

public struct CompareState: Equatable, Sendable {
    public var route: CompareRoute
    public var order: CompareOrder
    public var sequence: [PhotoID]
    public var position: Int
    public var mode: CompareMode = .split
    public var zoom: CompareZoom = .fit
    public var zoomCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)   // unit image coordinates; kept across photos
    public var divider: Double = 0.5
    public var showsOriginal = false
    public var originalLatched = false
    public var showsDifferences = false
    public var showsInspector = false
    public var originalAvailable = true
    public var spotCheckToastShown = false
    public init(route: CompareRoute, order: CompareOrder, sequence: [PhotoID], position: Int) {
        self.route = route; self.order = order; self.sequence = sequence; self.position = position
    }
}

public enum GridSort: String, Sendable { case captureTime, lowestScore, largestSavings, smallestSavings }
public enum AppAlert: Equatable, Sendable { case stop(WeddingID), quitWhileRunning(WeddingID), removeFromHistory(WeddingID), clearHistory }
public enum AppSheet: Equatable, Sendable { case editDelivery(DeliveryPreset, isNew: Bool), renameWedding(WeddingID) }
public enum SettingsTab: String, Sendable { case general, deliveries, advanced }

public struct AppState: Equatable, Sendable {
    public var selection: SidebarSelection = .newWedding
    public var sidebarVisible = false
    public var records: [WeddingRecord] = []        // every wedding; `phase` decides In Progress vs history
    public var queue: [WeddingID] = []              // FIFO; queue.first is running (or next)
    public var live: [WeddingID: JobProgress] = [:]
    public var draft: SetupDraft? = nil
    public var dropZone: DropZoneState = .idle
    public var detailPath: [CompareRoute] = []
    public var compare: CompareState? = nil
    public var search = ""
    public var gridSort: GridSort = .captureTime
    public var gridDelivery: DeliveryID? = nil
    public var issuesOnly = false
    public var selectedPhoto: PhotoID? = nil
    public var alert: AppAlert? = nil
    public var sheet: AppSheet? = nil
    public var settingsTab: SettingsTab = .general
    public var presets: [DeliveryPreset] = DeliveryPreset.builtIns
    public var defaultOn: [DeliveryID] = DeliveryPreset.defaultOnIDs
    public var settings = AppSettings()
    public var windowOpen = true
    public var toast: String? = nil
    public init() {}
}
