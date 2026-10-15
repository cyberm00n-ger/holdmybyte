// PNG writing, the blank check, manifest.json and the index.html contact sheet (§5.5 "Outputs per run").
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PixelStats {
    /// Fraction of pixels (sampled on a grid of at most ~250k points) that share the most common RGBA value.
    /// §5.5: a render is blank when this exceeds 0.99.
    static func dominantColourFraction(_ image: CGImage) -> Double {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return 1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = data.bindMemory(to: UInt32.self, capacity: image.width * image.height)
        let step = max(1, Int((Double(image.width * image.height) / 250_000).squareRoot()))
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: image.height, by: step) {
            for x in stride(from: 0, to: image.width, by: step) {
                counts[pixels[y * image.width + x], default: 0] += 1
                total += 1
            }
        }
        return total == 0 ? 1 : Double(counts.values.max() ?? 0) / Double(total)
    }

    static let blankThreshold = 0.99
}

enum PNGWriter {
    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}

struct SnapshotManifest: Codable {
    struct Run: Codable {
        var startedAt: Date
        var seconds: Double
        var locale: String
        var windowSize: String
        var appearances: [String]
        var settleSeconds: Double
        var fixturePhotos: Bool
        var loadAverageBefore: [Double]
        var loadAverageAfter: [Double]
        var macOS: String
        var failures: Int
    }

    struct Image: Codable {
        var id: String
        var section: String
        var surface: String
        var appearance: String
        var file: String
        /// Points, e.g. "1120x780".
        var size: String
        var pixelWidth: Int
        var pixelHeight: Int
        var dominantColourFraction: Double
        var blank: Bool
        var error: String?
        var milliseconds: Int
        /// Rendered and not blank.
        var ok = false
    }

    var run: Run
    var images: [Image]
}

enum ContactSheet {
    static func html(_ manifest: SnapshotManifest) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        // One card per (id, size); light and dark side by side.
        var groups: [(key: String, images: [SnapshotManifest.Image])] = []
        for image in manifest.images {
            let key = image.id + "|" + image.size
            if let index = groups.firstIndex(where: { $0.key == key }) { groups[index].images.append(image) } else { groups.append((key, [image])) }
        }
        let cards = groups.map { group -> String in
            let first = group.images[0]
            let failed = group.images.contains { !$0.ok }
            let figures = group.images.map { image -> String in
                let note = image.error.map { "<p class=\"err\">\(escape($0))</p>" } ?? (image.blank ? "<p class=\"err\">blank render</p>" : "")
                return """
                <figure><a href="\(escape(image.file))"><img loading="lazy" src="\(escape(image.file))" alt="\(escape(image.id)) \(image.appearance)"></a>\
                <figcaption>\(image.appearance)</figcaption>\(note)</figure>
                """
            }.joined()
            return """
            <section class="card\(failed ? " failed" : "")" id="\(escape(first.id))-\(escape(first.size))">
            <header><h2>\(escape(first.id))</h2><span>\(escape(first.size)) pt · \(escape(first.section)) · \(escape(first.surface))</span></header>
            <div class="pair">\(figures)</div></section>
            """
        }.joined(separator: "\n")
        let run = manifest.run
        let date = ISO8601DateFormatter().string(from: run.startedAt)
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>holdmybyte snapshots</title>
        <style>
        :root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --ink: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --bad: #c4321b; }
        @media (prefers-color-scheme: dark) { :root { --bg: #161617; --card: #1f1f21; --ink: #f5f5f7; --muted: #a1a1a6; --line: #38383a; --bad: #ff6b55; } }
        body { margin: 0; padding: 24px 16px; background: var(--bg); color: var(--ink); font: 14px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; }
        h1 { font-size: 22px; margin: 0 0 4px; } .meta { color: var(--muted); margin: 0 0 24px; }
        .card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 14px; margin: 0 0 18px; }
        .card.failed { border-color: var(--bad); }
        .card header { display: flex; flex-wrap: wrap; gap: 4px 12px; align-items: baseline; margin-bottom: 10px; }
        .card h2 { font-size: 16px; margin: 0; font-family: ui-monospace, SFMono-Regular, monospace; }
        .card header span { color: var(--muted); font-size: 12px; }
        .pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; }
        figure { margin: 0; } img { width: 100%; height: auto; border-radius: 8px; border: 1px solid var(--line); display: block; }
        figcaption { color: var(--muted); font-size: 12px; margin-top: 4px; } .err { color: var(--bad); margin: 4px 0 0; font-size: 12px; }
        </style></head><body>
        <h1>holdmybyte snapshots</h1>
        <p class="meta">\(manifest.images.count) images · \(run.failures) failed · \(escape(run.locale)) · \(escape(run.windowSize)) · \(date) · \
        \(String(format: "%.1f", run.seconds)) s · load \(run.loadAverageBefore.map { String(format: "%.2f", $0) }.joined(separator: " "))\
        \(run.fixturePhotos ? " · real fixture thumbnails" : " · synthetic thumbnails")</p>
        \(cards)
        </body></html>
        """
    }
}
