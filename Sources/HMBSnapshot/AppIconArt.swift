// The v1 placeholder app icon (§2.5): a white photo print in front of a teal glass slab. `Scripts/make-icon.sh`
// renders it through `hmb-snapshot --render-icon <dir>`; the harness also uses it as the alert icon.
import AppKit
import CoreGraphics

enum AppIconArt {
    /// The icon at `pixels`×`pixels`.
    static func cgImage(pixels: Int) -> CGImage? {
        guard let context = SnapshotRenderer.context(width: pixels, height: pixels) else { return nil }
        let s = CGFloat(pixels) / 1024
        context.scaleBy(x: s, y: s)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        // macOS icon grid: 824×824 body centred in 1024, corner ≈ 185.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

        // Slab: deep teal to the light accent, top-left light.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.30))
        context.addPath(bodyPath)
        context.setFillColor(color(0x0B7F7B))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(bodyPath)
        context.clip()
        let slab = CGGradient(colorsSpace: srgb, colors: [color(0x3CC8BF), color(0x0E8E89), color(0x075E5B)] as CFArray,
                              locations: [0, 0.55, 1])!
        context.drawLinearGradient(slab, start: CGPoint(x: 180, y: 940), end: CGPoint(x: 860, y: 90), options: [])
        // Glass sheen: a soft diagonal highlight and a bright rim.
        let sheen = CGGradient(colorsSpace: srgb, colors: [color(0xFFFFFF, 0.38), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(sheen, startCenter: CGPoint(x: 300, y: 860), startRadius: 0,
                                   endCenter: CGPoint(x: 300, y: 860), endRadius: 620, options: [])
        context.restoreGState()
        context.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
        context.setStrokeColor(color(0xFFFFFF, 0.45))
        context.setLineWidth(6)
        context.strokePath()

        // Print: a white card, slightly rotated, with a photograph (sky, sun, hills) inside.
        context.saveGState()
        context.translateBy(x: 512, y: 500)
        context.rotate(by: -0.10)
        let card = CGRect(x: -270, y: -215, width: 540, height: 430)
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: CGColor(gray: 0, alpha: 0.38))
        context.addPath(CGPath(roundedRect: card, cornerWidth: 22, cornerHeight: 22, transform: nil))
        context.setFillColor(color(0xFBFBF8))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let photo = card.insetBy(dx: 34, dy: 34).offsetBy(dx: 0, dy: 14).insetBy(dx: 0, dy: 14)
        context.addPath(CGPath(roundedRect: photo, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.clip()
        let sky = CGGradient(colorsSpace: srgb, colors: [color(0xF6C987), color(0xF29E7A), color(0x8C7FB8)] as CFArray,
                             locations: [0, 0.5, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: photo.minY), end: CGPoint(x: 0, y: photo.maxY), options: [])
        context.setFillColor(color(0xFFF4D6))
        context.fillEllipse(in: CGRect(x: 40, y: 10, width: 120, height: 120))
        let hills = CGMutablePath()
        hills.move(to: CGPoint(x: photo.minX, y: photo.minY))
        hills.addLine(to: CGPoint(x: photo.minX, y: -40))
        hills.addCurve(to: CGPoint(x: 40, y: -10), control1: CGPoint(x: -150, y: 40), control2: CGPoint(x: -40, y: 30))
        hills.addCurve(to: CGPoint(x: photo.maxX, y: -60), control1: CGPoint(x: 120, y: -50), control2: CGPoint(x: 180, y: 10))
        hills.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
        hills.closeSubpath()
        context.addPath(hills)
        context.setFillColor(color(0x2F5D50))
        context.fillPath()
        context.restoreGState()
        return context.makeImage()
    }

    static func image(pointSize: CGFloat) -> NSImage {
        let pixels = Int(pointSize * 2)
        guard let cg = cgImage(pixels: pixels) else { return NSImage(size: NSSize(width: pointSize, height: pointSize)) }
        return NSImage(cgImage: cg, size: NSSize(width: pointSize, height: pointSize))
    }

    /// Writes a complete `.iconset` (16…512 pt at 1× and 2×) into `directory`.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let image = cgImage(pixels: points * scale) else { continue }
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try PNGWriter.write(image, to: directory.appending(path: name))
            }
        }
    }
}
