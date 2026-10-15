// Compare geometry and canvas plan: Fit and 100 %, zoom at the cursor, panning, Show Original as one flip.
import CoreGraphics
import HMBModel
@testable import HMBUI
import Testing

@Suite struct CompareGeometryTests {
    static let geometry = CompareGeometry(viewSize: CGSize(width: 1120, height: 780), imageSize: CGSize(width: 9504, height: 6336),
                                          backingScale: 2, mode: .split)

    @Test func fitCentresBelowTheToolbarAndHundredPercentIsOneDevicePixel() {
        let g = Self.geometry
        let fit = g.imageFrame(in: g.viewSize, zoom: .fit, center: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(fit.height - 728) < 0.01)                       // 780 − 52 toolbar
        #expect(abs(fit.width - 1092) < 0.01)
        #expect(abs(fit.minY - 52) < 0.01 && abs(fit.midX - 560) < 0.01)
        let actual = g.imageFrame(in: g.viewSize, zoom: .actual, center: CGPoint(x: 0.5, y: 0.5))
        #expect(actual.width == 4752 && actual.height == 3168)       // 9504 px at 2 px/pt
        #expect(abs(actual.midX - 560) < 0.01 && abs(actual.midY - 390) < 0.01)
    }

    @Test func fitNeverEnlargesSmallDeliveries() {
        var g = Self.geometry
        g.imageSize = CGSize(width: 1440, height: 960)
        #expect(g.fitScale(in: g.viewSize) == 0.5)                   // 100 % on a Retina screen
    }

    @Test func zoomInKeepsThePointUnderTheCursor() {
        let g = Self.geometry
        for cursor in [CGPoint(x: 300, y: 400), CGPoint(x: 560, y: 416), CGPoint(x: 1000, y: 700)] {
            let before = g.unitPoint(at: cursor, zoom: .fit, center: CGPoint(x: 0.5, y: 0.5))
            let center = g.centerForZoomIn(at: cursor, fitCenter: CGPoint(x: 0.5, y: 0.5))
            let after = g.unitPoint(at: cursor, zoom: .actual, center: center)
            #expect(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001, "cursor \(cursor)")
        }
        // Without a cursor: the image centre.
        #expect(g.centerForZoomIn(at: nil, fitCenter: CGPoint(x: 0.1, y: 0.1)) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func centreIsClampedSoTheImageCoversTheView() {
        let g = Self.geometry
        let corner = g.clampedCenter(CGPoint(x: 0, y: 1), in: g.viewSize)
        let frame = g.imageFrame(in: g.viewSize, zoom: .actual, center: corner)
        #expect(abs(frame.minX) < 0.01 && abs(frame.maxY - 780) < 0.01)
        // An image smaller than the view stays centred.
        var small = g
        small.imageSize = CGSize(width: 1000, height: 600)
        #expect(small.clampedCenter(CGPoint(x: 0.1, y: 0.9), in: g.viewSize) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func panningMovesContentWithTheFingers() {
        let g = Self.geometry
        let start = CGPoint(x: 0.5, y: 0.5)
        let moved = g.panned(start, by: CGSize(width: 100, height: -50))
        let a = g.imageFrame(in: g.viewSize, zoom: .actual, center: start)
        let b = g.imageFrame(in: g.viewSize, zoom: .actual, center: moved)
        #expect(abs((b.minX - a.minX) - 100) < 0.01 && abs((b.minY - a.minY) + 50) < 0.01)
    }

    @Test func sideBySidePanesShareZoomAndCentre() {
        var g = Self.geometry
        g.mode = .sideBySide
        let panes = g.panes
        #expect(panes.count == 2 && panes[0].width == 559 && panes[1].minX == 561)
        let input = CompareCanvasPlan.Input(geometry: g, zoom: .actual, center: CGPoint(x: 0.4, y: 0.6), divider: 0.5,
                                            showsOriginal: false, showsDifferences: false, originalAvailable: true,
                                            hasOriginalImage: true, hasDifferencesImage: false)
        let plan = CompareCanvasPlan(input)
        let left = plan.placements[.leftOriginal]!, right = plan.placements[.delivered]!
        #expect(left.visible && right.visible && plan.dividerX == nil)
        #expect(left.frame.offsetBy(dx: 561, dy: 0) == right.frame)    // same image position in each pane
    }

    @Test func splitShowOriginalIsASingleVisibilityFlip() {
        let input = CompareCanvasPlan.Input(geometry: Self.geometry, zoom: .fit, center: CGPoint(x: 0.5, y: 0.5), divider: 0.3,
                                            showsOriginal: false, showsDifferences: false, originalAvailable: true,
                                            hasOriginalImage: true, hasDifferencesImage: false)
        let normal = CompareCanvasPlan(input)
        // 30 % across the photo (1092 wide, from x 14), not across the view.
        #expect(normal.dividerX == 342)
        #expect(normal.placements[.delivered]?.clip.minX == 342)
        #expect(normal.placements[.original]?.visible == true)
        var heldInput = input
        heldInput.showsOriginal = true
        let held = CompareCanvasPlan(heldInput)
        // Only the delivered slot's visibility differs (no frame changes, no new images).
        for slot in CompareCanvasPlan.Slot.allCases where slot != .delivered {
            #expect(held.placements[slot] == normal.placements[slot])
        }
        #expect(held.placements[.delivered]?.visible == false)
        #expect(held.placements[.delivered]?.frame == normal.placements[.delivered]?.frame)
    }

    /// The divider spans only the visible photo: never the letterbox, the area under the toolbar or the HUD's band
    /// below a Fit photo; at 100 % it runs from the toolbar's edge to the bottom.
    @Test func dividerIsConfinedToThePhoto() throws {
        var g = Self.geometry
        g.imageSize = CGSize(width: 4000, height: 6000)                 // portrait: letterboxed left and right
        let fit = CompareCanvasPlan(.init(geometry: g, zoom: .fit, center: CGPoint(x: 0.5, y: 0.5), divider: 0,
                                          showsOriginal: false, showsDifferences: false, originalAvailable: true,
                                          hasOriginalImage: true, hasDifferencesImage: false))
        let photo = g.imageFrame(in: g.viewSize, zoom: .fit, center: CGPoint(x: 0.5, y: 0.5))
        let line = try #require(fit.dividerLine)
        #expect(line.minY == photo.minY && line.maxY == photo.maxY && line.minY >= 52)
        #expect(line.minX == photo.minX.rounded())                       // 0 % is the photo's left edge
        #expect(abs(try #require(fit.dividerFraction(atX: photo.midX)) - 0.5) < 1e-9)
        #expect(fit.dividerFraction(atX: 0) == 0 && fit.dividerFraction(atX: g.viewSize.width) == 1)
        #expect(fit.isOnDivider(CGPoint(x: line.minX + 3, y: photo.midY)))
        #expect(!fit.isOnDivider(CGPoint(x: line.minX, y: 20)))           // under the toolbar
        let actual = CompareCanvasPlan(.init(geometry: g, zoom: .actual, center: CGPoint(x: 0.5, y: 0.5), divider: 0.5,
                                             showsOriginal: false, showsDifferences: false, originalAvailable: true,
                                             hasOriginalImage: true, hasDifferencesImage: false))
        let full = try #require(actual.dividerLine)
        #expect(full.minY == 52 && full.maxY == g.viewSize.height && full.minX == 560)
    }

    @Test func differencesCoverTheFrameInSplit() {
        let input = CompareCanvasPlan.Input(geometry: Self.geometry, zoom: .fit, center: CGPoint(x: 0.5, y: 0.5), divider: 0.5,
                                            showsOriginal: false, showsDifferences: true, originalAvailable: true,
                                            hasOriginalImage: true, hasDifferencesImage: true)
        let plan = CompareCanvasPlan(input)
        #expect(plan.placements[.differences]?.visible == true)
        #expect(plan.placements[.differences]?.clip == CGRect(origin: .zero, size: Self.geometry.viewSize))
        #expect(plan.placements[.delivered]?.visible == false && plan.dividerX == nil)
    }
}
