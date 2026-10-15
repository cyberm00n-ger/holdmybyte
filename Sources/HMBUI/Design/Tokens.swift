// Visual tokens (Docs/SPEC.md §2.5, §2.7). Frozen after WP0. Views never use literal colours or sizes outside this
// file; the single exception is the 1 px separator, which is always `.separator`.
import AppKit
import SwiftUI

public enum Tokens {
    // MARK: Colour

    public enum Palette {
        /// `.tint` at the root only when the system accent is Multicolor (see `View.hmbAccent()`). #0B7F7B / #3CC8BF.
        public static let accentMulticolor = adaptive(light: 0x0B7F7B, dark: 0x3CC8BF, name: "accentMulticolor")
        /// Compare background, the photographer's neutral surround. #F2F2F2 / #1C1C1E.
        public static let compareSurround = adaptive(light: 0xF2F2F2, dark: 0x1C1C1E, name: "compareSurround")
        /// Warnings and the issues edge.
        public static let warning = Color.orange
        /// Failures.
        public static let failure = Color.red
        /// Info symbols.
        public static let info = HierarchicalShapeStyle.secondary
        /// Compare split divider (§2.4 S14): a white line with a dark 0.5 pt shadow, over any photo, in both appearances.
        public static let compareDivider = Color.white
        public static let compareDividerShadow = Color.black.opacity(0.6)

        static func adaptive(light: UInt32, dark: UInt32, name: String) -> Color {
            Color(nsColor: NSColor(name: NSColor.Name("hmb." + name)) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(srgbHex: isDark ? dark : light)
            })
        }
    }

    /// True when the user's system accent is Multicolor (`AppleAccentColor` unset); then the app tints with
    /// `Palette.accentMulticolor`, otherwise with the system accent.
    public static var usesMulticolorAccent: Bool {
        forcesMulticolorAccent || UserDefaults.standard.object(forKey: "AppleAccentColor") == nil
    }

    /// Set once at launch by the snapshot harness, so snapshots show the shipped teal accent whoever renders them.
    nonisolated(unsafe) public static var forcesMulticolorAccent = false

    // MARK: Spacing (4 pt grid)

    public enum Spacing {
        public static let s4: CGFloat = 4
        public static let s6: CGFloat = 6
        public static let s8: CGFloat = 8
        public static let s12: CGFloat = 12
        public static let s16: CGFloat = 16
        public static let s20: CGFloat = 20
        public static let s24: CGFloat = 24
        public static let s32: CGFloat = 32
    }

    // MARK: Corner radii (all `.continuous`)

    public enum Radius {
        public static let dropZone: CGFloat = 22
        public static let tile: CGFloat = 16          // tiles and cards
        public static let banner: CGFloat = 10        // status banners
        public static let mosaic: CGFloat = 10
        public static let iconWell: CGFloat = 7
        public static let thumbnail: CGFloat = 6

        public static func shape(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    }

    // MARK: Layout

    public enum Layout {
        public static let windowDefault = CGSize(width: 1120, height: 780)
        public static let windowMinimum = CGSize(width: 780, height: 560)
        public static let setupColumnMaxWidth: CGFloat = 760
        public static let doneHeaderMaxWidth: CGFloat = 900
        public static let settingsWidth: CGFloat = 600
        public static let sidebarRowHeight: CGFloat = 44
        public static let deliveryRowMinHeight: CGFloat = 56
        public static let setupHeaderHeight: CGFloat = 88
        public static let bottomBarHeight: CGFloat = 64
        public static let tileMinHeight: CGFloat = 168
        public static let tilePadding: CGFloat = 18
        public static let sizeBarHeight: CGFloat = 6
        public static let gridCellMinimum: CGFloat = 116
        public static let gridCellMaximum: CGFloat = 168
        public static let gridSpacing: CGFloat = 6
        public static let proofThumb = CGSize(width: 96, height: 64)
    }

    // MARK: Typography (SF Pro only; monospaced only for file-name previews)

    public enum Typography {
        /// Tile hero number: 34 pt semibold (add `.monospacedDigit()`).
        public static let tileHero = Font.system(size: 34, weight: .semibold)
        /// Running saved counter and drop title: 28 pt semibold.
        public static let counter = Font.system(size: 28, weight: .semibold)
        public static let dropTitle = Font.system(size: 28, weight: .semibold)
        /// Done title: 26 pt semibold.
        public static let doneTitle = Font.system(size: 26, weight: .semibold)
        /// Setup name and run title: 22 pt semibold.
        public static let title = Font.system(size: 22, weight: .semibold)
        /// Section and tile titles.
        public static let sectionTitle = Font.headline
        public static let body = Font.body
        /// Secondary lines (with `.secondary`).
        public static let secondary = Font.callout
        /// Meta and footers (with `.secondary` / `.tertiary`).
        public static let meta = Font.caption
        /// File-name previews only.
        public static let fileName = Font.caption.monospaced()
        public static let dropSymbol = Font.system(size: 64, weight: .light)
        public static let doneSeal = Font.system(size: 34)
        public static let deliverySymbol = Font.system(size: 17)
        public static let statusBadge = Font.system(size: 14)
        public static let sidebarAccessory = Font.system(size: 11)
    }

    // MARK: Motion (§2.7)

    public enum Motion {
        /// Default spring.
        public static let spring = Animation.spring(response: 0.32, dampingFraction: 0.85)
        /// State morphs (empty → setup → running → done).
        public static let morph = Animation.smooth(duration: 0.35)
        /// Photo done: saturation 0 → 1.
        public static let photoDone = Animation.easeOut(duration: 0.25)
        /// Reduce Motion: opacity crossfades only.
        public static let reducedCrossfade = Animation.easeInOut(duration: 0.2)
        /// Tile hero count-down (first appearance only).
        public static let countDown = Animation.easeOut(duration: 0.6)
        public static let dragTargetScale: CGFloat = 1.02
        public static let scanStagger: Double = 0.015
        public static let scanStaggerCap = 40
        /// Engine events are coalesced to at most this many UI updates per second.
        public static let maxUIUpdatesPerSecond: Double = 10

        public static func standard(reduceMotion: Bool) -> Animation { reduceMotion ? reducedCrossfade : spring }
        public static func stateMorph(reduceMotion: Bool) -> Animation { reduceMotion ? reducedCrossfade : morph }
    }
}

extension View {
    /// Applies `Tokens.Palette.accentMulticolor` as the tint when the system accent is Multicolor. Use at the root only.
    public func hmbAccent() -> some View { modifier(HMBAccentModifier()) }
}

struct HMBAccentModifier: ViewModifier {
    func body(content: Content) -> some View {
        if Tokens.usesMulticolorAccent { content.tint(Tokens.Palette.accentMulticolor) } else { content }
    }
}

extension NSColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
