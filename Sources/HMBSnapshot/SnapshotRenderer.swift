// Renders one catalogue entry in one appearance and size (§5.5).
import AppKit
import HMBFixtures
import HMBModel
import HMBUI
import SwiftUI

struct RenderRequest {
    var entry: CatalogueEntry
    var appearance: SnapshotAppearance
    var size: CGSize
    /// True for the additional §6.3 minimum-size renders (changes the file name).
    var isExtraSize: Bool
}

enum SnapshotAppearance: String, CaseIterable, Codable {
    case light, dark
    var nsAppearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
}

struct RenderedImage {
    var image: CGImage
    /// Size in points (the PNG is at the backing scale).
    var pointSize: CGSize
    /// Sheet windows composited on top (window surfaces only).
    var sheets = 0
}

enum RenderError: Error, CustomStringConvertible {
    case captureFailed(String)
    var description: String { switch self { case .captureFailed(let what): "capture failed: \(what)" } }
}

@MainActor
final class SnapshotRenderer {
    let locale: Locale
    let settleSeconds: Double
    let thumbnails = FixtureThumbnails()

    init(locale: Locale, settleSeconds: Double) {
        self.locale = locale
        self.settleSeconds = settleSeconds
    }

    func render(_ request: RenderRequest) throws -> RenderedImage {
        let scenario = request.entry.make()
        let model = AppModel(state: scenario.state, engine: FixtureEngine(scenario.engine),
                             history: InMemoryHistory(scenario.state.records),
                             presetsStore: InMemoryPresets(presets: scenario.state.presets, defaultOn: scenario.state.defaultOn),
                             settingsStore: InMemorySettings(scenario.state.settings), thumbnails: thumbnails)
        // The inert platform says every path exists; S12 needs its delivery folder gone.
        var platform = AppPlatform.inert
        let missing = scenario.missingFolders
        platform.fileExists = { !missing.contains($0) }
        model.platform = platform
        model.volumesChanged()
        let appearance = request.appearance.nsAppearance
        preloadComparePair(model: model)
        switch request.entry.surface {
        case .window:
            return try renderWindow(hosted(RootView(model: model), model: model), size: request.size, appearance: appearance)
        case .settings:
            return try renderSettings(model: model, tab: scenario.state.settingsTab, appearance: appearance)
        case .menuBar:
            return try renderMenuBar(model: model, appearance: appearance)
        case .alert(let alert):
            return try renderAlert(HarnessAlert.copy(for: alert, in: scenario.state, locale: locale), appearance: appearance)
        }
    }

    /// Compare loads its pair asynchronously; a snapshot needs it in the first frame. The pair comes from the
    /// scenario's FixtureEngine (honouring an unavailable original) and is registered with `CompareView.preload`.
    private func preloadComparePair(model: AppModel) {
        guard let compare = model.state.compare, let record = model.compareRecord, let photo = compare.currentPhoto else { return }
        let engine = model.engine
        let delivery = compare.route.delivery
        var pair: ComparePair?
        var done = false
        Task { @MainActor in
            pair = try? await engine.comparePair(record: record, photo: photo, delivery: delivery, maxPixelSize: 2400)
            done = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !done, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        if let pair { CompareView.preload(pair, wedding: record.id, photo: photo, delivery: delivery) }
    }

    /// The environment every hosted view gets: the model (also for `@Environment(AppModel.self)` readers), snapshot
    /// mode (glass falls back to materials) and the run locale.
    private func hosted<V: View>(_ view: V, model: AppModel) -> some View {
        view
            .environment(model)
            .environment(\.isSnapshotRendering, true)
            .environment(\.locale, locale)
    }

    // MARK: Surfaces

    func renderWindow<Content: View>(_ content: Content, size: CGSize, appearance: NSAppearance) throws -> RenderedImage {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let window = OffscreenCapture.mainWindow(size: size, appearance: appearance, content: content)
        defer { close(window, keeping: before) }
        OffscreenCapture.settle(settleSeconds)
        let frame = OffscreenCapture.frameView(of: window)
        guard let base = OffscreenCapture.capture(frame, appearance: appearance)?.cgImage else {
            throw RenderError.captureFailed("main window")
        }
        // Sheets (Edit Delivery, Rename) are separate windows that never attach to an invisible parent: capture each
        // new window and place it where macOS shows a sheet, centred below the toolbar.
        var overlays: [(CGImage, CGRect)] = []
        let toolbarHeight = max(0, window.frame.height - window.contentLayoutRect.maxY)
        for sheet in NSApp.windows where !before.contains(ObjectIdentifier(sheet)) && sheet !== window {
            sheet.appearance = appearance
            // The content view only: unattached, the sheet is a titled window whose 32 pt title bar a presented
            // sheet does not have (it showed as an empty band above the sheet's own title).
            let view = sheet.contentView ?? OffscreenCapture.frameView(of: sheet)
            guard view.bounds.width > 40, view.bounds.height > 40,
                  let image = OffscreenCapture.capture(view, appearance: appearance)?.cgImage else { continue }
            let rect = CGRect(x: (size.width - view.bounds.width) / 2, y: toolbarHeight + 8,
                              width: view.bounds.width, height: view.bounds.height)
            overlays.append((image, rect))
        }
        let image = overlays.isEmpty ? base : composite(base: base, pointSize: size, overlays: overlays, appearance: appearance)
        return RenderedImage(image: image, pointSize: size, sheets: overlays.count)
    }

    private func renderSettings(model: AppModel, tab: SettingsTab, appearance: NSAppearance) throws -> RenderedImage {
        let title = switch tab { case .general: "General"; case .deliveries: "Deliveries"; case .advanced: "Advanced" }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let window = OffscreenCapture.fittingWindow(width: Tokens.Layout.settingsWidth, minHeight: 320, maxHeight: 900, title: title,
                                                    appearance: appearance, content: hosted(SettingsView(model: model), model: model))
        defer { close(window, keeping: before) }
        OffscreenCapture.settle(settleSeconds)
        let frame = OffscreenCapture.frameView(of: window)
        guard let image = OffscreenCapture.capture(frame, appearance: appearance)?.cgImage else {
            throw RenderError.captureFailed("settings window")
        }
        return RenderedImage(image: image, pointSize: frame.bounds.size)
    }

    private func renderMenuBar(model: AppModel, appearance: NSAppearance) throws -> RenderedImage {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let window = OffscreenCapture.panel(minWidth: 260, appearance: appearance,
                                            content: hosted(Self.menuLike(StatusMenu(model: model)), model: model))
        defer { close(window, keeping: before) }
        OffscreenCapture.settle(settleSeconds)
        guard let content = window.contentView,
              let rep = OffscreenCapture.capture(content, appearance: appearance), let image = rep.cgImage else {
            throw RenderError.captureFailed("status menu")
        }
        let size = content.bounds.size
        return RenderedImage(image: onBackground(image, pointSize: size, appearance: appearance, cornerRadius: 10), pointSize: size)
    }

    private func renderAlert(_ copy: AlertContent, appearance: NSAppearance) throws -> RenderedImage {
        let alert = NSAlert()
        alert.messageText = Copy.keepingQuotesTogether(copy.title)
        alert.informativeText = copy.message
        alert.icon = AppIconArt.image(pointSize: 64)
        alert.window.appearance = appearance
        // NSAlert lays buttons out right to left in the order they are added, and gives the first Return.
        let added = copy.buttons.indices.reversed().map { index in (index, alert.addButton(withTitle: copy.buttons[index])) }
        for (index, button) in added {
            button.keyEquivalent = index == copy.defaultButton ? "\r" : (copy.buttons.count == 2 ? "\u{1b}" : "")
            button.hasDestructiveAction = index == copy.destructiveButton
            // The app bundle's AccentColor asset (Scripts/make-icon.sh) makes AppKit draw the default button in the
            // accent; the harness is no bundle, so it sets the same colour on the button.
            if index == copy.defaultButton, Tokens.usesMulticolorAccent {
                button.bezelColor = NSColor(Tokens.Palette.accentMulticolor)
            }
        }
        alert.layout()
        defer { alert.window.close() }
        OffscreenCapture.settle(min(settleSeconds, 0.2))
        guard let content = alert.window.contentView,
              let image = OffscreenCapture.capture(content, appearance: appearance, settleAfterRewrite: 0.05)?.cgImage else {
            throw RenderError.captureFailed("alert")
        }
        let size = content.bounds.size
        return RenderedImage(image: onBackground(image, pointSize: size, appearance: appearance, cornerRadius: 16), pointSize: size)
    }

    // MARK: Helpers

    /// `StatusMenu`'s items laid out like an NSMenu (the real menu is drawn by AppKit, which needs the window
    /// server): leading-aligned rows, borderless items in the label colour, 14 pt row insets.
    private static func menuLike<Content: View>(_ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .buttonStyle(.borderless)
            .tint(.primary)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 260, alignment: .leading)
    }

    private func close(_ window: NSWindow, keeping before: Set<ObjectIdentifier>) {
        for other in NSApp.windows where !before.contains(ObjectIdentifier(other)) && other !== window { other.close() }
        window.contentView = nil
        window.close()
    }

    /// `image` over the appearance's window background in a rounded rectangle (popover/alert/menu surfaces are
    /// transparent once their material is gone).
    private func onBackground(_ image: CGImage, pointSize: CGSize, appearance: NSAppearance, cornerRadius: CGFloat) -> CGImage {
        let scale = CGFloat(image.width) / max(1, pointSize.width)
        guard let context = Self.context(width: image.width, height: image.height) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var fill = CGColor(gray: 0.5, alpha: 1)
        appearance.performAsCurrentDrawingAppearance { fill = NSColor.windowBackgroundColor.cgColor }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius * scale, cornerHeight: cornerRadius * scale, transform: nil))
        context.setFillColor(fill)
        context.fillPath()
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// `base` with each overlay (rect in points, top-left origin) drawn on top, with a soft shadow.
    private func composite(base: CGImage, pointSize: CGSize, overlays: [(CGImage, CGRect)], appearance: NSAppearance) -> CGImage {
        let scale = CGFloat(base.width) / max(1, pointSize.width)
        guard let context = Self.context(width: base.width, height: base.height) else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for (image, rect) in overlays {
            let target = CGRect(x: rect.minX * scale, y: CGFloat(base.height) - rect.maxY * scale,
                                width: rect.width * scale, height: rect.height * scale)
            var fill = CGColor(gray: 0.5, alpha: 1)
            appearance.performAsCurrentDrawingAppearance { fill = NSColor.windowBackgroundColor.cgColor }
            let path = CGPath(roundedRect: target, cornerWidth: 16 * scale, cornerHeight: 16 * scale, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 30 * scale, color: CGColor(gray: 0, alpha: 0.35))
            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.draw(image, in: target)
            context.restoreGState()
        }
        return context.makeImage() ?? base
    }

    nonisolated static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
