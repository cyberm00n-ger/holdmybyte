// Loading pairs for Compare (Docs/SPEC.md §2.4 S14 "Compare loading and availability"):
//  1. the cached grid thumbnail, at once (placeholder);
//  2. the pair at screen resolution (`comparePair(maxPixelSize: 2 × view)`), the first real frame (budget 150 ms);
//  3. the full-resolution pair (budget 600 ms); a mini spinner shows in the HUD until it arrives.
// The current pair stays decoded; the next photo's pair is preloaded at screen resolution.
import AppKit
import HMBModel
import Observation

@MainActor @Observable
final class ComparePairLoader {
    struct Key: Hashable, Sendable {
        var wedding: WeddingID
        var photo: PhotoID
        var delivery: DeliveryID
    }

    enum Stage: Int, Comparable, Sendable {
        case placeholder, screen, full
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    /// Milestones of the current load (for the performance harness and diagnostics).
    struct Timings: Equatable, Sendable {
        var requested: ContinuousClock.Instant
        var placeholder: Duration?
        var screen: Duration?
        var full: Duration?
    }

    private(set) var key: Key?
    private(set) var stage: Stage?
    private(set) var pair: ComparePair?
    private(set) var placeholder: SendableImage?
    private(set) var differences: SendableImage?
    private(set) var differencesStage: Stage?
    private(set) var isComputingDifferences = false
    private(set) var failure: String?
    private(set) var timings: Timings?

    @ObservationIgnored private var screenCache: [Key: ComparePair] = [:]
    @ObservationIgnored private var screenCacheOrder: [Key] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var placeholderTask: Task<Void, Never>?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var differencesTask: Task<Void, Never>?
    @ObservationIgnored private var differencesKey: (Key, Stage)?

    static let screenCacheLimit = 3

    /// Whether the full-resolution pair is still on its way (the HUD spinner).
    var isLoading: Bool { key != nil && stage != .full && failure == nil }

    init() {}

    /// A loader that already holds `pair` at full resolution (snapshot rendering, where nothing can wait).
    init(key: Key, pair: ComparePair, differencesTint: (red: CGFloat, green: CGFloat, blue: CGFloat)?) {
        self.key = key
        self.pair = pair
        stage = .full
        if let tint = differencesTint, let original = pair.original {
            differences = CompareDifferences.image(original: original.cgImage, delivered: pair.delivered.cgImage, tint: tint).map(SendableImage.init)
            differencesStage = .full
        }
    }

    /// Shows `photo`, loading in stages, then preloads `upcoming` at screen resolution.
    func show(_ key: Key, record: WeddingRecord, engine: any EngineService, thumbnails: any ThumbnailProviding,
              screenPixels: Int, upcoming: [PhotoID]) {
        guard key != self.key else { return }
        loadTask?.cancel()
        differencesTask?.cancel()
        differencesKey = nil
        self.key = key
        failure = nil
        differences = nil
        differencesStage = nil
        isComputingDifferences = false
        timings = Timings(requested: .now)
        if let cached = screenCache[key] {
            pair = cached
            stage = .screen
            placeholder = nil
            timings?.screen = .zero
        } else {
            pair = nil
            stage = nil
            placeholder = nil
        }
        if stage == nil, let photo = record.photos.first(where: { $0.id == key.photo }) {
            placeholderTask?.cancel()
            placeholderTask = Task { [weak self] in
                let image = await thumbnails.thumbnail(for: photo, maxPixelSize: 320)
                guard let self, self.key == key, self.stage == nil, let image else { return }
                self.placeholder = image
                self.stage = .placeholder
                self.timings?.placeholder = ContinuousClock.now - (self.timings?.requested ?? .now)
            }
        }
        loadTask = Task { [weak self] in
            await self?.loadPairs(key, record: record, engine: engine, screenPixels: screenPixels)
            guard let self, !Task.isCancelled, self.key == key else { return }
            self.preload(upcoming, of: key, record: record, engine: engine, screenPixels: screenPixels)
        }
    }

    private func loadPairs(_ key: Key, record: WeddingRecord, engine: any EngineService, screenPixels: Int) async {
        do {
            if (stage ?? .placeholder) < .screen {
                let screen = try await engine.comparePair(record: record, photo: key.photo, delivery: key.delivery, maxPixelSize: screenPixels)
                guard self.key == key, !Task.isCancelled else { return }
                remember(screen, for: key)
                if (stage ?? .placeholder) < .screen {
                    pair = screen
                    stage = .screen
                    timings?.screen = ContinuousClock.now - (timings?.requested ?? .now)
                }
            }
            let full = try await engine.comparePair(record: record, photo: key.photo, delivery: key.delivery, maxPixelSize: nil)
            guard self.key == key, !Task.isCancelled else { return }
            pair = full
            stage = .full
            timings?.full = ContinuousClock.now - (timings?.requested ?? .now)
        } catch is CancellationError {
        } catch {
            guard self.key == key else { return }
            failure = String(describing: error)
        }
    }

    private func preload(_ upcoming: [PhotoID], of current: Key, record: WeddingRecord, engine: any EngineService, screenPixels: Int) {
        preloadTask?.cancel()
        let keys = upcoming.map { Key(wedding: current.wedding, photo: $0, delivery: current.delivery) }.filter { screenCache[$0] == nil }
        guard !keys.isEmpty else { return }
        preloadTask = Task { [weak self] in
            for key in keys {
                guard !Task.isCancelled else { return }
                guard let pair = try? await engine.comparePair(record: record, photo: key.photo, delivery: key.delivery,
                                                               maxPixelSize: screenPixels) else { continue }
                self?.remember(pair, for: key)
            }
        }
    }

    private func remember(_ pair: ComparePair, for key: Key) {
        screenCache[key] = pair
        screenCacheOrder.removeAll { $0 == key }
        screenCacheOrder.append(key)
        // Keep the current photo's pair and the newest preloads; drop the oldest others.
        while screenCacheOrder.count > Self.screenCacheLimit,
              let oldest = screenCacheOrder.firstIndex(where: { $0 != self.key }) {
            screenCache[screenCacheOrder.remove(at: oldest)] = nil
        }
    }

    /// Computes the differences image for the current pair (again when a better stage arrives).
    func updateDifferences(wanted: Bool, tint: (red: CGFloat, green: CGFloat, blue: CGFloat)) {
        guard wanted, let key, let pair, let stage, stage >= .screen, let original = pair.original else { return }
        if let differencesStage, differencesStage >= stage, differences != nil { return }
        if let pending = differencesKey, pending.0 == key, pending.1 >= stage { return }
        differencesTask?.cancel()
        differencesKey = (key, stage)
        isComputingDifferences = true
        let delivered = pair.delivered
        differencesTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                CompareDifferences.image(original: original.cgImage, delivered: delivered.cgImage, tint: tint).map(SendableImage.init)
            }.value
            guard let self, !Task.isCancelled, self.key == key else { return }
            self.differences = image
            self.differencesStage = stage
            self.isComputingDifferences = false
            self.differencesKey = nil
        }
    }

    func cancel() {
        loadTask?.cancel()
        placeholderTask?.cancel()
        preloadTask?.cancel()
        differencesTask?.cancel()
    }
}
