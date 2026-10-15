// Differences (Docs/SPEC.md §2.4 S14, `D`): |delivered − original| × 10, coloured in the accent, over the original's
// luma darkened to 30 %. Core Image on the GPU: CIDifferenceBlendMode, then a colour matrix. Computed in the
// gamma-encoded sRGB working space so the amplification follows what the eye sees, not linear light.
import AppKit
import CoreImage
import HMBModel

enum CompareDifferences {
    static let amplification: CGFloat = 10
    static let baseBrightness: CGFloat = 0.3

    private static let context: CIContext = {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB, .cacheIntermediates: false,
                                   .name: "holdmybyte.compare.differences"])
    }()

    /// The differences image at the original's pixel size. `tint` is an sRGB colour (the accent).
    static func image(original: CGImage, delivered: CGImage, tint: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGImage? {
        // Photos are opaque; flatten anyway so transparent pixels (PNG sources, synthetic fixtures) compare as black.
        let rawBase = CIImage(cgImage: original)
        let black = CIImage(color: .black).cropped(to: rawBase.extent)
        let base = rawBase.composited(over: black)
        var top = CIImage(cgImage: delivered).composited(over: CIImage(color: .black).cropped(to: CIImage(cgImage: delivered).extent))
        if top.extent.size != base.extent.size, top.extent.width > 0, top.extent.height > 0 {
            top = top.transformed(by: CGAffineTransform(scaleX: base.extent.width / top.extent.width,
                                                        y: base.extent.height / top.extent.height))
        }
        let difference = top.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: base])
        // Colour = the tint; alpha = 10 × Rec. 709 luma of |Δ|, clamped.
        let k = amplification
        let overlay = difference
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0.2126 * k, y: 0.7152 * k, z: 0.0722 * k, w: 0),
                "inputBiasVector": CIVector(x: tint.red, y: tint.green, z: tint.blue, w: 0),
            ])
            .applyingFilter("CIColorClamp")
        let b = baseBrightness
        let darkened = base
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126 * b, y: 0.7152 * b, z: 0.0722 * b, w: 0),
                "inputGVector": CIVector(x: 0.2126 * b, y: 0.7152 * b, z: 0.0722 * b, w: 0),
                "inputBVector": CIVector(x: 0.2126 * b, y: 0.7152 * b, z: 0.0722 * b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        let composite = overlay.composited(over: darkened)
        return context.createCGImage(composite, from: rawBase.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// The accent as sRGB components for `appearance` (the app's teal under Multicolor, else the system accent).
    @MainActor static func tint(for appearance: NSAppearance?) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let color = Tokens.usesMulticolorAccent ? NSColor(Tokens.Palette.accentMulticolor) : NSColor.controlAccentColor
        var resolved = NSColor.systemTeal
        (appearance ?? NSAppearance(named: .darkAqua)!).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .systemTeal
        }
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
    }
}
