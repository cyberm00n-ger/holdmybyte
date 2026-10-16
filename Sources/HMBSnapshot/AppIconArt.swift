// The app icon (§2.5), drawn in code: a photo print held between two brackets ("hold my byte") on the teal accent.
// `Scripts/make-icon.sh` writes it as an Icon Composer file (`--render-assets`), which actool compiles into the
// Liquid Glass icon (with its dark, clear and tinted variants) plus an .icns fallback; the harness uses the flat
// composite below as the alert and Dock icon, because it cannot run actool's glass renderer.
import AppKit
import CoreGraphics
import HMBUI
import SwiftUI

enum AppIconArt {
    /// Layer canvas (Icon Composer's 1024 × 1024 point grid, which maps to the icon's rounded square).
    static let canvas: CGFloat = 1024

    /// The background fill, top to bottom: a lighter and a deeper shade of the accent.
    static let fillTop: UInt32 = 0x34C3B9
    static let fillBottom: UInt32 = 0x08706C

    // MARK: Shapes (top-left origin, canvas points)

    /// The print: a landscape card with the sun and two hills cut out (like SF Symbols' `photo.fill`).
    static let card = CGRect(x: 252, y: 312, width: 520, height: 400)
    static let cardRadius: CGFloat = 60

    static func cardPath() -> CGPath {
        let path = CGMutablePath()
        path.addPath(continuous(card, radius: cardRadius))
        // Cut-outs (even-odd): the sun and the hills, inside the print's border.
        path.addEllipse(in: CGRect(x: 596, y: 380, width: 96, height: 96))
        let inner = card.insetBy(dx: 52, dy: 52)
        let hills = CGMutablePath()
        hills.move(to: CGPoint(x: inner.minX, y: inner.maxY - 70))
        hills.addLine(to: CGPoint(x: 418, y: 470))
        hills.addQuadCurve(to: CGPoint(x: 452, y: 470), control: CGPoint(x: 435, y: 452))
        hills.addLine(to: CGPoint(x: 560, y: 572))
        hills.addLine(to: CGPoint(x: 600, y: 534))
        hills.addQuadCurve(to: CGPoint(x: 634, y: 534), control: CGPoint(x: 617, y: 517))
        hills.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY - 46))
        hills.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
        hills.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
        hills.closeSubpath()
        // Keep the cut inside the inner area, its corners rounded concentrically with the card's.
        path.addPath(hills.intersection(continuous(inner, radius: 22)))
        return path
    }

    /// The brackets: two rounded, heavy square brackets that hold the print.
    static let bracketWidth: CGFloat = 52
    static func bracketsPath() -> CGPath {
        let top: CGFloat = 262, bottom: CGFloat = 762, reach: CGFloat = 70
        let left: CGFloat = 178, right: CGFloat = canvas - 178
        let line = CGMutablePath()
        line.move(to: CGPoint(x: left + reach, y: top))
        line.addLine(to: CGPoint(x: left, y: top))
        line.addLine(to: CGPoint(x: left, y: bottom))
        line.addLine(to: CGPoint(x: left + reach, y: bottom))
        line.move(to: CGPoint(x: right - reach, y: top))
        line.addLine(to: CGPoint(x: right, y: top))
        line.addLine(to: CGPoint(x: right, y: bottom))
        line.addLine(to: CGPoint(x: right - reach, y: bottom))
        return line.copy(strokingWithWidth: bracketWidth, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    static func continuous(_ rect: CGRect, radius: CGFloat) -> CGPath {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    }

    // MARK: Layers

    /// The layers, back to front, with their fill rule (the print's cut-outs are even-odd; the stroked brackets
    /// overlap themselves at the corners and need the winding rule).
    static var layers: [(name: String, path: CGPath, rule: CGPathFillRule)] {
        [("print", cardPath(), .evenOdd), ("brackets", bracketsPath(), .winding)]
    }

    /// One white layer (Icon Composer tints and lights it).
    static func layer(_ path: CGPath, rule: CGPathFillRule, pixels: Int) -> CGImage? {
        guard let context = flippedContext(pixels: pixels) else { return nil }
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath(using: rule)
        return context.makeImage()
    }

    // MARK: Flat composite (alert and Dock icon in the harness)

    /// The icon at `pixels`×`pixels`: the 824-point rounded square of the macOS grid, centred in 1024.
    static func cgImage(pixels: Int) -> CGImage? {
        guard let context = flippedContext(pixels: pixels) else { return nil }
        let k = CGFloat(pixels) / canvas           // shadows are in device space (y up), unscaled by the CTM
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let bodyPath = continuous(body, radius: 185)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(bodyPath)
        context.setFillColor(color(fillBottom))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(bodyPath)
        context.clip()
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let fill = CGGradient(colorsSpace: srgb, colors: [color(fillTop), color(fillBottom)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(fill, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
        // The artwork, on the body's grid, with the soft shadow glass layers cast.
        context.translateBy(x: body.minX, y: body.minY)
        context.scaleBy(x: body.width / canvas, y: body.height / canvas)
        for layer in layers {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 30 * k, color: CGColor(gray: 0, alpha: 0.22))
            context.addPath(layer.path)
            context.setFillColor(CGColor(gray: 1, alpha: 0.96))
            context.fillPath(using: layer.rule)
            context.restoreGState()
        }
        context.restoreGState()
        // A light rim, as the system draws on glass icons.
        context.addPath(continuous(body.insetBy(dx: 1.5, dy: 1.5), radius: 183.5))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
        context.setLineWidth(3)
        context.strokePath()
        return context.makeImage()
    }

    static func image(pointSize: CGFloat) -> NSImage {
        let pixels = Int(pointSize * 2)
        guard let cg = cgImage(pixels: pixels) else { return NSImage(size: NSSize(width: pointSize, height: pointSize)) }
        return NSImage(cgImage: cg, size: NSSize(width: pointSize, height: pointSize))
    }

    // MARK: Asset sources for actool

    /// Writes `AppIcon.icon` (Icon Composer) and `Assets.xcassets` (the `AccentColor`, from `Tokens`) into
    /// `directory`, plus `AppIcon-flat.png` (the flat composite at 1024, for review).
    static func writeAssetSources(to directory: URL) throws {
        let fm = FileManager.default
        let icon = directory.appending(path: "AppIcon.icon")
        let assets = icon.appending(path: "Assets")
        try? fm.removeItem(at: icon)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        for layer in layers {
            guard let image = Self.layer(layer.path, rule: layer.rule, pixels: Int(canvas)) else { throw CocoaError(.fileWriteUnknown) }
            try PNGWriter.write(image, to: assets.appending(path: "\(layer.name).png"))
        }
        try Data(iconJSON.utf8).write(to: icon.appending(path: "icon.json"))

        let catalog = directory.appending(path: "Assets.xcassets")
        let accent = catalog.appending(path: "AccentColor.colorset")
        try? fm.removeItem(at: catalog)
        try fm.createDirectory(at: accent, withIntermediateDirectories: true)
        try Data(#"{ "info" : { "author" : "holdmybyte", "version" : 1 } }"#.utf8).write(to: catalog.appending(path: "Contents.json"))
        try Data(accentJSON.utf8).write(to: accent.appending(path: "Contents.json"))

        if let flat = cgImage(pixels: 1024) { try PNGWriter.write(flat, to: directory.appending(path: "AppIcon-flat.png")) }
    }

    static var iconJSON: String {
        """
        {
          "fill" : {
            "linear-gradient" : [
              "\(componentString(fillTop))",
              "\(componentString(fillBottom))"
            ]
          },
          "groups" : [
            {
              "layers" : [ { "image-name" : "print.png", "name" : "print" } ],
              "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
              "translucency" : { "enabled" : true, "value" : 0.3 }
            },
            {
              "layers" : [ { "image-name" : "brackets.png", "name" : "brackets" } ],
              "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
              "translucency" : { "enabled" : true, "value" : 0.45 }
            }
          ],
          "supported-platforms" : { "squares" : [ "macOS" ] }
        }
        """
    }

    static var accentJSON: String {
        func entry(_ hex: UInt32, dark: Bool) -> String {
            let c = [16, 8, 0].map { String(format: "\"0x%02X\"", (hex >> UInt32($0)) & 0xFF) }
            let appearance = dark ? #""appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "# : ""
            return "    { \(appearance)\"color\" : { \"color-space\" : \"srgb\", \"components\" : { \"alpha\" : \"1.000\", "
                + "\"red\" : \(c[0]), \"green\" : \(c[1]), \"blue\" : \(c[2]) } }, \"idiom\" : \"universal\" }"
        }
        let hex = Tokens.Palette.accentMulticolorHex
        return """
        {
          "colors" : [
        \(entry(hex.light, dark: false)),
        \(entry(hex.dark, dark: true))
          ],
          "info" : { "author" : "holdmybyte", "version" : 1 }
        }
        """
    }

    // MARK: Helpers

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func componentString(_ hex: UInt32) -> String {
        let c = [16, 8, 0].map { String(format: "%.5f", Double((hex >> UInt32($0)) & 0xFF) / 255) }
        return "srgb:\(c[0]),\(c[1]),\(c[2]),1.00000"
    }

    /// A transparent `pixels`² context in canvas points with a top-left origin.
    static func flippedContext(pixels: Int) -> CGContext? {
        guard let context = SnapshotRenderer.context(width: pixels, height: pixels) else { return nil }
        let s = CGFloat(pixels) / canvas
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: s, y: -s)
        context.interpolationQuality = .high
        return context
    }
}
