// Thumbnails for the sidebar, the setup mosaic, the photo grid and the proof strip. One in-memory cache for the whole
// app (the provider has its own disk cache); the snapshot harness gets synthetic fixture images synchronously.
import AppKit
import HMBFixtures
import HMBModel
import SwiftUI

@MainActor
final class ThumbnailMemoryCache {
    static let shared = ThumbnailMemoryCache()
    private let cache = NSCache<NSString, CGImageBox>()

    init() { cache.countLimit = 3000 }

    final class CGImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    static func key(_ photo: SourcePhoto, _ size: Int) -> NSString { "\(photo.url.path)|\(photo.byteCount)|\(size)" as NSString }

    func image(_ photo: SourcePhoto, _ size: Int) -> CGImage? { cache.object(forKey: Self.key(photo, size))?.image }
    func store(_ image: CGImage, _ photo: SourcePhoto, _ size: Int) { cache.setObject(CGImageBox(image), forKey: Self.key(photo, size)) }
}

/// Pixel sizes requested from the provider (≤ 320 px is what the disk cache stores).
enum ThumbnailSize {
    static let small = 96       // sidebar, mosaic
    static let grid = 320       // grid cells and proof thumbs
}

struct ThumbnailView: View {
    let photo: SourcePhoto?
    var pixelSize: Int = ThumbnailSize.grid
    /// The cell shows the photo without colour (queued/working). The live view uses `.saturation(0)` around the
    /// thumbnail; offscreen snapshots cannot draw that filter, so they get a greyscale image instead.
    var monochrome = false
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering
    @State private var loaded: CGImage?

    var body: some View {
        Color.clear
            .background(.fill.tertiary)
            .overlay {
                if let image = currentImage.map({ isSnapshotRendering && monochrome ? Self.greyscale($0) : $0 }) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: photo.map { ThumbnailMemoryCache.key($0, pixelSize) as String }) { await load() }
    }

    private var currentImage: CGImage? {
        if let loaded { return loaded }
        guard let photo else { return nil }
        if let cached = ThumbnailMemoryCache.shared.image(photo, pixelSize) { return cached }
        // Snapshots render without a run loop turn for tasks: fixture images are produced synchronously.
        if isSnapshotRendering, let fixtures = model.thumbnails as? FixtureThumbnails {
            let image = fixtures.image(for: photo, maxPixelSize: pixelSize).cgImage
            ThumbnailMemoryCache.shared.store(image, photo, pixelSize)
            return image
        }
        return nil
    }

    static func greyscale(_ image: CGImage) -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private func load() async {
        guard let photo else { loaded = nil; return }
        if let cached = ThumbnailMemoryCache.shared.image(photo, pixelSize) { loaded = cached; return }
        guard let image = await model.thumbnails.thumbnail(for: photo, maxPixelSize: pixelSize)?.cgImage else { return }
        ThumbnailMemoryCache.shared.store(image, photo, pixelSize)
        if !Task.isCancelled { loaded = image }
    }
}

/// 2×2 thumbnail mosaic (SetupHeader): cell 36, gap 2, corner 10; shimmers while the scan has no photos yet.
struct ThumbnailMosaic: View {
    let photos: [SourcePhoto]
    var cell: CGFloat = 36
    var gap: CGFloat = 2

    var body: some View {
        Grid(horizontalSpacing: gap, verticalSpacing: gap) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { column in
                        let i = row * 2 + column
                        ThumbnailView(photo: i < photos.count ? photos[i] : nil, pixelSize: ThumbnailSize.small)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .redacted(reason: photos.isEmpty ? .placeholder : [])
        .shimmering(active: photos.isEmpty)
        .clipShape(Tokens.Radius.shape(Tokens.Radius.mosaic))
        .accessibilityHidden(true)
    }
}
