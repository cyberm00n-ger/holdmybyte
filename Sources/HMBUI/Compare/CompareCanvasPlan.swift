// What the Compare canvas shows where (Docs/SPEC.md §2.4 S14), as a plan of four image slots. The live canvas maps
// slots to CALayers (Show Original is one visibility flip); the snapshot path draws the same plan with Core Graphics.
import CoreGraphics
import HMBModel

struct CompareCanvasPlan: Equatable {
    enum Slot: Int, CaseIterable {
        case leftOriginal       // Side by Side: the original pane
        case original           // under the delivered image (Split: the left of the divider; Show Original)
        case delivered          // Split: right of the divider, Side by Side: right pane
        case differences        // Split: full frame, Side by Side: right pane
    }

    struct Placement: Equatable {
        var clip: CGRect        // view coordinates
        var frame: CGRect       // the image's frame, view coordinates
        var visible: Bool
    }

    var placements: [Slot: Placement]
    /// The split divider line in view coordinates: zero width at its x, spanning the visible photo (never the
    /// letterbox, the area under the toolbar or the HUD). nil: no divider shown.
    var dividerLine: CGRect?
    /// The visible photo the divider moves across (view coordinates); the divider fraction is relative to it.
    var dividerSpan: CGRect?

    /// Split divider x in view coordinates (nil: no divider shown).
    var dividerX: CGFloat? { dividerLine?.minX }

    /// Whether `point` (view coordinates) grabs the divider line (6 pt either side).
    func isOnDivider(_ point: CGPoint) -> Bool {
        guard let line = dividerLine else { return false }
        return abs(point.x - line.minX) <= 6 && point.y >= line.minY && point.y <= line.maxY
    }

    /// The divider fraction for a pointer at `x` (view coordinates), relative to the visible photo.
    func dividerFraction(atX x: CGFloat) -> Double? {
        guard let span = dividerSpan, span.width > 0 else { return nil }
        return Double(min(1, max(0, (x - span.minX) / span.width)))
    }

    struct Input: Equatable {
        var geometry: CompareGeometry
        var zoom: CompareZoom
        var center: CGPoint
        var divider: Double
        var showsOriginal: Bool
        var showsDifferences: Bool
        var originalAvailable: Bool
        var hasOriginalImage: Bool
        var hasDifferencesImage: Bool
    }

    init(_ input: Input) {
        var geometry = input.geometry
        let comparing = input.originalAvailable && input.hasOriginalImage
        if !comparing { geometry.mode = .split }            // delivered only: one pane
        let panes = geometry.panes
        func frame(in pane: CGRect) -> CGRect {
            geometry.imageFrame(in: pane.size, zoom: input.zoom, center: input.center).offsetBy(dx: pane.minX, dy: pane.minY)
        }
        let main = panes.last!
        let mainFrame = frame(in: main)
        let showOriginal = comparing && input.showsOriginal
        let showDifferences = comparing && input.showsDifferences && !showOriginal && input.hasDifferencesImage
        var placements: [Slot: Placement] = [:]
        placements[.original] = Placement(clip: main, frame: mainFrame, visible: comparing)
        placements[.differences] = Placement(clip: main, frame: mainFrame, visible: showDifferences)

        var dividerLine: CGRect?
        var dividerSpan: CGRect?
        if geometry.mode == .split {
            placements[.leftOriginal] = Placement(clip: .zero, frame: .zero, visible: false)
            if comparing {
                let span = geometry.visiblePhotoRect(in: main.size, zoom: input.zoom, center: input.center)
                    .offsetBy(dx: main.minX, dy: main.minY)
                let x = (span.minX + span.width * CGFloat(min(1, max(0, input.divider)))).rounded()
                let clip = CGRect(x: x, y: main.minY, width: max(0, main.maxX - x), height: main.height)
                placements[.delivered] = Placement(clip: clip, frame: mainFrame, visible: !showOriginal && !showDifferences)
                if !showOriginal && !showDifferences, span.width > 0, span.height > 0 {
                    dividerLine = CGRect(x: x, y: span.minY, width: 0, height: span.height)
                    dividerSpan = span
                }
            } else {
                placements[.delivered] = Placement(clip: main, frame: mainFrame, visible: true)
            }
        } else {
            let left = panes[0]
            placements[.leftOriginal] = Placement(clip: left, frame: frame(in: left), visible: true)
            placements[.delivered] = Placement(clip: main, frame: mainFrame, visible: !showOriginal && !showDifferences)
        }
        self.placements = placements
        self.dividerLine = dividerLine
        self.dividerSpan = dividerSpan
    }
}
