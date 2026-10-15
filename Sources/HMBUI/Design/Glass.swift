// The single entry point for custom Liquid Glass (Docs/SPEC.md §2.5). Frozen after WP0.
// Glass is used for: Compare HUD, knob, side labels and toasts; the drop-onto-content capsule.
// Never glass: the drop zone, tiles, cards, grid and form rows.
import SwiftUI

extension EnvironmentValues {
    /// True while the snapshot harness renders offscreen (`hmb-snapshot`), which cannot render Liquid Glass.
    /// Glass then falls back to `.regularMaterial`.
    @Entry public var isSnapshotRendering: Bool = false
}

extension View {
    /// Liquid Glass in `shape`, or `.regularMaterial` in `shape` when `\.isSnapshotRendering` is true.
    public func hmbGlass(_ glass: Glass = .regular, in shape: some Shape = Capsule()) -> some View {
        modifier(HMBGlassModifier(glass: glass, shape: shape))
    }

    /// `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`, falling back to `.bordered` / `.borderedProminent`
    /// while snapshot rendering. Use for `Choose Photos…`, `Spot-Check…` and the primary commit button.
    public func hmbGlassButtonStyle(prominent: Bool = false) -> some View {
        modifier(HMBGlassButtonStyleModifier(prominent: prominent))
    }
}

struct HMBGlassModifier<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    func body(content: Content) -> some View {
        if isSnapshotRendering {
            content.background(.regularMaterial, in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

struct HMBGlassButtonStyleModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    func body(content: Content) -> some View {
        switch (prominent, isSnapshotRendering) {
        case (true, false): content.buttonStyle(.glassProminent)
        case (false, false): content.buttonStyle(.glass)
        case (true, true): content.buttonStyle(.borderedProminent)
        case (false, true): content.buttonStyle(.bordered)
        }
    }
}
