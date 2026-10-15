import Foundation

public struct WeddingRecord: Identifiable, Codable, Sendable, Hashable {
    public var id: WeddingID
    public var name: String
    public var createdAt: Date
    public var weddingDate: Date?
    public var camera: String?
    public var sourceRoots: [URL]
    public var sourceBookmarks: [Data]       // URL.bookmarkData() (not security-scoped) for relinking
    public var photos: [SourcePhoto]
    public var deliveries: [DeliveryPreset]  // snapshots, incl. later "Create More" additions
    public var deliveryCompletedAt: [String: Date]   // DeliveryID.rawValue → completion date
    public var outputFolder: URL
    public var outputBookmark: Data?
    public var naming: NamingScheme
    public var phase: JobPhase
    public var results: [PhotoResult]
    public var startedAt: Date?
    public var finishedAt: Date?
    public var activeSeconds: Double         // excludes paused time
    public var viewed: Bool

    public init(id: WeddingID, name: String, createdAt: Date, weddingDate: Date?, camera: String?,
                sourceRoots: [URL], sourceBookmarks: [Data], photos: [SourcePhoto], deliveries: [DeliveryPreset],
                deliveryCompletedAt: [String: Date], outputFolder: URL, outputBookmark: Data?, naming: NamingScheme,
                phase: JobPhase, results: [PhotoResult], startedAt: Date?, finishedAt: Date?,
                activeSeconds: Double, viewed: Bool) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.weddingDate = weddingDate
        self.camera = camera; self.sourceRoots = sourceRoots; self.sourceBookmarks = sourceBookmarks
        self.photos = photos; self.deliveries = deliveries; self.deliveryCompletedAt = deliveryCompletedAt
        self.outputFolder = outputFolder; self.outputBookmark = outputBookmark; self.naming = naming
        self.phase = phase; self.results = results; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.activeSeconds = activeSeconds; self.viewed = viewed
    }

    public var sourceBytes: Int64 { photos.reduce(0) { $0 + $1.byteCount } }
    public var coverPhoto: SourcePhoto? { photos.first }
    /// Number of failed (photo, delivery) pairs.
    public var issueCount: Int { results.reduce(0) { if case .failed = $1.status { $0 + 1 } else { $0 } } }
    public func summary(for delivery: DeliveryID) -> DeliverySummary? {
        guard let preset = deliveries.first(where: { $0.id == delivery }) else { return nil }
        return DeliverySummary.make(preset: preset, photos: photos, results: results.filter { $0.delivery == delivery })
    }
    /// Σ(source − output) over full-size deliveries (lifetime footer).
    /// Per delivery: Σ inBytes − Σ outBytes over its delivered photos (done + kept original), as in `DeliverySummary`.
    public var savedBytesFullSize: Int64 {
        deliveries.filter(\.isFullSize).reduce(Int64(0)) { total, preset in
            let summary = DeliverySummary.make(preset: preset, photos: photos,
                                               results: results.filter { $0.delivery == preset.id })
            return total + (summary.sourceBytes - summary.outputBytes)
        }
    }
}
