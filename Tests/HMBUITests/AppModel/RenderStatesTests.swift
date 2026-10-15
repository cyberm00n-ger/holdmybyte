// WP3 visual review: renders every WP3 catalogue state offscreen (light and dark, 1120×780 and 780×560) to PNG.
// Gated: runs only with HMB_WP3_RENDER_DIR set (outputs stay local). WP5's hmb-snapshot is the official harness.
import AppKit
import QuartzCore
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct RenderStatesTests {
    nonisolated static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["HMB_WP3_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    @Test(.enabled(if: RenderStatesTests.outputDirectory != nil))
    func renderCatalogue() throws {
        let directory = try #require(Self.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let only = ProcessInfo.processInfo.environment["HMB_WP3_RENDER_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let sizes: [CGSize] = ProcessInfo.processInfo.environment["HMB_WP3_RENDER_SMALL"] == "1"
            ? [CGSize(width: 780, height: 560)]
            : [CGSize(width: 1120, height: Double(ProcessInfo.processInfo.environment["HMB_WP3_RENDER_HEIGHT"] ?? "") ?? 780)]
        var blank: [String] = []
        for id in WP3StateCatalogue.ids where only?.contains(id) ?? true {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for size in sizes {
                    let model = try #require(WP3StateCatalogue.model(id))
                    if ProcessInfo.processInfo.environment["HMB_WP3_RENDER_SIDEBAR"] == "1" { model.state.sidebarVisible = true }
                    let image = Self.render(model: model, id: id, size: size, appearance: appearance)
                    let suffix = (appearance == .aqua ? "light" : "dark") + (size.width < 1000 ? "-small" : "")
                    try #require(image).write(to: directory.appending(path: "\(id)-\(suffix).png"))
                    if let image, Self.isBlank(image) { blank.append("\(id)-\(suffix)") }
                }
            }
        }
        #expect(blank.isEmpty, "blank renders: \(blank)")
    }

    static func render(model: AppModel, id: String, size: CGSize, appearance: NSAppearance.Name) -> Data? {
        let locale = Locale(identifier: "en_DE")
        let root: AnyView
        switch id {
        case "menubar-extra":
            root = AnyView(VStack(alignment: .leading, spacing: 6) { StatusMenu(model: model) }
                .buttonStyle(.borderless).padding(12).frame(width: 300, alignment: .leading)
                .environment(model))
        default:
            root = AnyView(RootView(model: model))
        }
        let hosting = NSHostingView(rootView: root
            .environment(\.isSnapshotRendering, true)
            .environment(\.locale, locale))
        let frame = NSRect(origin: .zero, size: id == "menubar-extra" ? CGSize(width: 300, height: 200) : size)
        let window = OffscreenWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setContentSize(frame.size)
        if ProcessInfo.processInfo.environment["HMB_WP3_RENDER_ORDER"] == "1" {
            // On screen for the window server, but below the desktop window and click-through: invisible to the
            // person using the Mac, never under their pointer.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: 0, y: 0))
            window.orderFrontRegardless()
        }
        defer { window.orderOut(nil) }
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.display()
        CATransaction.flush()
        if ProcessInfo.processInfo.environment["HMB_WP3_RENDER_DEBUG"] == "1" {
            print("window", window.frame, "content", window.contentView!.frame, "hosting", hosting.frame, "safe", hosting.safeAreaInsets)
            func walk(_ v: NSView, _ depth: Int) {
                let name = String(describing: type(of: v))
                if name.contains("Table") || name.contains("Scroll") || name.contains("Outline") || name.contains("Clip") {
                    var extra = ""
                    if let t = v as? NSTableView { extra = " rows=\(t.numberOfRows) visible=\(t.rows(in: t.visibleRect))" }
                    print(String(repeating: " ", count: depth) + name + " \(v.frame)" + extra + " layer=\(v.layer != nil) hidden=\(v.isHidden)")
                }
                for sub in v.subviews { walk(sub, depth + 1) }
            }
            walk(window.contentView!.superview!, 0)
        }
        if id.hasPrefix("alert-"), let alert = model.state.alert {
            let copy = alert.copy(in: model.state)
            let nsAlert = NSAlert()
            nsAlert.messageText = copy.title
            nsAlert.informativeText = copy.message
            // NSAlert's first button is the default one (rightmost).
            let order = [alert.defaultButtonIndex] + copy.buttons.indices.filter { $0 != alert.defaultButtonIndex }
            for index in order { nsAlert.addButton(withTitle: copy.buttons[index]) }
            if let destructive = alert.destructiveButtonIndex, let position = order.firstIndex(of: destructive) {
                nsAlert.buttons[position].hasDestructiveAction = true
            }
            nsAlert.window.appearance = NSAppearance(named: appearance)
            nsAlert.layout()
            guard let view = nsAlert.window.contentView else { return nil }
            return png(view)
        }
        if ProcessInfo.processInfo.environment["HMB_WP3_RENDER_ORDER"] == "1" {
            // The real composited window (glass included) via the window server; needs screen-recording permission.
            let file = FileManager.default.temporaryDirectory.appending(path: "hmb-wp3-\(UUID().uuidString).png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
            try? process.run()
            process.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: file) }
            if let data = try? Data(contentsOf: file) { return data }
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        return png(view)
    }

    /// cacheDisplay does not capture the content of scroll views (Form, List, ScrollView) on macOS 26, so each scroll
    /// view's document view is cached separately and composited over its clip view, outermost first.
    static func png(_ root: NSView) -> Data? {
        root.layoutSubtreeIfNeeded()
        guard let captured = root.bitmapImageRepForCachingDisplay(in: root.bounds),
              let base = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: captured)
        guard let context = NSGraphicsContext(bitmapImageRep: base) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The window background is drawn by the window server, not by the views: paint it first.
        (root.window?.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            root.bounds.fill()
        }
        captured.draw(in: root.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let clip = scroll.contentView
                let visible = document.visibleRect
                if visible.width > 0, visible.height > 0, let rep = document.bitmapImageRepForCachingDisplay(in: visible) {
                    document.cacheDisplay(in: visible, to: rep)
                    var target = clip.convert(clip.bounds, to: root)
                    if root.isFlipped { target.origin.y = root.bounds.height - target.maxY }
                    // Only the area not covered by the scroll view's insets (toolbar, bottom bar).
                    let insets = scroll.contentInsets
                    let flipped = clip.isFlipped != root.isFlipped
                    var visibleArea = target
                    visibleArea.origin.y += flipped ? insets.top : insets.bottom
                    visibleArea.size.height -= insets.top + insets.bottom
                    context.saveGraphicsState()
                    NSBezierPath(rect: visibleArea).addClip()
                    rep.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    context.restoreGraphicsState()
                }
            }
            for sub in view.subviews where !sub.isHidden { visit(sub) }
        }
        visit(root)
        NSGraphicsContext.restoreGraphicsState()
        return base.representation(using: .png, properties: [:])
    }

    static func isBlank(_ png: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: png) else { return true }
        var counts: [UInt32: Int] = [:]
        let stepX = max(1, rep.pixelsWide / 64), stepY = max(1, rep.pixelsHigh / 64)
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
                counts[key, default: 0] += 1
                total += 1
            }
        }
        return Double(counts.values.max() ?? 0) > 0.99 * Double(max(total, 1))
    }
}
