// S19 Dock tile: the app icon with a 6 pt accent progress bar at the bottom while running; the badge counts finished
// weddings the user has not viewed yet.
import AppKit
import HMBUI
import SwiftUI

@MainActor
final class DockTileController {
    private let view = DockProgressView()
    private var lastProgress: Double?
    private var lastBadge = -1

    func update(progress: Double?, badge: Int) {
        let tile = NSApplication.shared.dockTile
        // Redraw at most once per percent.
        let rounded = progress.map { ($0 * 100).rounded() / 100 }
        if rounded != lastProgress {
            lastProgress = rounded
            view.progress = rounded
            tile.contentView = rounded == nil ? nil : view
            tile.display()
        }
        if badge != lastBadge {
            lastBadge = badge
            tile.badgeLabel = badge > 0 ? "\(badge)" : nil
        }
    }
}

final class DockProgressView: NSView {
    var progress: Double? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSApplication.shared.applicationIconImage?.draw(in: bounds)
        guard let progress else { return }
        let height: CGFloat = bounds.height * 6 / 64            // 6 pt on a 64 pt tile
        let inset = bounds.width * 0.12
        let track = NSRect(x: inset, y: bounds.height * 0.06, width: bounds.width - 2 * inset, height: height)
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        var fill = track
        fill.size.width = max(height, track.width * CGFloat(max(0, min(1, progress))))
        accentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
    }

    private var accentColor: NSColor {
        Tokens.usesMulticolorAccent ? NSColor(Tokens.Palette.accentMulticolor) : .controlAccentColor
    }
}
