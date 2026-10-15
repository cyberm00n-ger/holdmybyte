// Regenerates the synthetic test images in this folder (no client photos, no camera EXIF).
// Usage: swift Tests/Fixtures/generate.swift [<jpegtran with -arithmetic support>]
// The arithmetic-coded fixture needs a libjpeg build with arithmetic coding (e.g. libjpeg-turbo's jpegtran); it is only
// a one-time generation tool and never part of the build.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

func context(_ w: Int, _ h: Int, _ space: CGColorSpace) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}

func write(_ image: CGImage, _ name: String, type: UTType = .jpeg, quality: Double = 0.9, properties: [CFString: Any] = [:]) -> URL {
    let url = folder.appending(path: name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var options = properties
    if type == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "could not write \(name)")
    return url
}

/// Warm vertical gradient with soft blobs (photo-like, smooth: the easy case).
func gradient(_ w: Int, _ h: Int) -> CGImage {
    let c = context(w, h, srgb)
    let colors = [CGColor(srgbRed: 0.98, green: 0.90, blue: 0.80, alpha: 1), CGColor(srgbRed: 0.85, green: 0.62, blue: 0.45, alpha: 1),
                  CGColor(srgbRed: 0.25, green: 0.18, blue: 0.14, alpha: 1)]
    c.drawLinearGradient(CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: [0, 0.5, 1])!,
                         start: CGPoint(x: 0, y: h), end: CGPoint(x: w / 3, y: 0), options: [])
    let blobs: [(Double, Double, Double, CGColor)] = [
        (0.3, 0.45, 0.18, CGColor(srgbRed: 0.95, green: 0.95, blue: 0.92, alpha: 0.8)),
        (0.62, 0.40, 0.14, CGColor(srgbRed: 0.18, green: 0.20, blue: 0.28, alpha: 0.8)),
        (0.8, 0.75, 0.2, CGColor(srgbRed: 1.0, green: 0.85, blue: 0.55, alpha: 0.6)),
    ]
    for (x, y, r, color) in blobs {
        let g = CGGradient(colorsSpace: srgb, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0.2, 1])!
        let center = CGPoint(x: Double(w) * x, y: Double(h) * y)
        c.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: Double(min(w, h)) * r, options: [])
    }
    return c.makeImage()!
}

/// Saturated hue ramps in Display P3 (colour-management and chroma case).
func ramps(_ w: Int, _ h: Int) -> CGImage {
    let c = context(w, h, p3)
    let bands = 6
    for i in 0..<bands {
        let hue = Double(i) / Double(bands)
        let colors = (0...4).map { s -> CGColor in
            let (r, g, b) = hsv(hue + Double(s) * 0.03, Double(s) / 4, 1 - Double(s) * 0.08)
            return CGColor(colorSpace: p3, components: [r, g, b, 1])!
        }
        let y0 = Double(h) * Double(i) / Double(bands), y1 = Double(h) * Double(i + 1) / Double(bands)
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: y0, width: Double(w), height: y1 - y0))
        c.drawLinearGradient(CGGradient(colorsSpace: p3, colors: colors as CFArray, locations: nil)!,
                             start: .zero, end: CGPoint(x: w, y: 0), options: [])
        c.restoreGState()
    }
    return c.makeImage()!
}

/// Hard-edged red/green/blue checker plus fine black/white lines (texture and chroma stress).
func pattern(_ w: Int, _ h: Int) -> CGImage {
    let c = context(w, h, srgb)
    let palette = [CGColor(srgbRed: 0.9, green: 0.05, blue: 0.1, alpha: 1), CGColor(srgbRed: 0.05, green: 0.6, blue: 0.2, alpha: 1),
                   CGColor(srgbRed: 0.1, green: 0.2, blue: 0.85, alpha: 1), CGColor(srgbRed: 0.98, green: 0.85, blue: 0.1, alpha: 1)]
    let cell = 32
    for y in stride(from: 0, to: h / 2, by: cell) {
        for x in stride(from: 0, to: w, by: cell) {
            c.setFillColor(palette[(x / cell + y / cell) % palette.count])
            c.fill(CGRect(x: x, y: y, width: cell, height: cell))
        }
    }
    for x in 0..<w {
        c.setFillColor(gray: x.isMultiple(of: 2) ? 0 : 1, alpha: 1)
        c.fill(CGRect(x: x, y: h / 2, width: 1, height: h / 2))
    }
    return c.makeImage()!
}

func cmykImage(_ w: Int, _ h: Int) -> CGImage {
    let space = CGColorSpaceCreateDeviceCMYK()
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    c.drawLinearGradient(CGGradient(colorsSpace: space, colors: [CGColor(genericCMYKCyan: 0.8, magenta: 0.1, yellow: 0, black: 0, alpha: 1),
                                                                 CGColor(genericCMYKCyan: 0, magenta: 0.7, yellow: 0.9, black: 0.1, alpha: 1)] as CFArray,
                                    locations: nil)!, start: .zero, end: CGPoint(x: w, y: h), options: [])
    return c.makeImage()!
}

func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    let hh = (h - floor(h)) * 6, c = v * s, x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
    let (r, g, b): (Double, Double, Double) = switch Int(hh) {
    case 0: (c, x, 0)
    case 1: (x, c, 0)
    case 2: (0, c, x)
    case 3: (0, x, c)
    case 4: (x, 0, c)
    default: (c, 0, x)
    }
    return (r + m, g + m, b + m)
}

/// Inserts a COM marker right after SOI.
func insertComment(_ text: String, into url: URL) throws {
    var data = try Data(contentsOf: url)
    let payload = Data(text.utf8)
    var segment = Data([0xFF, 0xFE, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)])
    segment.append(payload)
    data.insert(contentsOf: segment, at: 2)
    try data.write(to: url)
}

_ = write(gradient(640, 427), "gradient-srgb.jpg")
_ = write(ramps(640, 427), "ramps-p3.jpg")
_ = write(pattern(512, 512), "pattern.png", type: .png)
_ = write(gradient(640, 427), "orientation-6.jpg", properties: [kCGImagePropertyOrientation: 6])
_ = write(cmykImage(320, 213), "cmyk.jpg")
let com = write(gradient(320, 213), "holdmybyte-output.jpg")
try insertComment("holdmybyte v2 · test fixture", into: com)
_ = write(gradient(2400, 1600), "mosaic-2400x1600.jpg", quality: 0.35)

let base = write(gradient(320, 213), "arithmetic-source.jpg")
let jpegtran = CommandLine.arguments.dropFirst().first ?? "/opt/homebrew/opt/jpeg-turbo/bin/jpegtran"
let process = Process()
process.executableURL = URL(fileURLWithPath: jpegtran)
process.arguments = ["-arithmetic", "-copy", "none", "-outfile", folder.appending(path: "arithmetic.jpg").path, base.path]
try process.run()
process.waitUntilExit()
try FileManager.default.removeItem(at: base)
precondition(process.terminationStatus == 0, "jpegtran -arithmetic failed")
print("wrote fixtures to \(folder.path)")
