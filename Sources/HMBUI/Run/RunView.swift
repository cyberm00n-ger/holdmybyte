// S8 running (header, delivery strip, grid) and S9 banners (paused, stopped, interrupted).
import HMBModel
import SwiftUI

struct RunView: View {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        let presentation = WeddingPresentation(record)
        let progress = presentation.progress(live: model.state.live[record.id])
        VStack(spacing: 0) {
            RunHeader(record: record, progress: progress)
                .padding(.horizontal, Tokens.Spacing.s24).padding(.top, Tokens.Spacing.s20).padding(.bottom, Tokens.Spacing.s16)
            RunBanner(record: record, progress: progress)
                .padding(.horizontal, Tokens.Spacing.s24).padding(.bottom, Tokens.Spacing.s12)
            DeliveryStrip(record: record, progress: progress)
                .padding(.horizontal, Tokens.Spacing.s24).padding(.bottom, Tokens.Spacing.s12)
            Divider()
            ScrollView {
                PhotoGrid(record: record, cells: presentation.cells(delivery: model.state.gridDelivery, sort: .captureTime, issuesOnly: false))
                    .padding(Tokens.Spacing.s20)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .toolbar { RunToolbar(record: record) }
    }
}

struct RunToolbar: ToolbarContent {
    let record: WeddingRecord
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if record.phase == .running {
                Button { model.pause(record.id) } label: { Label(Copy.Toolbar.pause, systemImage: "pause.fill") }
                    .help(Copy.Toolbar.pauseHelp)
            } else {
                Button { model.resume(record.id) } label: { Label(Copy.Toolbar.resume, systemImage: "play.fill") }
                    .help(Copy.Toolbar.resumeHelp)
                    .disabled(!model.canResume(record))
            }
            Button { model.requestStop(record.id) } label: { Label(Copy.Toolbar.stop, systemImage: "stop.fill") }
                .help(Copy.Toolbar.stopHelp)
                .disabled(record.phase == .stopped)
        }
    }
}

/// Title, status line, saved-so-far counter and the progress bar.
struct RunHeader: View {
    let record: WeddingRecord
    let progress: JobProgress
    @Environment(\.locale) private var locale

    var body: some View {
        let saved = progress.savedSoFar(deliveries: record.deliveries)
        let running = record.phase == .running
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Copy.Run.title(record.name))
                        .font(Tokens.Typography.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusLine(running: running))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: Tokens.Spacing.s16)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(HMBFormat.bytes(saved.bytes, locale: locale))
                        .font(Tokens.Typography.counter)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .fixedSize()
                    Text(saved.isSaving ? Copy.Run.savedSoFar : Copy.Run.deliveredSoFar)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                // Paused/stopped/interrupted: `.secondary`. Never `.tint(nil)`, which resets to the system accent
                // instead of keeping the app's tint.
                .modifier(SecondaryTint(active: !running))
                .accessibilityLabel(Copy.Run.title(record.name))
                .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent")
        }
        .animation(.default, value: progress.photosDone)
    }

    private func statusLine(running: Bool) -> String {
        if running {
            return HMBFormat.statusLine(done: progress.photosDone, total: progress.photosTotal, etaSeconds: progress.etaSeconds,
                                        finishing: progress.isFinishing, locale: locale)
        }
        return "\(progress.photosDone.formatted(.number.locale(locale))) of \(Copy.photos(progress.photosTotal, locale: locale))"
    }
}

/// The S9 banner for paused, stopped and interrupted weddings.
struct RunBanner: View {
    let record: WeddingRecord
    let progress: JobProgress
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        switch record.phase {
        case .paused(let reason):
            let text = Copy.Banner.paused(reason, done: progress.photosDone, total: progress.photosTotal, locale: locale)
            StatusBanner(symbol: symbol(reason), symbolStyle: style(reason), title: text.title, message: text.message) {
                Button(Copy.Banner.resume) { model.resume(record.id) }
                    .disabled(!model.canResume(record))
                if reason != .user {
                    Button(Copy.Banner.stop) { model.requestStop(record.id) }
                }
            }
        case .stopped:
            let text = Copy.Banner.stopped(done: progress.photosDone, total: progress.photosTotal, locale: locale)
            StatusBanner(symbol: "stop.circle.fill", title: text.title, message: text.message) {
                Button(Copy.Banner.resume) { model.resume(record.id) }
                Button(Copy.Banner.showInFinder) { model.revealInFinder(record.id, delivery: nil) }
            }
        case .interrupted:
            let text = Copy.Banner.interrupted(done: progress.photosDone, total: progress.photosTotal, locale: locale)
            StatusBanner(symbol: "arrow.clockwise.circle.fill", title: text.title, message: text.message) {
                Button(Copy.Banner.resume) { model.resume(record.id) }
                Button(Copy.Banner.stopHere) { model.stopHere(record.id) }
            }
        default:
            EmptyView()
        }
    }

    private func symbol(_ reason: PauseReason) -> String {
        switch reason {
        case .user: "pause.circle.fill"
        case .sourceUnavailable: "externaldrive.badge.xmark"
        case .diskFull, .outputNotWritable: "exclamationmark.triangle.fill"
        }
    }

    private func style(_ reason: PauseReason) -> AnyShapeStyle {
        switch reason {
        case .diskFull, .outputNotWritable: AnyShapeStyle(Tokens.Palette.warning)
        default: AnyShapeStyle(.secondary)
        }
    }
}

/// Capsules: symbol · name · live size; a complete delivery shows a checkmark and reveals its folder on click.
struct DeliveryStrip: View {
    let record: WeddingRecord
    let progress: JobProgress
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Tokens.Spacing.s8) {
                ForEach(record.deliveries) { preset in
                    let summary = progress.summaries.first { $0.delivery == preset.id }
                        ?? WeddingPresentation(record).summary(preset)
                    let complete = summary.processed >= summary.total && summary.total > 0
                    Button {
                        if complete { model.revealInFinder(record.id, delivery: preset.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: preset.symbol)
                            Text(preset.name).lineLimit(1)
                            if complete {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            } else {
                                Text(HMBFormat.bytes(summary.outputBytes, locale: locale))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.fill.tertiary, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(complete ? Copy.Run.revealHelp(preset.name) : preset.specLine)
                    .accessibilityLabel(complete ? "\(preset.name), complete" : "\(preset.name), \(HMBFormat.bytes(summary.outputBytes, locale: locale))")
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// `.tint(.secondary)` when `active`; otherwise the inherited tint stays.
struct SecondaryTint: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.tint(.secondary) } else { content }
    }
}
