// S18 alert copy: the single source used by the `.alert` modifiers and by the snapshot harness (Docs/SPEC.md §5.3).
import Foundation
import HMBModel

public typealias AlertCopy = (title: String, message: String, buttons: [String])

extension AppAlert {
    /// Title, message and button titles (in display order; the first is the action button) for this alert in `state`.
    /// The default button is `defaultButtonIndex`; the destructive one is `destructiveButtonIndex`.
    public func copy(in state: AppState, locale: Locale = .current) -> AlertCopy {
        switch self {
        case .stop(let id):
            let record = state.records.first { $0.id == id }
            let name = record?.name ?? ""
            let done = AppAlert.photosDone(id, in: state)
            let photos = done == 1 ? "The finished photo stays" : "The \(done.formatted(.number.locale(locale))) finished photos stay"
            return ("Stop compressing \(Copy.quoted(name))?",
                    "\(photos) in the delivery folders. You can finish the rest later.",
                    ["Stop", "Continue"])
        case .quitWhileRunning(let id):
            let record = state.records.first { $0.id == id }
            let done = AppAlert.photosDone(id, in: state)
            let total = record?.photos.count ?? 0
            let verb = done == 1 ? "is" : "are"
            return ("Stop compressing \(Copy.quoted(record?.name ?? "")) and quit?",
                    "\(done.formatted(.number.locale(locale))) of \(Copy.photos(total, locale: locale)) \(verb) done. "
                    + "holdmybyte will offer to resume next time it opens.",
                    ["Quit", "Cancel"])
        case .removeFromHistory(let id):
            let name = state.records.first { $0.id == id }?.name ?? ""
            return ("Remove \(Copy.quoted(name)) from history?",
                    "The delivered photos stay where they are. Only this entry is removed.",
                    ["Remove", "Cancel"])
        case .clearHistory:
            let count = state.records.filter { !$0.phase.isInProgress }.count
            let weddings = count == 1 ? "1 wedding" : "all \(count.formatted(.number.locale(locale))) weddings"
            return ("Clear the history of \(weddings)?", "Delivered photos are not touched.", ["Clear", "Cancel"])
        }
    }

    /// Index into `copy(in:).buttons` of the default (Return) button.
    public var defaultButtonIndex: Int {
        switch self {
        case .stop: 1                  // [Stop] [Continue] (default)
        case .quitWhileRunning: 1      // [Quit] [Cancel] (default)
        case .removeFromHistory: 1     // [Remove] (destructive) [Cancel]
        case .clearHistory: 1
        }
    }

    /// Index of the destructive button, if any.
    public var destructiveButtonIndex: Int? {
        switch self {
        case .removeFromHistory, .clearHistory: 0
        case .stop, .quitWhileRunning: nil
        }
    }

    /// Photos finished in every delivery of the job (live progress first, else the record's results).
    static func photosDone(_ id: WeddingID, in state: AppState) -> Int {
        if let progress = state.live[id] { return progress.photosDone }
        guard let record = state.records.first(where: { $0.id == id }) else { return 0 }
        return record.photosFinished
    }
}

extension JobPhase {
    /// Running, queued, paused, stopped or interrupted: shown under "In Progress".
    public var isInProgress: Bool {
        switch self {
        case .queued, .running, .paused, .stopped, .interrupted: true
        case .finished, .failed: false
        }
    }
}

extension WeddingRecord {
    /// Photos that are finished (done, kept original or failed) in every delivery of the record.
    public var photosFinished: Int {
        guard !deliveries.isEmpty else { return 0 }
        var perPhoto: [PhotoID: Int] = [:]
        var seen = Set<ResultKey>()
        for result in results.reversed() {
            let key = ResultKey(photo: result.photo, delivery: result.delivery)
            guard seen.insert(key).inserted else { continue }
            switch result.status {
            case .done, .keptOriginal, .failed: perPhoto[result.photo, default: 0] += 1
            case .queued, .working: break
            }
        }
        let wanted = Set(deliveries.map(\.id)).count
        return perPhoto.values.filter { $0 >= wanted }.count
    }
}

/// (photo, delivery): the identity of a result.
public struct ResultKey: Hashable, Sendable {
    public var photo: PhotoID
    public var delivery: DeliveryID
    public init(photo: PhotoID, delivery: DeliveryID) { self.photo = photo; self.delivery = delivery }
}
