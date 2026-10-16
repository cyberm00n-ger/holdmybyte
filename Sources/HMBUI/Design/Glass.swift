// The single entry point for custom Liquid Glass (Docs/SPEC.md §2.5). Frozen after WP0.
// Glass is used for: Compare HUD, knob, side labels and toasts; the drop-onto-content capsule.
// Never glass: the drop zone, tiles, cards, grid and form rows.
import SwiftUI

extension EnvironmentValues {
    /// True while the snapshot harness renders offscreen (`hmb-snapshot`), which cannot render Liquid Glass.
    /// Glass then falls back to a flat stand-in (`Tokens.Palette.snapshotGlass` with a hairline).
    @Entry public var isSnapshotRendering: Bool = false
}

extension View {
    /// Liquid Glass in `shape`, or a flat stand-in in `shape` when `\.isSnapshotRendering` is true (offscreen,
    /// materials draw without their blur, so a material capsule over a photo vanished and its text sat on the photo).
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
            content
                .background(Tokens.Palette.snapshotGlass, in: shape)
                .overlay { shape.stroke(.separator, lineWidth: 0.5) }
                .shadow(color: Tokens.Palette.snapshotGlassShadow, radius: 6, y: 2)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

struct HMBMaterialModifier<S: Shape>: ViewModifier {
    let material: Material
    let shape: S
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    func body(content: Content) -> some View {
        if isSnapshotRendering {
            content.background(Tokens.Palette.snapshotGlass, in: shape)
        } else {
            content.background(material, in: shape)
        }
    }
}

struct HMBGlassButtonStyleModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering

    func body(content: Content) -> some View {
        switch (prominent, isSnapshotRendering) {
        case (true, false): content.buttonStyle(.glassProminent)
        case (false, false): content.buttonStyle(.glass).hmbNeutralButtonTint()
        case (true, true): content.buttonStyle(.borderedProminent)
        case (false, true): content.buttonStyle(.bordered).hmbNeutralButtonTint()
        }
    }
}

extension View {
    /// A secondary push or glass button (Cancel, Choose Photos…, Spot-Check…) draws like the system's: neutral bezel,
    /// label colour. The app's root `.tint` (Multicolor accent, §2.5) would otherwise colour its label and bezel teal,
    /// which macOS never does for a secondary button and §2.5's accent list does not allow.
    public func hmbNeutralButtonTint() -> some View { tint(nil) }

    /// A toolbar or HUD menu (Delivery, Zoom, More, the Compare order menu): its symbol and title draw in the label
    /// colour like the toolbar's buttons. Menus pick up the root `.tint`, which §2.5 reserves for the listed elements.
    public func hmbMenuLabelTint() -> some View { tint(.primary) }

    /// A SwiftUI material behind a small label over a photo (score capsules, grid badges); under
    /// `isSnapshotRendering` the same flat stand-in as `hmbGlass`, because offscreen materials draw without their blur.
    public func hmbMaterial(_ material: Material, in shape: some Shape) -> some View {
        modifier(HMBMaterialModifier(material: material, shape: shape))
    }
}
