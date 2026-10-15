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
    /// Split divider x in view coordinates (nil: no divider shown).
    var dividerX: CGFloat?

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

        var dividerX: CGFloat?
        if geometry.mode == .split {
            placements[.leftOriginal] = Placement(clip: .zero, frame: .zero, visible: false)
            if comparing {
                let x = (main.width * CGFloat(input.divider)).rounded()
                let clip = CGRect(x: x, y: main.minY, width: max(0, main.maxX - x), height: main.height)
                placements[.delivered] = Placement(clip: clip, frame: mainFrame, visible: !showOriginal && !showDifferences)
                if !showOriginal && !showDifferences { dividerX = x }
            } else {
                placements[.delivered] = Placement(clip: main, frame: mainFrame, visible: true)
            }
        } else {
            let left = panes[0]
            placements[.leftOriginal] = Placement(clip: left, frame: frame(in: left), visible: true)
            placements[.delivered] = Placement(clip: main, frame: mainFrame, visible: !showOriginal && !showDifferences)
        }
        self.placements = placements
        self.dividerX = dividerX
    }
}
