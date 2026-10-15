// S17: the transient menu-bar status item (only while a job runs and the main window is closed).
import AppKit
import HMBModel
import SwiftUI

public struct StatusMenu: View {
    @Bindable public var model: AppModel
    @Environment(\.locale) private var locale

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        if let id = model.state.queue.first, let record = model.record(id) {
            let progress = WeddingPresentation(record).progress(live: model.state.live[id])
            Text(record.name).bold()
            Text(HMBFormat.statusLine(done: progress.photosDone, total: progress.photosTotal, etaSeconds: progress.etaSeconds,
                                      finishing: progress.isFinishing, locale: locale))
            Divider()
            if record.phase == .running {
                Button(Copy.StatusItem.pause) { model.pause(id) }
            } else {
                Button(Copy.StatusItem.resume) { model.resume(id) }
                    .disabled(!model.canResume(record))
            }
            Button(Copy.StatusItem.stop) {
                model.platform.openMainWindow()
                model.requestStop(id)
            }
            Divider()
            Button(Copy.StatusItem.open) { model.platform.openMainWindow() }
        } else {
            Button(Copy.StatusItem.open) { model.platform.openMainWindow() }
        }
    }
}

/// The status item's label: a 16 pt progress ring (template image) plus "58 %".
public struct StatusItemLabel: View {
    public let fraction: Double
    @Environment(\.locale) private var locale

    public init(fraction: Double) { self.fraction = fraction }

    public var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.ring(fraction))
            Text(Copy.StatusItem.percent(fraction, locale: locale)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("holdmybyte, \(Int((fraction * 100).rounded())) percent")
    }

    /// A 16 × 16 pt template image: a faint full track and the progress arc from 12 o'clock, clockwise.
    public static func ring(_ fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let lineWidth: CGFloat = 2
            let inset = rect.insetBy(dx: lineWidth / 2 + 1, dy: lineWidth / 2 + 1)
            let center = NSPoint(x: inset.midX, y: inset.midY)
            let radius = inset.width / 2
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let clamped = max(0, min(1, fraction))
            if clamped > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
