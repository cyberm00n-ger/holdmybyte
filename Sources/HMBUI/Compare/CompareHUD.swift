// Compare overlays (Docs/SPEC.md §2.4 S14): the HUD capsule, side labels, centred capsules and the divider knob.
import HMBModel
import SwiftUI

struct CompareHUD: View {
    @Bindable var model: AppModel
    let compare: CompareState
    let result: PhotoResult?
    let originalBytes: Int64
    let isLoading: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: Tokens.Spacing.s4) {
            Button { model.stepCompare(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(compare.position == 0)
            .help("Previous Photo (←)")
            .accessibilityLabel("Previous Photo")

            Text(CompareCopy.counter(compare, locale: locale))
                .monospacedDigit()
                .frame(minWidth: 96)
                .accessibilityLabel("Photo \(CompareCopy.counter(compare, locale: locale))")

            Button { model.stepCompare(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(compare.position >= compare.sequence.count - 1 && !(compare.route.spotCheck && !compare.spotCheckToastShown))
            .help("Next Photo (→)")
            .accessibilityLabel("Next Photo")

            Divider().frame(height: 20)

            ScorePill(result: result)

            if let out = result?.outBytes {
                Text(CompareCopy.sizeLine(original: originalBytes, delivered: out, locale: locale))
                    .font(.callout).monospacedDigit().lineLimit(1).fixedSize()
            }

            if isLoading {
                ProgressView().controlSize(.mini).help("Loading full resolution")
            }

            Divider().frame(height: 20)

            Menu(CompareCopy.orderTitle(compare.order)) {
                ForEach([CompareOrder.captureTime, .lowestScore, .largestSavings], id: \.self) { order in
                    Button { model.setCompareOrder(order) } label: {
                        if order == compare.order { Label(CompareCopy.orderTitle(order), systemImage: "checkmark") }
                        else { Text(CompareCopy.orderTitle(order)) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Order of the photos")
        }
        .padding(.horizontal, Tokens.Spacing.s6 + Tokens.Spacing.s6)
        .frame(height: 44)
        .hmbGlass(in: Capsule())
    }
}

/// The score: a capsule in the accent; orange (with a warning symbol) only if below the target, which must never happen.
struct ScorePill: View {
    let result: PhotoResult?

    var body: some View {
        if result?.status == .keptOriginal {
            Label("Kept original", systemImage: "equal.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Spacing.s8).padding(.vertical, 2)
                .background(.fill.tertiary, in: Capsule())
        } else if let score = result?.score {
            let below = (result?.target).map { score < $0 } ?? false
            HStack(spacing: 3) {
                if below { Image(systemName: "exclamationmark.triangle.fill") }
                Text(HMBFormat.score(score)).monospacedDigit()
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(below ? AnyShapeStyle(Tokens.Palette.warning) : AnyShapeStyle(.tint))
            .padding(.horizontal, Tokens.Spacing.s8).padding(.vertical, 2)
            .background(below ? AnyShapeStyle(Tokens.Palette.warning.opacity(0.15)) : AnyShapeStyle(.tint.opacity(0.15)), in: Capsule())
            .accessibilityLabel(below ? "Score \(HMBFormat.score(score)), below target" : "Score \(HMBFormat.score(score))")
        }
    }
}

/// A 24 pt glass capsule with a caption (side labels, legend, "Original", the no-original note, toasts).
struct CompareCapsule: View {
    let text: String
    var symbol: String? = nil
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: Tokens.Spacing.s6) {
            if let symbol { Image(systemName: symbol) }
            Text(text).monospacedDigit().lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, Tokens.Spacing.s12)
        .frame(height: height)
        .hmbGlass(in: Capsule())
    }
}

/// The split divider: a 1.5 pt white line with a 0.5 pt dark shadow, and a 30 pt glass knob.
struct CompareDivider: View {
    @Bindable var model: AppModel
    let x: CGFloat
    let width: CGFloat
    let height: CGFloat
    let divider: Double

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Tokens.Palette.compareDivider)
                .frame(width: 1.5)
                .shadow(color: Tokens.Palette.compareDividerShadow, radius: 0, x: 0.5, y: 0)
                .shadow(color: Tokens.Palette.compareDividerShadow, radius: 0, x: -0.5, y: 0)
                .allowsHitTesting(false)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .hmbGlass(.regular.interactive(), in: Circle())
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(CompareView.coordinateSpace))
                    .onChanged { value in model.updateCompare { $0.divider = Double(value.location.x / max(1, width)) } })
                .accessibilityElement()
                .accessibilityLabel("Divider")
                .accessibilityValue("Divider at \(Int((divider * 100).rounded())) percent")
                .accessibilityAdjustableAction { direction in
                    model.updateCompare {
                        switch direction {
                        case .increment: $0.divider = min(1, ($0.divider * 10).rounded() / 10 + 0.1)
                        case .decrement: $0.divider = max(0, ($0.divider * 10).rounded() / 10 - 0.1)
                        @unknown default: break
                        }
                    }
                }
                .accessibilityAction(named: "Show Original") { model.toggleCompareOriginalLatch() }
        }
        .frame(width: 30, height: height)
        .position(x: x, y: height / 2)
    }
}
