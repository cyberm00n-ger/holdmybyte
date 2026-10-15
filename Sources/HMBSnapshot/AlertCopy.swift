// Alert copy for the harness (§2.3, §2.4 S9, S16, S18).
//
// §5.3 makes WP3's `AppAlert.copy` the single source of this copy. It does not exist on the WP5 branch yet, so the
// harness carries the spec strings here, in the same (title, message, buttons) shape. After WP3 merges, `copy(for:in:)`
// becomes a one-line forward to WP3's API (Docs/WP5-NOTES.md, open question Q1).
import Foundation
import HMBModel
import HMBUI

struct AlertContent: Equatable {
    var title: String
    var message: String
    /// Display order, left to right.
    var buttons: [String]
    /// Index into `buttons` of the default (Return) button.
    var defaultButton: Int
    /// Index of the destructive button, if any.
    var destructiveButton: Int?
}

enum AlertCopy {
    static func copy(for alert: AppAlert, in state: AppState) -> AlertContent {
        func name(_ id: WeddingID) -> String { state.records.first { $0.id == id }?.name ?? "this wedding" }
        func done(_ id: WeddingID) -> (done: Int, total: Int) {
            if let progress = state.live[id] { return (progress.photosDone, progress.photosTotal) }
            let record = state.records.first { $0.id == id }
            let finished = Set(record?.results.compactMap { result -> PhotoID? in
                switch result.status { case .done, .keptOriginal: result.photo; default: nil }
            } ?? [])
            return (finished.count, record?.photos.count ?? 0)
        }
        switch alert {
        case .stop(let id):
            return AlertContent(
                title: "Stop compressing “\(name(id))”?",
                message: "The \(done(id).done) finished photos stay in the delivery folders. You can finish the rest later.",
                buttons: ["Stop", "Continue"], defaultButton: 1, destructiveButton: nil)
        case .quitWhileRunning(let id):
            let progress = done(id)
            return AlertContent(
                title: "Stop compressing “\(name(id))” and quit?",
                message: "\(progress.done) of \(progress.total) photos are done. holdmybyte will offer to resume next time it opens.",
                buttons: ["Quit", "Cancel"], defaultButton: 1, destructiveButton: nil)
        case .removeFromHistory(let id):
            return AlertContent(
                title: "Remove “\(name(id))” from history?",
                message: "The delivered photos stay where they are. Only this entry is removed.",
                buttons: ["Remove", "Cancel"], defaultButton: 0, destructiveButton: 0)
        case .clearHistory:
            let count = state.records.filter { if case .finished = $0.phase { true } else { false } }.count
            return AlertContent(
                title: "Clear the history of all \(count) weddings?",
                message: "Delivered photos are not touched.",
                buttons: ["Clear", "Cancel"], defaultButton: 0, destructiveButton: 0)
        }
    }
}
