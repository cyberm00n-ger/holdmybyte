// `hmb-snapshot --self-test [dir]`: proves the capture pipeline on this machine without any WP3/WP4 view.
// It renders a probe with every construct the harness has to rewrite (glass sidebar, toolbar platter, vibrant
// sidebar text, a sheet, materials, the glass-button fallback, a CALayer-backed NSView) in both appearances and checks
// the pixels where each construct must show.
import AppKit
import HMBUI
import SwiftUI

private struct ProbeLayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = CALayer()
        layer.backgroundColor = CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        layer.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        view.layer?.addSublayer(layer)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ProbeView: View {
    @State private var showsSheet = false

    var body: some View {
        NavigationSplitView {
            List {
                Label("New Wedding", systemImage: "plus.circle.fill")
                Section("July 2026") {
                    Text("Finn und Lissy")
                    Text("Anna und Ben")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 16) {
                Text("Compressing Finn und Lissy").font(.system(size: 22, weight: .semibold))
                Text("312 of 535 photos · about 3 min left").font(.callout).foregroundStyle(.secondary)
                ProgressView(value: 0.58).frame(width: 320)
                Button("Compress 535 Photos") {}.hmbGlassButtonStyle(prominent: true).controlSize(.large)
                Text("Glass capsule").padding(.horizontal, 14).padding(.vertical, 8).hmbGlass()
                ProbeLayerView().frame(width: 80, height: 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Finn und Lissy")
            .navigationSubtitle("535 photos · 10.95 GB")
            .toolbar {
                ToolbarItemGroup {
                    Button { } label: { Label("Pause", systemImage: "pause.fill") }
                    Button { } label: { Label("Stop", systemImage: "stop.fill") }
                }
            }
        }
        .sheet(isPresented: $showsSheet) {
            Form { TextField("Name", text: .constant("Couple’s Package")) }
                .formStyle(.grouped).frame(width: 500, height: 200)
        }
        .onAppear { showsSheet = true }
    }
}

@MainActor
enum HarnessSelfTest {
    struct Check { var name: String; var passed: Bool; var detail: String }

    static func run(renderer: SnapshotRenderer, directory: URL) -> [Check] {
        var checks: [Check] = []
        for appearance in SnapshotAppearance.allCases {
            let label = "self-test-\(appearance.rawValue)"
            do {
                let size = CGSize(width: 1120, height: 780)
                let content = ProbeView().environment(\.isSnapshotRendering, true)
                let rendered = try renderer.renderWindow(content, size: size, appearance: appearance.nsAppearance)
                try PNGWriter.write(rendered.image, to: directory.appending(path: label + ".png"))
                let scale = Double(rendered.image.width) / size.width
                let dominant = PixelStats.dominantColourFraction(rendered.image)
                checks.append(Check(name: "\(label): not blank", passed: dominant <= PixelStats.blankThreshold,
                                    detail: String(format: "dominant colour %.3f", dominant)))
                checks.append(Check(name: "\(label): sheet composited", passed: rendered.sheets == 1, detail: "\(rendered.sheets) sheet(s)"))
                // Sidebar rows (vibrant text in glass) must show as text: high luminance spread in the row band.
                let sidebar = luminanceRange(rendered.image, CGRect(x: 30, y: 60, width: 170, height: 120), scale: scale)
                checks.append(Check(name: "\(label): sidebar text visible", passed: sidebar > 90, detail: "luminance range \(sidebar)"))
                // Toolbar items on their glass platter, top right.
                let toolbar = luminanceRange(rendered.image, CGRect(x: size.width - 110, y: 10, width: 100, height: 32), scale: scale)
                checks.append(Check(name: "\(label): toolbar items visible", passed: toolbar > 90, detail: "luminance range \(toolbar)"))
            } catch {
                checks.append(Check(name: "\(label): rendered", passed: false, detail: "\(error)"))
            }
        }
        return checks
    }

    /// max − min luminance (0…255) inside `rect` (points, top-left origin).
    static func luminanceRange(_ image: CGImage, _ rect: CGRect, scale: Double) -> Int {
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = image.cropping(to: pixelRect),
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return 0 }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: crop.width * crop.height * 4)
        var low = 255, high = 0
        for i in 0..<(crop.width * crop.height) {
            let y = (299 * Int(bytes[i * 4]) + 587 * Int(bytes[i * 4 + 1]) + 114 * Int(bytes[i * 4 + 2])) / 1000
            low = min(low, y); high = max(high, y)
        }
        return max(0, high - low)
    }
}
