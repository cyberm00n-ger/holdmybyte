// Small shared view pieces: card surface, size bar, shimmer, status banner, the glass toast.
import HMBModel
import SwiftUI

extension View {
    /// Tile and card surface (§2.4 S10): `.background.secondary`, corner 16, a separator stroke (Increase Contrast:
    /// `.primary.opacity(0.3)`). Never glass.
    func cardSurface(padding: CGFloat = Tokens.Layout.tilePadding) -> some View {
        modifier(CardSurface(padding: padding))
    }

    /// The redacted-placeholder shimmer for loading values.
    func shimmering(active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

struct CardSurface: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: Tokens.Radius.shape(Tokens.Radius.tile))
            .overlay {
                if contrast == .increased {
                    Tokens.Radius.shape(Tokens.Radius.tile).strokeBorder(.primary.opacity(0.3))
                } else {
                    Tokens.Radius.shape(Tokens.Radius.tile).strokeBorder(.separator)
                }
            }
    }
}

struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering
    @State private var phase = false

    func body(content: Content) -> some View {
        if active && !reduceMotion && !isSnapshotRendering {
            content
                .opacity(phase ? 0.45 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
                .onAppear { phase = true }
        } else {
            content
        }
    }
}

/// 6 pt capsule: track `.fill.tertiary`, fill `.tint` at output/source.
struct SizeBar: View {
    let source: Int64
    let output: Int64

    var body: some View {
        GeometryReader { proxy in
            let fraction = source > 0 ? min(1, max(0, Double(output) / Double(source))) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule().fill(.tint).frame(width: max(Tokens.Layout.sizeBarHeight, proxy.size.width * fraction))
            }
        }
        .frame(height: Tokens.Layout.sizeBarHeight)
        .accessibilityHidden(true)
    }
}

/// StatusBanner (S9, S12): 16 pt symbol · title and message · buttons; `.fill.quaternary`, corner 10, padding 12.
struct StatusBanner<Actions: View>: View {
    let symbol: String
    var symbolStyle: AnyShapeStyle = AnyShapeStyle(.secondary)
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Tokens.Spacing.s12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(symbolStyle)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Spacing.s8)
            HStack(spacing: Tokens.Spacing.s8) { actions() }
                .controlSize(.regular)
        }
        .padding(Tokens.Spacing.s12)
        .background(.fill.quaternary, in: Tokens.Radius.shape(Tokens.Radius.banner))
        .accessibilityElement(children: .contain)
    }
}

/// A transient glass capsule at the bottom of the window (Locate failure and similar).
struct ToastCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, Tokens.Spacing.s16)
            .frame(height: 36)
            .hmbGlass(.regular, in: Capsule())
            .accessibilityAddTraits(.updatesFrequently)
    }
}
