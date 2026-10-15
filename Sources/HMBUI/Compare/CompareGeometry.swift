// Compare geometry (Docs/SPEC.md §2.4 S14): panes, where the image sits at Fit and at 100 %, zooming at the cursor
// and panning. Pure value math in view points (y down), shared by the CALayer path and the snapshot draw path.
import CoreGraphics

struct CompareGeometry: Equatable {
    /// The canvas in points.
    var viewSize: CGSize
    /// Pixel size of the full-resolution delivered image (the reference for 100 %).
    var imageSize: CGSize
    /// Device pixels per point (100 % = one image pixel per device pixel).
    var backingScale: CGFloat
    var mode: CompareMode
    /// Content runs under the toolbar; at Fit the image is centred in the area below this inset.
    var topInset: CGFloat = 52

    static let paneGap: CGFloat = 2

    /// Split (or no original): one pane over the whole canvas. Side by Side: two panes with a 2 pt gap.
    var panes: [CGRect] {
        let bounds = CGRect(origin: .zero, size: viewSize)
        guard mode == .sideBySide else { return [bounds] }
        let width = max(0, (viewSize.width - Self.paneGap) / 2)
        return [CGRect(x: 0, y: 0, width: width, height: viewSize.height),
                CGRect(x: width + Self.paneGap, y: 0, width: width, height: viewSize.height)]
    }

    /// Points per image pixel at 100 %.
    var actualScale: CGFloat { 1 / max(backingScale, 0.5) }

    /// Points per image pixel at Fit: the image fits the pane below the toolbar, never enlarged beyond 100 %.
    func fitScale(in pane: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let available = CGSize(width: pane.width, height: max(1, pane.height - topInset))
        return min(actualScale, min(available.width / imageSize.width, available.height / imageSize.height))
    }

    func scale(_ zoom: CompareZoom, in pane: CGSize) -> CGFloat {
        zoom == .fit ? fitScale(in: pane) : actualScale
    }

    /// The image's frame in pane coordinates. At 100 %, `center` (unit image coordinates) sits in the pane's centre,
    /// clamped so the image never leaves a gap along an axis where it is larger than the pane.
    func imageFrame(in pane: CGSize, zoom: CompareZoom, center: CGPoint) -> CGRect {
        let s = scale(zoom, in: pane)
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        guard zoom == .actual else {
            let areaHeight = max(1, pane.height - topInset)
            return CGRect(x: (pane.width - size.width) / 2, y: topInset + (areaHeight - size.height) / 2,
                          width: size.width, height: size.height)
        }
        let c = clampedCenter(center, in: pane)
        return CGRect(x: pane.width / 2 - c.x * size.width, y: pane.height / 2 - c.y * size.height,
                      width: size.width, height: size.height)
    }

    /// The part of the image that is on screen below the toolbar, in pane coordinates: at Fit the photo itself
    /// (the letterbox excluded), at 100 % the pane below the toolbar. The split divider spans exactly this rect.
    func visiblePhotoRect(in pane: CGSize, zoom: CompareZoom, center: CGPoint) -> CGRect {
        let frame = imageFrame(in: pane, zoom: zoom, center: center)
        let area = CGRect(x: 0, y: topInset, width: pane.width, height: max(0, pane.height - topInset))
        let visible = frame.intersection(area)
        return visible.isNull ? .zero : visible
    }

    /// The unit centre adjusted so that, at 100 %, the image covers the pane (0.5 where it is smaller than the pane).
    func clampedCenter(_ center: CGPoint, in pane: CGSize) -> CGPoint {
        let s = actualScale
        func axis(_ c: CGFloat, image: CGFloat, pane: CGFloat) -> CGFloat {
            let extent = image * s
            guard extent > pane, extent > 0 else { return 0.5 }
            let half = pane / 2 / extent
            return min(1 - half, max(half, c.isFinite ? c : 0.5))
        }
        return CGPoint(x: axis(center.x, image: imageSize.width, pane: pane.width),
                       y: axis(center.y, image: imageSize.height, pane: pane.height))
    }

    /// The pane containing `point` (view coordinates), and the point relative to it.
    func pane(containing point: CGPoint) -> (index: Int, rect: CGRect) {
        let rects = panes
        let index = rects.firstIndex { $0.contains(point) } ?? (rects.count > 1 && point.x > viewSize.width / 2 ? 1 : 0)
        return (index, rects[index])
    }

    /// Unit image coordinates under `point` (view coordinates).
    func unitPoint(at point: CGPoint, zoom: CompareZoom, center: CGPoint) -> CGPoint {
        let pane = pane(containing: point).rect
        let frame = imageFrame(in: pane.size, zoom: zoom, center: center)
        let local = CGPoint(x: point.x - pane.minX, y: point.y - pane.minY)
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(1, max(0, (local.x - frame.minX) / frame.width)),
                       y: min(1, max(0, (local.y - frame.minY) / frame.height)))
    }

    /// Fit → 100 % keeping the image point under `cursor` (view coordinates) under the cursor; nil cursor zooms on
    /// the image centre. Returns the new unit centre.
    func centerForZoomIn(at cursor: CGPoint?, fitCenter: CGPoint) -> CGPoint {
        guard let cursor else { return CGPoint(x: 0.5, y: 0.5) }
        let pane = pane(containing: cursor).rect
        let target = unitPoint(at: cursor, zoom: .fit, center: fitCenter)
        let s = actualScale
        let local = CGPoint(x: cursor.x - pane.minX, y: cursor.y - pane.minY)
        // After zooming, target must sit at `local`: centre = target − (local − paneCentre) / imageExtent.
        let center = CGPoint(x: target.x - (local.x - pane.width / 2) / max(1, imageSize.width * s),
                             y: target.y - (local.y - pane.height / 2) / max(1, imageSize.height * s))
        return clampedCenter(center, in: pane.size)
    }

    /// The centre after dragging or scrolling the content by `delta` points (content follows the fingers).
    func panned(_ center: CGPoint, by delta: CGSize) -> CGPoint {
        let pane = panes[0].size
        let s = actualScale
        let moved = CGPoint(x: center.x - delta.width / max(1, imageSize.width * s),
                            y: center.y - delta.height / max(1, imageSize.height * s))
        return clampedCenter(moved, in: pane)
    }
}
