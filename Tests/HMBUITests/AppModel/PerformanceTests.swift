// §5.3 acceptance 5 (WP3 side): the history Done view loads in ≤ 100 ms; a 2000-photo grid scrolls at ≥ 110 fps.
// Timing is machine-load dependent, so these run only with HMB_WP3_PERF=1 and print their numbers (with `uptime`).
// WP5's snapshot harness owns the official signpost benchmark; `GridScrollProbe` below is what it can reuse.
import AppKit
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct PerformanceTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["HMB_WP3_PERF"] == "1" }

    /// §5.5 quiet-machine rule: timing gates are only asserted when the 1-minute load average is below 3.
    static var isQuiet: Bool {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads[0] < 3
    }

    static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }

    /// A finished wedding with `count` photos and the four built-in deliveries.
    static func bigWedding(_ count: Int) -> WeddingRecord {
        let photos = FixtureFactory.photos(count: count, totalBytes: Int64(count) * 20_500_000,
                                           root: URL(fileURLWithPath: "/Users/sebastian/Weddings/Big/fertig", isDirectory: true),
                                           firstCapture: FixtureFactory.date(2026, 6, 6, 11), hours: 12, camera: "ILCE-1",
                                           pixelSize: (8640, 5760), seed: 42)
        var record = Fixtures.finnUndLissy
        record.id = FixtureFactory.weddingID(4242)
        record.name = "Big Wedding"
        record.photos = photos
        record.results = DeliveryPreset.builtIns.flatMap { preset in
            FixtureFactory.results(photos: photos, preset: preset, wedding: "Big Wedding",
                                   outputTotal: Int64(Double(count) * 20_500_000 * (preset.isFullSize ? 0.12 : 0.015)),
                                   scores: preset.isLossy ? FixtureFactory.scores(count: count, min: 74, max: 77, median: 74.6, seed: 9) : nil,
                                   seed: 7)
        }
        return record
    }

    static func window(_ model: AppModel, size: CGSize = Tokens.Layout.windowDefault) -> (NSWindow, NSHostingView<AnyView>) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: AnyView(RootView(model: model).environment(\.isSnapshotRendering, true)))
        let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        precondition(window.frame.origin.x < -10_000, "the perf window must stay off screen")
        return (window, hosting)
    }

    @Test(.enabled(if: PerformanceTests.enabled)) func historyDoneViewLoadsQuickly() throws {
        var state = AppState()
        state.sidebarVisible = true
        state.records = Fixtures.history
        let model = AppModel(state: state, engine: FixtureEngine(), history: InMemoryHistory(), presetsStore: InMemoryPresets(),
                             settingsStore: InMemorySettings(), thumbnails: FixtureThumbnails(photoFolder: nil))
        let (window, hosting) = Self.window(model)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        var samples: [Double] = []
        for round in 0..<6 {
            // Alternate between two finished weddings so every measurement is a fresh Done view.
            let target = round.isMultiple(of: 2) ? Fixtures.finnUndLissyID : Fixtures.history[5].id
            let start = ContinuousClock.now
            model.select(.wedding(target))
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            samples.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
        }
        let sorted = samples.dropFirst().sorted()
        let median = sorted[sorted.count / 2]
        print("WP3-PERF done-view-load ms: \(samples.map { String(format: "%.1f", $0) }) median \(String(format: "%.1f", median)) (\(Self.load()))")
        if Self.isQuiet { #expect(median <= 100) }
    }

    @Test(.enabled(if: PerformanceTests.enabled)) func gridScrollsAt110FPS() throws {
        let record = Self.bigWedding(2000)
        var state = AppState()
        state.sidebarVisible = true
        state.records = [record]
        state.selection = .wedding(record.id)
        let model = AppModel(state: state, engine: FixtureEngine(), history: InMemoryHistory(), presetsStore: InMemoryPresets(),
                             settingsStore: InMemorySettings(), thumbnails: FixtureThumbnails(photoFolder: nil))
        let (window, hosting) = Self.window(model)
        defer { window.orderOut(nil) }
        let result = GridScrollProbe.run(window: window, hosting: hosting, seconds: 3)
        print("WP3-PERF grid-scroll 2000 cells: \(result.frames) frames in \(String(format: "%.2f", result.seconds)) s = "
              + "\(String(format: "%.0f", result.fps)) fps, worst frame \(String(format: "%.1f", result.worstMs)) ms, "
              + "scrolled \(Int(result.distance)) pt (\(Self.load()))")
        #expect(result.distance > 2000)
        if Self.isQuiet { #expect(result.fps >= 110) }
    }
}

@MainActor @Suite struct PresentationCostProbe {
    @Test(.enabled(if: PerformanceTests.enabled)) func presentationCost() {
        let record = Fixtures.finnUndLissy
        let clock = ContinuousClock()
        var t = clock.now
        func lap(_ name: String) { print("WP3-PERF \(name): \(String(format: "%.2f", Double((clock.now - t).components.attoseconds) / 1e15)) ms"); t = clock.now }
        let p = WeddingPresentation(record); lap("latest")
        for preset in record.deliveries { _ = p.summary(preset) }; lap("4 summaries")
        _ = p.cells(delivery: nil, sort: .captureTime, issuesOnly: false); lap("cells")
        _ = p.issueGroups; lap("issueGroups")
        _ = p.lowest(5, delivery: record.deliveries[0]); lap("lowest")
        _ = p.metTarget(record.deliveries[0]); lap("metTarget")
        _ = record.photosFinished; lap("photosFinished")
        var state = AppState(); state.records = Fixtures.history
        _ = SidebarSections(state, locale: .current); lap("sidebar sections (cold)")
        _ = SidebarSections(state, locale: .current); lap("sidebar sections (warm)")
    }
}
