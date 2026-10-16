// WP0: the frozen UI contracts compile and behave (AppState defaults, side-effect-free AppModel.init, tokens).
import HMBFixtures
import HMBModel
@testable import HMBUI
import SwiftUI
import Testing

@MainActor @Suite struct ScaffoldUITests {
    @Test func appStateDefaults() {
        let state = AppState()
        #expect(state.selection == .newWedding)
        #expect(state.presets == DeliveryPreset.builtIns)
        #expect(state.defaultOn == [.couple, .website])
        #expect(state.settings == AppSettings())
        #expect(state.windowOpen && !state.sidebarVisible)
    }

    @Test func appModelInitHasNoSideEffects() async throws {
        var state = AppState()
        state.records = [Fixtures.finnUndLissy]
        let history = InMemoryHistory()
        let model = AppModel(state: state, engine: FixtureEngine(), history: history, presetsStore: InMemoryPresets(),
                             settingsStore: InMemorySettings(), thumbnails: FixtureThumbnails(photoFolder: nil))
        #expect(model.state == state)
        #expect(try await history.loadAll().isEmpty)
        #expect(await history.saveCount == 0)
    }

    @Test func tokens() {
        #expect(Tokens.Radius.dropZone == 22 && Tokens.Radius.tile == 16 && Tokens.Radius.thumbnail == 6)
        #expect([Tokens.Spacing.s4, Tokens.Spacing.s6, Tokens.Spacing.s8, Tokens.Spacing.s12, Tokens.Spacing.s16,
                 Tokens.Spacing.s20, Tokens.Spacing.s24, Tokens.Spacing.s32] == [4, 6, 8, 12, 16, 20, 24, 32])
        let light = NSColor(Tokens.Palette.accentMulticolor)
        var resolved: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { resolved = light.usingColorSpace(.sRGB) }
        #expect(abs((resolved?.redComponent ?? 0) - 11.0 / 255) < 0.01)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { resolved = light.usingColorSpace(.sRGB) }
        #expect(abs((resolved?.greenComponent ?? 0) - 148.0 / 255) < 0.01)      // #15948C (Docs/DECISIONS.md)
        var environment = EnvironmentValues()
        #expect(!environment.isSnapshotRendering)
        environment.isSnapshotRendering = true
        #expect(environment.isSnapshotRendering)
    }
}
