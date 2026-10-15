// WP4 acceptance 5 (Docs/SPEC.md §5.4): every WP4 state renders offscreen the way the snapshot harness renders it
// (NSHostingView in a borderless window that is never ordered front, cacheDisplay), light and dark, not blank.
// PNGs go to $HMB_WP4_RENDER_DIR when set (for visual review), otherwise to a temporary folder that is removed.
import AppKit
import HMBFixtures
import HMBModel
@testable import HMBUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct WP4RenderTests {
    static let outputDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["HMB_WP4_RENDER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appending(path: "hmb-wp4-render-\(UUID().uuidString)", directoryHint: .isDirectory)
    }()

    static var keepsOutput: Bool { ProcessInfo.processInfo.environment["HMB_WP4_RENDER_DIR"]?.isEmpty == false }

    @Test(arguments: WP4StateCatalogue.ids)
    func rendersInBothAppearances(_ id: String) async throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        defer { if !Self.keepsOutput { try? FileManager.default.removeItem(at: Self.outputDirectory) } }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let model = try #require(WP4StateCatalogue.model(id))
            let view = try #require(await WP4StateCatalogue.view(id, model: model))
            let size: CGSize? = switch id {
            case let id where id.hasPrefix("compare"): Tokens.Layout.windowDefault
            case "edit-delivery": EditDeliverySheet.size
            default: nil                                      // Settings: 600 wide, height fits content
            }
            let image = try await Self.render(view, size: size, appearance: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            try Self.png(image).write(to: Self.outputDirectory.appending(path: "\(id)-\(suffix).png"))
            #expect(!Self.isBlank(image), "\(id) \(suffix) rendered blank")
            if id.hasPrefix("settings") {
                #expect(image.width >= 600 && image.height >= 150, "\(id) has size \(image.width)×\(image.height)")
            }
        }
        CompareView.preloadedPairs.removeAll()
    }

    /// Hosts `view` like the harness does and returns the cached bitmap (1× backing: the window is never on a screen).
    static func render(_ view: AnyView, size: CGSize?, appearance: NSAppearance.Name) async throws -> CGImage {
        let root = view
            .environment(\.isSnapshotRendering, true)
            .environment(\.locale, Locale(identifier: "en_DE"))
        let hosting = NSHostingView(rootView: root)
        let fitting = size ?? CGSize(width: Tokens.Layout.settingsWidth, height: max(200, hosting.fittingSize.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: fitting), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: fitting)
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        if size == nil {
            let height = max(150, hosting.fittingSize.height)
            window.setContentSize(CGSize(width: fitting.width, height: height))
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: fitting.width, height: height))
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
        }
        hosting.displayIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        return try #require(rep.cgImage)
    }

    static func png(_ image: CGImage) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// The harness's rule: blank when more than 99 % of the pixels share one colour.
    static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let bpp = image.bitsPerPixel / 8
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: image.height, by: 3) {
            for x in stride(from: 0, to: image.width, by: 3) {
                let p = bytes + y * image.bytesPerRow + x * bpp
                counts[UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]), default: 0] += 1
                total += 1
            }
        }
        return Double(counts.values.max() ?? 0) > 0.99 * Double(total)
    }
}
