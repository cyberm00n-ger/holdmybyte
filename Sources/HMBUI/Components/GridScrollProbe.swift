// Grid scrolling probe (§5.3 acceptance 5): WP5's snapshot harness can call `GridScrollProbe.run` on a hosted
// 2000-photo Done view; WP3's PerformanceTests use it too.
import AppKit
import SwiftUI

/// Scripted scrolling of the detail scroll view: per frame, move the clip view by 24 pt (a fast trackpad flick),
/// lay out and display, for `seconds`. Reports the achieved frame rate (CPU side: layout + draw into the backing store).
@MainActor
public enum GridScrollProbe {
    public struct Result { public var frames: Int; public var seconds: Double; public var worstMs: Double; public var distance: CGFloat
        public var fps: Double { Double(frames) / seconds } }

    public static func run(window: NSWindow, hosting: NSView, seconds: Double, step: CGFloat = 24) -> Result {
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let scroll = largestScrollView(in: hosting) else { return Result(frames: 0, seconds: 1, worstMs: 0, distance: 0) }
        let clip = scroll.contentView
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        var y = clip.bounds.origin.y, direction: CGFloat = 1, frames = 0, worst = 0.0, distance: CGFloat = 0
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(seconds) {
            let frameStart = ContinuousClock.now
            y += direction * step
            if y >= maxY || y <= 0 { direction = -direction; y = min(max(0, y), maxY) }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date())
            distance += step
            frames += 1
            worst = max(worst, Double((ContinuousClock.now - frameStart).components.attoseconds) / 1e15)
        }
        let elapsed = Double((ContinuousClock.now - start).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - start).components.seconds)
        return Result(frames: frames, seconds: elapsed, worstMs: worst, distance: distance)
    }

    static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ v: NSView) {
            if let s = v as? NSScrollView, s.documentView != nil,
               (s.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0),
               !(String(describing: type(of: s)).contains("List")) { best = s }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }
}
