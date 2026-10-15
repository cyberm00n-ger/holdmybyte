// The main window (§2.1): sidebar + detail, the whole window is a drop target, alerts and sheets.
import HMBModel
import SwiftUI
import UniformTypeIdentifiers

public struct RootView: View {
    @Bindable public var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView(columnVisibility: model.columnVisibilityBinding) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            NavigationStack(path: model.detailPathBinding) {
                DetailRouter()
                    .navigationDestination(for: CompareRoute.self) { _ in CompareView(model: model) }
            }
            .navigationSplitViewColumnWidth(min: Tokens.Layout.windowMinimum.width - 260, ideal: 860)
        }
        .searchable(text: model.searchBinding, placement: .sidebar, prompt: Text(Copy.Sidebar.searchPrompt))
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .frame(minWidth: Tokens.Layout.windowMinimum.width, minHeight: Tokens.Layout.windowMinimum.height)
        .onDrop(of: [.fileURL], delegate: WindowDropDelegate(model: model))
        .overlay(alignment: .bottom) {
            if let toast = model.state.toast, model.state.compare == nil {
                ToastCapsule(text: toast).padding(.bottom, Tokens.Spacing.s24).transition(.opacity)
            }
        }
        .animation(Tokens.Motion.stateMorph(reduceMotion: reduceMotion), value: model.state.toast)
        .animation(Tokens.Motion.standard(reduceMotion: reduceMotion), value: model.state.sidebarVisible)
        .modifier(AlertPresenter(model: model) { $0 != .clearHistory })
        .sheet(item: renameBinding) { item in
            RenameSheet(model: model, wedding: item.id)
        }
        .sheet(item: editDeliveryBinding) { item in
            EditDeliverySheetHost(model: model, preset: item.preset, isNew: item.isNew)
        }
        .environment(model)
        .hmbAccent()
        .onAppear { model.windowDidAppear() }
        .onDisappear { model.windowDidDisappear() }
    }

    private struct RenameItem: Identifiable { let id: WeddingID }
    private struct EditItem: Identifiable { let preset: DeliveryPreset; let isNew: Bool; var id: DeliveryID { preset.id } }

    private var renameBinding: Binding<RenameItem?> {
        Binding(get: {
            if case .renameWedding(let id) = model.state.sheet { RenameItem(id: id) } else { nil }
        }, set: { if $0 == nil, case .renameWedding = model.state.sheet { model.state.sheet = nil } })
    }

    private var editDeliveryBinding: Binding<EditItem?> {
        Binding(get: {
            if case .editDelivery(let preset, let isNew) = model.state.sheet { EditItem(preset: preset, isNew: isNew) } else { nil }
        }, set: { if $0 == nil, case .editDelivery = model.state.sheet { model.state.sheet = nil } })
    }
}

/// Chooses the detail view for the sidebar selection; its phases morph in place (§2.1).
struct DetailRouter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.state.selection {
            case .newWedding:
                if let draft = model.state.draft, draft.existingWedding == nil {
                    SetupView(draft: draft)
                } else {
                    DropZoneView()
                }
            case .wedding(let id):
                if let draft = model.state.draft, draft.existingWedding == id {
                    SetupView(draft: draft)
                } else if let record = model.record(id) {
                    WeddingDetailView(record: record)
                } else {
                    DropZoneView()
                }
            }
        }
        .animation(Tokens.Motion.stateMorph(reduceMotion: reduceMotion), value: detailKind)
    }

    /// Changes whenever the detail morphs to another phase (for the crossfade).
    private var detailKind: String {
        switch model.state.selection {
        case .newWedding: model.state.draft == nil ? "empty" : "setup"
        case .wedding(let id):
            if model.state.draft?.existingWedding == id { "setup-more" } else {
                switch model.record(id)?.phase {
                case .queued?: "queued"
                case .running?, .paused?, .stopped?, .interrupted?: "run"
                case .finished?: "done"
                case .failed?: "failed"
                case nil: "none"
                }
            }
        }
    }
}

/// Presents S18 alerts from `AppAlert.copy` (the single source of their copy). `presents` picks the alerts this window
/// shows: the main window shows all but Clear History; Settings (WP4) can present `.clearHistory` with
/// `AlertPresenter(model: model) { $0 == .clearHistory }`.
public struct AlertPresenter: ViewModifier {
    let model: AppModel
    let presents: (AppAlert) -> Bool

    public init(model: AppModel, presents: @escaping (AppAlert) -> Bool = { _ in true }) {
        self.model = model
        self.presents = presents
    }

    public func body(content: Content) -> some View {
        let alert = model.state.alert.flatMap { presents($0) ? $0 : nil }
        let copy = alert?.copy(in: model.state)
        content.alert(Text(copy?.title ?? ""), isPresented: Binding(get: { alert != nil }, set: { shown in
            if !shown, model.state.alert == alert { model.dismissAlert() }
        }), presenting: alert) { alert in
            let buttons = copy?.buttons ?? []
            ForEach(Array(buttons.enumerated()), id: \.offset) { index, title in
                if index == alert.defaultButtonIndex {
                    Button(title, role: .cancel) { model.dismissAlert() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(title, role: index == alert.destructiveButtonIndex ? .destructive : nil) { model.confirmAlert() }
                }
            }
        } message: { _ in
            Text(copy?.message ?? "")
        }
    }
}

// MARK: - Drop

/// The whole window is a drop target (sidebar included). Computes the DragSummary on enter and calls `handleDrop`.
struct WindowDropDelegate: DropDelegate {
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        let providers = info.itemProviders(for: [.fileURL])
        model.setDropTargeted(true, summary: .items(count: max(1, providers.count)))
        Task { @MainActor in
            let urls = await Self.urls(from: providers)
            guard !urls.isEmpty else { return }
            model.setDropTargeted(true, summary: model.dragSummary(for: urls))
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func dropExited(info: DropInfo) { model.setDropTargeted(false, summary: nil) }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        model.setDropTargeted(false, summary: nil)
        Task { @MainActor in
            let urls = await Self.urls(from: providers)
            model.handleDrop(urls)
        }
        return !providers.isEmpty
    }

    @MainActor
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url, url.isFileURL { urls.append(url) }
        }
        return urls
    }
}
