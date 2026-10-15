// The Compare canvas (Docs/SPEC.md §2.4 S14): an NSViewRepresentable backed by CALayers. Each image slot is a
// clipping container with one image layer; Show Original hides the delivered slot (a visibility flip, no decode).
// While snapshot rendering (`\.isSnapshotRendering`), the same plan is drawn with Core Graphics in `draw(_:)`,
// because `cacheDisplay(in:to:)` does not capture layer-hosted content.
import AppKit
import HMBModel
import QuartzCore
import SwiftUI

/// The images the canvas shows. `imageSize` is the full-resolution pixel size (the 100 % reference), so a
/// screen-resolution preview occupies exactly the frame the full image will.
struct CompareCanvasImages: Equatable {
    var original: SendableImage?
    var delivered: SendableImage?
    var differences: SendableImage?
    var imageSize: CGSize
}

/// Gives CompareView (keyboard, menus) the canvas's cursor position and geometry.
@MainActor final class CompareCanvasProxy {
    weak var view: CompareCanvasView?
    var cursor: CGPoint? { view?.cursor }
    var geometry: CompareGeometry? { view?.geometry }
    var window: NSWindow? { view?.window }
}

struct CompareCanvas: NSViewRepresentable {
    var images: CompareCanvasImages
    var compare: CompareState
    var drawsWithLayers: Bool
    var proxy: CompareCanvasProxy
    var onDivider: (Double) -> Void
    var onCenter: (CGPoint) -> Void
    var onToggleZoom: (CGPoint?) -> Void
    var onZoom: (CompareZoom, CGPoint?) -> Void

    func makeNSView(context: Context) -> CompareCanvasView {
        let view = CompareCanvasView(drawsWithLayers: drawsWithLayers)
        proxy.view = view
        return view
    }

    func updateNSView(_ view: CompareCanvasView, context: Context) {
        proxy.view = view
        view.onDivider = onDivider
        view.onCenter = onCenter
        view.onToggleZoom = onToggleZoom
        view.onZoom = onZoom
        view.update(images: images, compare: compare)
    }
}

final class CompareCanvasView: NSView {
    let drawsWithLayers: Bool
    private(set) var images = CompareCanvasImages(imageSize: .zero)
    private(set) var compare: CompareState?
    private(set) var plan: CompareCanvasPlan?
    private(set) var cursor: CGPoint?

    var onDivider: (Double) -> Void = { _ in }
    var onCenter: (CGPoint) -> Void = { _ in }
    var onToggleZoom: (CGPoint?) -> Void = { _ in }
    var onZoom: (CompareZoom, CGPoint?) -> Void = { _, _ in }

    private var containers: [CompareCanvasPlan.Slot: CALayer] = [:]
    private var imageLayers: [CompareCanvasPlan.Slot: CALayer] = [:]
    private var drag: Drag?
    private var inlineDifferences: (original: CGImage, delivered: CGImage, appearance: String, image: CGImage)?
    private var magnification: CGFloat = 0

    private enum Drag { case divider, pan(start: CGPoint, center: CGPoint) }

    init(drawsWithLayers: Bool) {
        self.drawsWithLayers = drawsWithLayers
        super.init(frame: .zero)
        if drawsWithLayers {
            let root = CALayer()
            root.isGeometryFlipped = true
            root.masksToBounds = true
            layer = root                     // layer-hosting: AppKit leaves the tree to us
            wantsLayer = true
            for slot in CompareCanvasPlan.Slot.allCases {
                let container = CALayer()
                container.masksToBounds = true
                container.isHidden = true
                let image = CALayer()
                image.contentsGravity = .resize
                image.minificationFilter = .trilinear
                image.magnificationFilter = .linear
                container.addSublayer(image)
                root.addSublayer(container)
                containers[slot] = container
                imageLayers[slot] = image
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Comparison")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var geometry: CompareGeometry? {
        guard let compare else { return nil }
        return CompareGeometry(viewSize: bounds.size, imageSize: images.imageSize,
                               backingScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                               mode: compare.originalAvailable && images.original != nil ? compare.mode : .split)
    }

    func update(images: CompareCanvasImages, compare: CompareState) {
        let imagesChanged = images != self.images
        self.images = images
        self.compare = compare
        apply(imagesChanged: imagesChanged)
    }

    override func layout() {
        super.layout()
        apply(imagesChanged: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply(imagesChanged: false)
    }

    private func makePlan() -> CompareCanvasPlan? {
        guard let compare, let geometry, images.imageSize.width > 0, bounds.width > 0 else { return nil }
        return CompareCanvasPlan(.init(geometry: geometry, zoom: compare.zoom, center: compare.zoomCenter,
                                       divider: compare.divider, showsOriginal: compare.showsOriginal,
                                       showsDifferences: compare.showsDifferences,
                                       originalAvailable: compare.originalAvailable,
                                       hasOriginalImage: images.original != nil,
                                       hasDifferencesImage: images.differences != nil
                                           || (!drawsWithLayers && compare.showsDifferences && images.original != nil)))
    }

    private func apply(imagesChanged: Bool) {
        let plan = makePlan()
        guard plan != self.plan || imagesChanged else { return }
        self.plan = plan
        guard drawsWithLayers else {
            needsDisplay = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in CompareCanvasPlan.Slot.allCases {
            guard let container = containers[slot], let imageLayer = imageLayers[slot] else { continue }
            let image = self.image(for: slot)
            guard let placement = plan?.placements[slot], placement.visible, let image else {
                container.isHidden = true
                continue
            }
            if imagesChanged || imageLayer.contents == nil || (imageLayer.contents as! CGImage) !== image {
                imageLayer.contents = image
            }
            container.frame = placement.clip
            imageLayer.frame = placement.frame.offsetBy(dx: -placement.clip.minX, dy: -placement.clip.minY)
            container.isHidden = false
        }
        CATransaction.commit()
    }

    private func image(for slot: CompareCanvasPlan.Slot) -> CGImage? {
        switch slot {
        case .leftOriginal, .original: images.original?.cgImage
        case .delivered: images.delivered?.cgImage
        case .differences: differencesImage()
        }
    }

    /// The loader's differences image; in the snapshot path (which cannot wait for the background computation)
    /// computed here, for the appearance being drawn.
    private func differencesImage() -> CGImage? {
        if let image = images.differences { return image.cgImage }
        guard !drawsWithLayers, compare?.showsDifferences == true,
              let original = images.original?.cgImage, let delivered = images.delivered?.cgImage else { return nil }
        let appearance = effectiveAppearance.name.rawValue
        if let cached = inlineDifferences, cached.original === original, cached.delivered === delivered,
           cached.appearance == appearance {
            return cached.image
        }
        guard let image = CompareDifferences.image(original: original, delivered: delivered,
                                                   tint: CompareDifferences.tint(for: effectiveAppearance)) else { return nil }
        inlineDifferences = (original, delivered, appearance, image)
        return image
    }

    // MARK: Snapshot drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let plan = plan ?? makePlan() else { return }
        context.interpolationQuality = .high
        for slot in CompareCanvasPlan.Slot.allCases {
            guard let placement = plan.placements[slot], placement.visible, let image = image(for: slot) else { continue }
            context.saveGState()
            context.clip(to: placement.clip)
            // The view is flipped; CGImage draws bottom-up, so flip around the frame.
            context.translateBy(x: 0, y: placement.frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: placement.frame.minX, y: 0, width: placement.frame.width, height: placement.frame.height))
            context.restoreGState()
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil) }
    override func mouseEntered(with event: NSEvent) { cursor = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { cursor = nil }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let x = plan?.dividerX, abs(point.x - x) <= 6 {
            NSCursor.columnResize.set()
        } else if compare?.zoom == .actual {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if event.clickCount == 2 {
            drag = nil
            onToggleZoom(point)
            return
        }
        guard let compare else { return }
        if let x = plan?.dividerX, abs(point.x - x) <= 6 {
            drag = .divider
        } else if compare.zoom == .actual {
            drag = .pan(start: point, center: compare.zoomCenter)
            NSCursor.closedHand.set()
        } else if plan?.dividerX != nil {
            drag = .divider                                    // at Fit, dragging anywhere moves the divider
            onDivider(Double(point.x / max(1, bounds.width)))
        } else {
            drag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        switch drag {
        case .divider:
            onDivider(Double(point.x / max(1, bounds.width)))
        case .pan(let start, let center):
            guard let geometry else { return }
            onCenter(geometry.panned(center, by: CGSize(width: point.x - start.x, height: point.y - start.y)))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .pan = drag { NSCursor.openHand.set() }
        drag = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let compare, compare.zoom == .actual, let geometry else { return super.scrollWheel(with: event) }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        onCenter(geometry.panned(compare.zoomCenter, by: CGSize(width: event.scrollingDeltaX * factor,
                                                               height: event.scrollingDeltaY * factor)))
    }

    override func magnify(with event: NSEvent) {
        if event.phase == .began { magnification = 0 }
        magnification += event.magnification
        let point = convert(event.locationInWindow, from: nil)
        if magnification > 0.12, compare?.zoom == .fit {
            magnification = 0
            onZoom(.actual, point)
        } else if magnification < -0.12, compare?.zoom == .actual {
            magnification = 0
            onZoom(.fit, nil)
        }
    }
}
