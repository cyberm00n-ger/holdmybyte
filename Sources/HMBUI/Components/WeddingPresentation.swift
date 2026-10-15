// Derived, view-ready numbers for one wedding: summaries, grid cells, issues, the hardest photos. Pure functions of a
// `WeddingRecord` (plus live progress), so they are cheap to test and identical in the app and the snapshot harness.
import Foundation
import HMBModel

public enum CellStatus: Equatable, Sendable { case queued, working, done, keptOriginal, failed }

public struct GridCell: Identifiable, Equatable, Sendable {
    public var photo: SourcePhoto
    public var status: CellStatus
    public var score: Double?
    public var savedFraction: Double?
    public var hasIssue: Bool
    public var id: PhotoID { photo.id }
}

public struct IssueGroup: Identifiable, Equatable, Sendable {
    public var failure: PhotoFailure
    public var delivery: DeliveryPreset?          // per-delivery failures (encode, write, quality)
    public var photos: [SourcePhoto]
    public var id: String { failure.rawValue + "|" + (delivery?.id.rawValue ?? "*") }
}

public struct WeddingPresentation {
    public let record: WeddingRecord
    /// Latest result per (photo, delivery).
    public let latest: [ResultKey: PhotoResult]

    public init(_ record: WeddingRecord) {
        self.record = record
        var latest: [ResultKey: PhotoResult] = [:]
        latest.reserveCapacity(record.results.count)
        for result in record.results { latest[ResultKey(photo: result.photo, delivery: result.delivery)] = result }
        self.latest = latest
    }

    public var lossyDeliveries: [DeliveryPreset] { record.deliveries.filter(\.isLossy) }

    /// The delivery whose values the grid shows: the chosen one, else the first lossy one, else the first.
    public func gridDelivery(_ chosen: DeliveryID?) -> DeliveryPreset? {
        if let chosen, let preset = record.deliveries.first(where: { $0.id == chosen }) { return preset }
        return lossyDeliveries.first ?? record.deliveries.first
    }

    /// The delivery Compare opens on (archive is never comparable).
    public func compareDelivery(_ chosen: DeliveryID?) -> DeliveryPreset? {
        if let preset = gridDelivery(chosen), preset.isLossy { return preset }
        return lossyDeliveries.first
    }

    public func summary(_ preset: DeliveryPreset) -> DeliverySummary {
        DeliverySummary.make(preset: preset, photos: record.photos, results: record.results.filter { $0.delivery == preset.id })
    }

    /// Photos that failed in at least one delivery.
    public var failedPhotos: Set<PhotoID> {
        Set(latest.values.compactMap { if case .failed = $0.status { $0.photo } else { nil } })
    }

    public var issuePhotoCount: Int { failedPhotos.count }

    public func cell(_ photo: SourcePhoto, delivery: DeliveryPreset?) -> GridCell {
        var anyWorking = false, anyFailed = false, finished = 0
        for preset in record.deliveries {
            guard let result = latest[ResultKey(photo: photo.id, delivery: preset.id)] else { continue }
            switch result.status {
            case .working: anyWorking = true
            case .failed: anyFailed = true; finished += 1
            case .done, .keptOriginal: finished += 1
            case .queued: break
            }
        }
        let chosen = delivery.flatMap { latest[ResultKey(photo: photo.id, delivery: $0.id)] }
        let status: CellStatus
        if anyFailed && finished == record.deliveries.count {
            status = .failed
        } else if anyWorking || (finished > 0 && finished < record.deliveries.count) {
            status = anyWorking ? .working : .queued
        } else if finished == 0 {
            status = .queued
        } else if chosen?.status == .keptOriginal {
            status = .keptOriginal
        } else {
            status = anyFailed ? .failed : .done
        }
        var fraction: Double?
        if let chosen, let out = chosen.outBytes, chosen.inBytes > 0, chosen.status == .done || chosen.status == .keptOriginal {
            fraction = 1 - Double(out) / Double(chosen.inBytes)
        }
        return GridCell(photo: photo, status: status, score: chosen?.status == .done ? chosen?.score : nil,
                        savedFraction: fraction, hasIssue: anyFailed)
    }

    public func cells(delivery chosen: DeliveryID?, sort: GridSort, issuesOnly: Bool) -> [GridCell] {
        let preset = gridDelivery(chosen)
        var cells = record.photos.map { cell($0, delivery: preset) }
        if issuesOnly { cells = cells.filter(\.hasIssue) }
        switch sort {
        case .captureTime:
            break
        case .lowestScore:
            cells.sort { ($0.score ?? .infinity, $0.photo.id.index) < ($1.score ?? .infinity, $1.photo.id.index) }
        case .largestSavings:
            cells.sort { ($0.savedFraction ?? -.infinity, -$0.photo.id.index) > ($1.savedFraction ?? -.infinity, -$1.photo.id.index) }
        case .smallestSavings:
            cells.sort { ($0.savedFraction ?? .infinity, $0.photo.id.index) < ($1.savedFraction ?? .infinity, $1.photo.id.index) }
        }
        return cells
    }

    /// The `n` lowest-scoring photos of `delivery` (done photos only), lowest first.
    public func lowest(_ n: Int, delivery: DeliveryPreset) -> [(photo: SourcePhoto, score: Double)] {
        let scored = record.photos.compactMap { photo -> (SourcePhoto, Double)? in
            guard let result = latest[ResultKey(photo: photo.id, delivery: delivery.id)], result.status == .done,
                  let score = result.score else { return nil }
            return (photo, score)
        }
        return Array(scored.sorted { ($0.1, $0.0.id.index) < ($1.1, $1.0.id.index) }.prefix(n)).map { (photo: $0.0, score: $0.1) }
    }

    /// Scores of `delivery`'s done photos.
    public func scores(_ delivery: DeliveryPreset) -> [Double] {
        record.photos.compactMap { photo in
            guard let result = latest[ResultKey(photo: photo.id, delivery: delivery.id)], result.status == .done else { return nil }
            return result.score
        }
    }

    /// Photos of `delivery` that met their target (done at or above target, plus kept originals).
    public func metTarget(_ delivery: DeliveryPreset) -> Int {
        record.photos.reduce(0) { count, photo in
            guard let result = latest[ResultKey(photo: photo.id, delivery: delivery.id)] else { return count }
            switch result.status {
            case .keptOriginal: return count + 1
            case .done:
                if let score = result.score, let target = result.target ?? delivery.quality.floor, score < target { return count }
                return count + 1
            default: return count
            }
        }
    }

    /// Issue groups (S11): photo-level failures across deliveries, then per-delivery failures in delivery order.
    public var issueGroups: [IssueGroup] {
        var photoLevel: [PhotoFailure: Set<PhotoID>] = [:]
        var perDelivery: [DeliveryID: [PhotoFailure: Set<PhotoID>]] = [:]
        for result in latest.values {
            guard case .failed(let failure) = result.status else { continue }
            switch failure {
            case .unreadable, .cmykUnsupported, .sourceMissing: photoLevel[failure, default: []].insert(result.photo)
            case .encodeFailed, .writeFailed, .qualityUnreachable: perDelivery[result.delivery, default: [:]][failure, default: []].insert(result.photo)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: record.photos.map { ($0.id, $0) })
        func photos(_ ids: Set<PhotoID>) -> [SourcePhoto] { ids.sorted().compactMap { byID[$0] } }
        var groups: [IssueGroup] = []
        for failure in [PhotoFailure.unreadable, .cmykUnsupported, .sourceMissing] {
            if let ids = photoLevel[failure] { groups.append(IssueGroup(failure: failure, delivery: nil, photos: photos(ids))) }
        }
        for preset in record.deliveries {
            for failure in [PhotoFailure.encodeFailed, .writeFailed, .qualityUnreachable] {
                if let ids = perDelivery[preset.id]?[failure] {
                    groups.append(IssueGroup(failure: failure, delivery: preset, photos: photos(ids)))
                }
            }
        }
        return groups
    }

    /// Live progress, or one computed from the record (paused, stopped and interrupted weddings after a relaunch).
    public func progress(live: JobProgress?) -> JobProgress {
        if let live { return live }
        let summaries = record.deliveries.map(summary)
        return JobProgress(wedding: record.id, photosDone: record.photosFinished, photosTotal: record.photos.count,
                           photosInFlight: 0, secondsPerPhoto: nil, etaSeconds: nil, summaries: summaries)
    }

    /// Spot-check K = clamp(ceil(0.03 × photos), 5, 12) (§2.4 S14).
    public static func spotCheckCount(photos: Int) -> Int { min(12, max(5, Int((0.03 * Double(photos)).rounded(.up)))) }
}

extension JobProgress {
    /// "the last photos are in flight" (S8).
    public var isFinishing: Bool { photosInFlight > 0 && photosDone + photosInFlight >= photosTotal }

    /// Σ(source − output) over full-size deliveries, or Σ output when there is none (S8 savedSoFar).
    public func savedSoFar(deliveries: [DeliveryPreset]) -> (bytes: Int64, isSaving: Bool) {
        let fullSize = Set(deliveries.filter(\.isFullSize).map(\.id))
        if !fullSize.isEmpty {
            let saved = summaries.filter { fullSize.contains($0.delivery) }.reduce(Int64(0)) { $0 + $1.sourceBytes - $1.outputBytes }
            return (saved, true)
        }
        return (summaries.reduce(Int64(0)) { $0 + $1.outputBytes }, false)
    }
}
