// Draws hosted SwiftUI views into bitmaps without the window server (§5.5 "How it renders").
//
// Windows are created but never ordered front; `cacheDisplay(in:to:)` asks the view tree to draw itself, which works
// with a locked screen. What the window server composites is not available that way, so before each capture the
// harness rewrites three things (measured on macOS 26, see Docs/SNAPSHOTS.md "Rendering notes"):
//  1. Liquid Glass (`NSGlassEffectView`: the sidebar, toolbar platters) draws as opaque white. Each glass view is
//     replaced by a `GlassStandIn` that paints a flat, appearance-aware fill; its content view is moved into the
//     stand-in and pinned with constraints.
//  2. Backdrop layers and scroll-edge pockets (`CABackdropLayer`, `NSScrollPocket`) blur what lies behind them and
//     come out as solid blocks; they are hidden.
//  3. Vibrant text and symbols are `CATintedImage` layer contents (an A8 mask tinted by `contentsMultiplyColor`,
//     composited with plus-lighter/plus-darker). Neither `cacheDisplay` nor `CALayer.render(in:)` draws them, so
//     they are flattened into ordinary images with a colour that approximates the vibrant result.
import AppKit
import ObjectiveC
import SwiftUI

@MainActor
enum OffscreenCapture {
    // MARK: Windows

    /// A titled, unified-toolbar window like the app's main window (never ordered front).
    static func mainWindow<Content: View>(size: CGSize, appearance: NSAppearance, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.appearance = appearance
        window.animationBehavior = .none
        let hosting = NSHostingView(rootView: content)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = hosting
        window.setContentSize(size)
        return window
    }

    /// A titled window sized to its content's fitting height (Settings).
    static func fittingWindow<Content: View>(width: CGFloat, minHeight: CGFloat, maxHeight: CGFloat, title: String,
                                             appearance: NSAppearance, content: Content) -> NSWindow {
        let hosting = NSHostingView(rootView: content)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: minHeight)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: minHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.toolbarStyle = .preference
        window.appearance = appearance
        window.animationBehavior = .none
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let height = min(maxHeight, max(minHeight, hosting.fittingSize.height))
        window.setContentSize(CGSize(width: width, height: height))
        return window
    }

    /// A borderless panel sized to its content (the menu-bar extra's menu).
    static func panel<Content: View>(minWidth: CGFloat, appearance: NSAppearance, content: Content) -> NSWindow {
        let hosting = NSHostingView(rootView: content)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = CGSize(width: max(minWidth, fitting.width), height: max(40, fitting.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.animationBehavior = .none
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.setContentSize(size)
        return window
    }

    /// Spins the main run loop (SwiftUI updates, `.task`s and main-actor work all run on it).
    static func settle(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    // MARK: Capture

    /// Prepares `root` (glass, backdrops, vibrancy; see the file comment), lets it re-render, and draws it.
    static func capture(_ root: NSView, appearance: NSAppearance, settleAfterRewrite: Double = 0.15) -> NSBitmapImageRep? {
        replaceGlass(in: root, appearance: appearance)
        settle(settleAfterRewrite)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        if let layer = root.layer { flattenTintedContents(layer, appearance: appearance) }
        guard root.bounds.width >= 1, root.bounds.height >= 1,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep
    }

    /// The window's frame view (title bar and toolbar included).
    static func frameView(of window: NSWindow) -> NSView { window.contentView?.superview ?? window.contentView! }

    // MARK: Glass and backdrops

    static func replaceGlass(in view: NSView, appearance: NSAppearance) {
        if view.className == "NSScrollPocket" { view.isHidden = true; return }
        if let layer = view.layer, NSStringFromClass(type(of: layer)).contains("Backdrop") { view.isHidden = true; return }
        if let glass = view as? NSGlassEffectView, let parent = glass.superview {
            let standIn = GlassStandIn(frame: glass.frame, cornerRadius: glass.cornerRadius)
            standIn.autoresizingMask = glass.autoresizingMask
            parent.addSubview(standIn, positioned: .below, relativeTo: glass)
            if glass.translatesAutoresizingMaskIntoConstraints == false {
                standIn.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    standIn.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                    standIn.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                    standIn.topAnchor.constraint(equalTo: glass.topAnchor),
                    standIn.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
                ])
            }
            if let content = glass.contentView {
                glass.contentView = nil
                standIn.addSubview(content)
                content.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    content.leadingAnchor.constraint(equalTo: standIn.leadingAnchor),
                    content.trailingAnchor.constraint(equalTo: standIn.trailingAnchor),
                    content.topAnchor.constraint(equalTo: standIn.topAnchor),
                    content.bottomAnchor.constraint(equalTo: standIn.bottomAnchor),
                ])
                replaceGlass(in: content, appearance: appearance)
            }
            glass.isHidden = true
            return
        }
        for subview in view.subviews { replaceGlass(in: subview, appearance: appearance) }
    }

    // MARK: Vibrancy

    /// Replaces `CATintedImage` contents by plain images (see the file comment). Plus-lighter text (dark) becomes
    /// white and plus-darker text (light) black, with an opacity that keeps the label hierarchy: the primary label's
    /// tint (0.255 / 0.749 on macOS 26) maps to 88 %.
    static func flattenTintedContents(_ layer: CALayer, appearance: NSAppearance) {
        if let contents = layer.contents, let object = contents as AnyObject?,
           let cls = object_getClass(object), NSStringFromClass(cls) == "CATintedImage",
           let maskObject = object.perform(NSSelectorFromString("image"))?.takeUnretainedValue(),
           CFGetTypeID(maskObject) == CGImage.typeID {
            let mask = maskObject as! CGImage
            let tint = (layer.value(forKey: "contentsMultiplyColor") as! CGColor?) ?? NSColor.labelColor.cgColor
            let filter = layer.compositingFilter as? String
            if let flat = flatten(mask: mask, tint: tint, filter: filter) {
                layer.contents = flat
                layer.setValue(nil, forKey: "contentsMultiplyColor")
                if filter == "plusL" || filter == "plusD" { layer.compositingFilter = nil }
            }
        } else if let filter = layer.compositingFilter as? String, filter == "plusL" || filter == "plusD" {
            layer.compositingFilter = nil
        }
        for sublayer in layer.sublayers ?? [] { flattenTintedContents(sublayer, appearance: appearance) }
    }

    static func flatten(mask: CGImage, tint: CGColor, filter: String?) -> CGImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: mask.width, height: mask.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let color: CGColor
        let components = tint.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        let luminance = components.count >= 3 ? (components[0] + components[1] + components[2]) / 3 : components[0]
        let alpha = components.last ?? 1
        switch filter {
        case "plusL": color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: min(1, luminance / 0.255 * 0.88) * alpha)
        case "plusD": color = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: min(1, (1 - luminance) / 0.251 * 0.88) * alpha)
        default: color = tint
        }
        let rect = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        context.clip(to: rect, mask: mask)          // A8 coverage (or grey, for a non-mask image)
        context.setFillColor(color)
        context.fill(rect)
        return context.makeImage()
    }
}

/// Flat stand-in for a glass surface: a rounded rectangle in a fill a little off the window background, with a
/// hairline, resolved for the view's appearance at draw time.
final class GlassStandIn: NSView {
    let cornerRadius: CGFloat

    init(frame: CGRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        (NSColor.windowBackgroundColor.blended(withFraction: 0.07, of: .labelColor) ?? .windowBackgroundColor).setFill()
        path.fill()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        edge.lineWidth = 1
        NSColor.separatorColor.setStroke()
        edge.stroke()
    }
}

/// Offscreen windows of an inactive app are never key, so AppKit and SwiftUI would draw every control in its
/// inactive look (grey traffic lights, grey default and prominent buttons, grey selection). The harness process only
/// hosts snapshot windows, so it reports the app as active and every window as key and main. The underscored
/// selectors are AppKit's own appearance queries (macOS 26); a missing one is skipped.
enum ActiveWindowAppearance {
    @MainActor static func force() {
        let alwaysTrue: @convention(block) (AnyObject) -> Bool = { _ in true }
        let alwaysTrueWithArgument: @convention(block) (AnyObject, Int) -> Bool = { _, _ in true }
        let windowQueries = ["isKeyWindow", "isMainWindow", "hasKeyAppearance", "hasMainAppearance", "_hasKeyAppearance",
                             "_hasMainAppearance", "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus"]
        for name in windowQueries {
            if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString(name)) {
                method_setImplementation(method, imp_implementationWithBlock(alwaysTrue))
            }
        }
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("_hasActiveAppearanceForStandardWindowButton:")) {
            method_setImplementation(method, imp_implementationWithBlock(alwaysTrueWithArgument))
        }
        if let method = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("isActive")) {
            method_setImplementation(method, imp_implementationWithBlock(alwaysTrue))
        }
    }
}
