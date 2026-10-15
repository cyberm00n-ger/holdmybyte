// Shared helpers for the WP1 primitive tests: deterministic synthetic images, local-data gates, small metrics.
import CoreGraphics
import CryptoKit
import Foundation
@testable import HMBEngine

enum Synthetic {
    enum Kind: String, CaseIterable, Sendable { case gradient, noise, blocks, waves }

    /// Packed RGBA (width × 4 bytes per row), integer-only arithmetic so the bytes are identical on every machine.
    /// The same generator ran once against the old `GrainEstimator` to produce `ImagingTests.expectedFeatures`.
    static func rgba(_ kind: Kind, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 0x1234_5678
        func next() -> UInt32 { seed = seed &* 1_664_525 &+ 1_013_904_223; return seed >> 8 }
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var r = 0, g = 0, b = 0
                switch kind {
                case .gradient:
                    r = x * 255 / max(1, width - 1)
                    g = y * 255 / max(1, height - 1)
                    b = (x + y) * 255 / max(1, width + height - 2)
                case .noise:
                    r = 128 + Int(next() % 41) - 20
                    g = 120 + Int(next() % 31) - 15
                    b = 110 + Int(next() % 21) - 10
                case .blocks:
                    let cell = (x / 24) * 7 + (y / 24) * 13
                    r = (cell * 53) % 256; g = (cell * 97 + 40) % 256; b = (cell * 151 + 80) % 256
                    if x % 37 == 0 || y % 29 == 0 { r = 255 - r; g = 255 - g; b = 255 - b }
                case .waves:
                    let t = (x * x + 3 * y * y) / 97
                    r = 60 + (t % 160)
                    g = 90 + ((x * 3 + y) % 120)
                    b = 40 + ((x + y * 5) / 3) % 150
                    let n = Int(next() % 9) - 4
                    r = min(255, max(0, r + n)); g = min(255, max(0, g + n)); b = min(255, max(0, b + n))
                }
                out[i] = UInt8(r); out[i + 1] = UInt8(g); out[i + 2] = UInt8(b); out[i + 3] = 255
            }
        }
        return out
    }

    static func image(_ kind: Kind, width: Int = 320, height: Int = 240,
                      colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> PixelImage {
        let packed = rgba(kind, width: width, height: height)
        let image = PixelImage(width: width, height: height, colorSpace: colorSpace)
        let base = image.pixels.baseAddress!.assumingMemoryBound(to: UInt8.self)
        packed.withUnsafeBufferPointer { src in
            for y in 0..<height { (base + y * image.bytesPerRow).update(from: src.baseAddress! + y * width * 4, count: width * 4) }
        }
        return image
    }
}

enum LocalData {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    /// The 6 sample photos (HMB_TEST_PHOTOS), sorted; empty when not configured.
    static var samplePhotos: [URL] { jpegs(in: env["HMB_TEST_PHOTOS"]) }
    static var holdout: URL? { env["HMB_HOLDOUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var hasSamples: Bool { !samplePhotos.isEmpty }
    static var hasHoldout: Bool {
        guard let holdout else { return false }
        return FileManager.default.fileExists(atPath: holdout.path)
    }
    static var cjpegli: URL {
        URL(fileURLWithPath: env["HMB_CJPEGLI"] ?? "/Users/sebastianhaas/Desktop/jpegos/Vendor/bin/cjpegli")
    }
    /// Opt-in for timing runs (they need a quiet machine): HMB_METRIC_BENCH=1.
    static var benchEnabled: Bool { env["HMB_METRIC_BENCH"] == "1" }

    static func jpegs(in path: String?) -> [URL] {
        guard let path, let items = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: nil) else { return [] }
        return items.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A fresh scratch folder in the system temp directory (never next to source photos).
    static func scratchDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hmb-wp1-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "load n/a" }
        return String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }
}

enum Measure {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// PSNR over R, G, B (0…255).
    static func psnr(_ a: PixelImage, _ b: PixelImage) -> Double {
        precondition(a.width == b.width && a.height == b.height)
        var se = 0.0
        for y in 0..<a.height {
            let ra = a.bytes + y * a.bytesPerRow, rb = b.bytes + y * b.bytesPerRow
            for x in 0..<(a.width * 4) where x % 4 != 3 {
                let d = Double(ra[x]) - Double(rb[x]); se += d * d
            }
        }
        let mse = se / Double(a.pixelCount * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    static func identical(_ a: PixelImage, _ b: PixelImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        for y in 0..<a.height {
            let ra = a.bytes + y * a.bytesPerRow, rb = b.bytes + y * b.bytesPerRow
            for x in 0..<(a.width * 4) where x % 4 != 3 && ra[x] != rb[x] { return false }
        }
        return true
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}
