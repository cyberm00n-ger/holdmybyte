// A wedding's detail: Queued (S7) → Running / Paused / Stopped / Interrupted (S8, S9) → Done (S10–S12) / Failed (S13).
import HMBModel
import SwiftUI

struct WeddingDetailView: View {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        content
            .navigationTitle(record.name)
            .navigationSubtitle(Copy.Toolbar.subtitle(photos: record.photos.count, bytes: record.sourceBytes, locale: locale))
            .overlay {
                if model.state.dropZone.isTargeted {
                    DropCapsule(text: Copy.DragTarget.startNewWedding)
                }
            }
            .onAppear { if model.state.windowOpen { model.markViewed(record.id) } }
    }

    @ViewBuilder private var content: some View {
        switch record.phase {
        case .queued:
            QueuedView(record: record)
        case .running, .paused, .stopped, .interrupted:
            RunView(record: record)
        case .finished:
            DoneView(record: record)
        case .failed(let reason):
            FailedView(record: record, reason: reason)
        }
    }
}

// MARK: - S7 queued

struct QueuedView: View {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section { SetupHeader(draft: draft, editable: false) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: Tokens.Layout.setupColumnMaxWidth, maxHeight: 150)
            ContentUnavailableView {
                Label(Copy.Queued.title, systemImage: "clock")
            } description: {
                Text(Copy.Queued.description(after: ahead?.name))
            } actions: {
                Button(Copy.Queued.startNow) { model.startNow(record.id) }
                    .hmbNeutralButtonTint()
                Button(Copy.Queued.remove) { model.removeFromQueue(record.id) }
                    .hmbNeutralButtonTint()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.removeFromQueue(record.id) } label: { Label(Copy.Toolbar.removeFromQueue, systemImage: "xmark") }
                    .help(Copy.Toolbar.removeFromQueueHelp)
            }
        }
    }

    /// The wedding the queue is working on (or waiting for) before this one.
    private var ahead: WeddingRecord? {
        guard let head = model.state.queue.first, head != record.id else { return nil }
        return model.record(head)
    }

    private var draft: SetupDraft {
        let scan = ScanResult(photos: record.photos, sourceRoots: record.sourceRoots, suggestedName: record.name,
                              weddingDate: record.weddingDate, camera: record.camera, totalBytes: record.sourceBytes,
                              rawCount: 0, notices: [])
        return SetupDraft(wedding: record.id, name: record.name, scan: .ready(scan), enabled: [:], naming: record.naming)
    }
}

// MARK: - S13 failed

struct FailedView: View {
    let record: WeddingRecord
    let reason: String
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            // The title breaks before the name, never inside it (non-breaking spaces within the quoted name).
            Label(Copy.Failed.title(record.name.replacingOccurrences(of: " ", with: "\u{00A0}")), systemImage: "xmark.octagon")
        } description: {
            Text(reason)
        } actions: {
            Button(Copy.Failed.tryAgain) { model.retry(record.id, photos: nil) }
                .hmbNeutralButtonTint()
            Button(Copy.Failed.remove) { model.requestRemoveFromHistory(record.id) }
                .hmbNeutralButtonTint()
        }
    }
}
