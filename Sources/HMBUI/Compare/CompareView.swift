// Compare (Docs/SPEC.md §2.4 S14): pushed on the detail NavigationStack, full-bleed under the toolbar.
// Split (original left, delivered right) or Side by Side; hold `\` for the original, `D` for amplified differences,
// `Z` for Fit ⇄ 100 % at the cursor; zoom and pan persist from photo to photo.
import AppKit
import HMBModel
import SwiftUI

public struct CompareView: View {
    @Bindable public var model: AppModel
    private let route: CompareRoute?

    @State private var loader: ComparePairLoader
    @State private var proxy = CompareCanvasProxy()
    @State private var keyboard = CompareKeyboard()
    @Environment(\.isSnapshotRendering) private var isSnapshotRendering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    static let coordinateSpace = "hmb.compare"
    static let toastDuration: Duration = .milliseconds(2500)

    /// Shows `model.state.compare` (open it with `model.openCompare(_:)`).
    public init(model: AppModel) { self.init(model: model, route: nil) }

    /// For `.navigationDestination(for: CompareRoute.self)`: opens `route` on appear unless it is already open.
    public init(model: AppModel, route: CompareRoute?) {
        self.model = model
        self.route = route
        _loader = State(initialValue: Self.preloadedLoader(model: model) ?? ComparePairLoader())
    }

    /// Starts with `initialPair` already loaded (for the snapshot harness, which cannot wait for a load).
    public init(model: AppModel, initialPair: ComparePair) {
        self.model = model
        self.route = nil
        if let compare = model.state.compare, let photo = compare.currentPhoto {
            let key = ComparePairLoader.Key(wedding: compare.route.wedding, photo: photo, delivery: compare.route.delivery)
            _loader = State(initialValue: ComparePairLoader(key: key, pair: initialPair, differencesTint: nil))
        } else {
            _loader = State(initialValue: ComparePairLoader())
        }
    }

    public var body: some View {
        Group {
            if let compare = model.state.compare, let record = model.compareRecord,
               let photoID = compare.currentPhoto, let photo = record.photos.first(where: { $0.id == photoID }),
               let preset = record.deliveries.first(where: { $0.id == compare.route.delivery }) {
                content(compare: compare, record: record, photo: photo, preset: preset)
            } else {
                Tokens.Palette.compareSurround.ignoresSafeArea()
            }
        }
        .onAppear {
            if let route, model.state.compare?.route.wedding != route.wedding || model.state.compare == nil {
                model.openCompare(route)
            }
        }
    }

    // MARK: Content

    private func content(compare: CompareState, record: WeddingRecord, photo: SourcePhoto, preset: DeliveryPreset) -> some View {
        let result = CompareSequence.deliveredResults(record, delivery: preset.id)[photo.id]
        let key = ComparePairLoader.Key(wedding: record.id, photo: photo.id, delivery: preset.id)
        let pair = loader.key == key ? loader.pair : nil
        let images = canvasImages(pair: pair, photo: photo, result: result, key: key)
        let comparing = compare.originalAvailable && images.original != nil
        return GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Tokens.Palette.compareSurround
                CompareCanvas(images: images, compare: compare, drawsWithLayers: !isSnapshotRendering, proxy: proxy,
                              onDivider: { value in model.updateCompare { $0.divider = value } },
                              onCenter: { center in model.updateCompare { $0.zoomCenter = center } },
                              onToggleZoom: { point in CompareKeyboard.toggleZoom(model: model, proxy: proxy, atCursor: false, point: point) },
                              onZoom: { zoom, point in
                                  guard zoom != compare.zoom else { return }
                                  CompareKeyboard.toggleZoom(model: model, proxy: proxy, atCursor: false, point: point)
                              })
                    .backgroundExtensionEffect()
                if compare.mode == .split, comparing, !compare.showsOriginal, !compare.showsDifferences {
                    CompareDivider(model: model, x: (size.width * compare.divider).rounded(), width: size.width,
                                   height: size.height, divider: compare.divider)
                }
                centredCapsules(compare: compare, pair: pair, comparing: comparing)
            }
            .coordinateSpace(.named(Self.coordinateSpace))
            .overlay(alignment: .top) {
                sideLabels(compare: compare, photo: photo, result: result, pair: pair, comparing: comparing, width: size.width)
                    .padding(.top, 52 + 10)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: Tokens.Spacing.s12) {
                    if let toast = model.state.toast {
                        CompareCapsule(text: toast, symbol: "checkmark.seal", height: 32)
                            .transition(.opacity)
                    }
                    CompareHUD(model: model, compare: compare, result: result, originalBytes: pair?.originalBytes ?? photo.byteCount,
                               isLoading: loader.isLoading)
                }
                .padding(.bottom, 20)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarBackButtonHidden(true)
        .modifier(CompareInspectorPresentation(
            isPresented: Binding(get: { model.state.compare?.showsInspector ?? false },
                                 set: { shown in model.updateCompare { $0.showsInspector = shown } }),
            isSnapshotRendering: isSnapshotRendering) {
                PhotoInspector(record: record, photo: photo, preset: preset, result: result, pair: pair)
            })
        .toolbar { toolbar(compare: compare, record: record, preset: preset, comparing: comparing) }
        .task(id: LoadRequest(key: key, upcoming: upcoming(compare))) {
            guard !isSnapshotRendering else { return }
            loader.show(key, record: record, engine: model.engine, thumbnails: model.thumbnails,
                        screenPixels: screenPixels, upcoming: upcoming(compare))
        }
        .onChange(of: pairAvailability(pair), initial: true) { _, available in
            if let available { model.setCompareOriginalAvailable(available) }
        }
        .task(id: DifferencesRequest(key: key, stage: loader.stage, wanted: compare.showsDifferences)) {
            guard !isSnapshotRendering, compare.showsDifferences else { return }
            loader.updateDifferences(wanted: true, tint: CompareDifferences.tint(for: proxy.view?.effectiveAppearance))
        }
        .task(id: model.state.toast) {
            guard !isSnapshotRendering, let toast = model.state.toast else { return }
            try? await Task.sleep(for: Self.toastDuration)
            if model.state.toast == toast {
                withAnimation(reduceMotion ? Tokens.Motion.reducedCrossfade : Tokens.Motion.spring) { model.state.toast = nil }
            }
        }
        .onAppear { if !isSnapshotRendering { keyboard.install(model: model, proxy: proxy) } }
        .onDisappear {
            keyboard.remove()
            loader.cancel()
        }
    }

    // MARK: Pieces

    @ToolbarContentBuilder
    private func toolbar(compare: CompareState, record: WeddingRecord, preset: DeliveryPreset, comparing: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.closeCompare() } label: { Label(record.name, systemImage: "chevron.left") }
                .labelStyle(.titleAndIcon)
                .help("Back to \(record.name) (Esc)")
        }
        ToolbarItem(placement: .principal) {
            Picker("Comparison", selection: Binding(get: { compare.mode },
                                                     set: { mode in model.updateCompare { if $0.canSplit { $0.mode = mode } } })) {
                Text("Split").tag(CompareMode.split)
                Text("Side by Side").tag(CompareMode.sideBySide)
            }
            .pickerStyle(.segmented)
            .disabled(!compare.canSplit)
            .help("Split or side by side (Y)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let lossy = CompareSequence.lossyDeliveries(record)
            if lossy.count > 1 {
                Menu {
                    ForEach(lossy) { delivery in
                        Button { model.setCompareDelivery(delivery.id) } label: {
                            Label(delivery.name, systemImage: delivery.id == preset.id ? "checkmark" : delivery.symbol)
                        }
                    }
                } label: {
                    Label(preset.name, systemImage: preset.symbol)
                }
                .help("Choose the delivery to compare")
            }
            Toggle(isOn: Binding(get: { compare.showsDifferences }, set: { _ in model.toggleCompareDifferences() })) {
                Label("Differences", systemImage: "circle.lefthalf.filled")
            }
            .disabled(!compare.canShowDifferences)
            .help("Show differences (D)")
            Menu {
                Button { if compare.zoom != .fit { model.toggleCompareZoom() } } label: {
                    Label("Fit", systemImage: compare.zoom == .fit ? "checkmark" : "arrow.down.right.and.arrow.up.left")
                }
                Button { if compare.zoom != .actual { CompareKeyboard.toggleZoom(model: model, proxy: proxy, atCursor: false) } } label: {
                    Label("100 %", systemImage: compare.zoom == .actual ? "checkmark" : "1.magnifyingglass")
                }
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
            }
            .help("Fit or 100 % (Z)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { compare.showsInspector }, set: { _ in model.toggleCompareInspector() })) {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show the inspector (I)")
        }
    }

    @ViewBuilder
    private func sideLabels(compare: CompareState, photo: SourcePhoto, result: PhotoResult?, pair: ComparePair?,
                            comparing: Bool, width: CGFloat) -> some View {
        let original = CompareCopy.originalLabel(bytes: pair?.originalBytes ?? photo.byteCount,
                                                 available: compare.originalAvailable, locale: locale)
        let delivered = CompareCopy.deliveredLabel(bytes: result?.outBytes ?? pair?.deliveredBytes, locale: locale)
        if compare.mode == .sideBySide && comparing {
            let pane = max(0, (width - CompareGeometry.paneGap) / 2)
            HStack(spacing: CompareGeometry.paneGap) {
                CompareCapsule(text: original).frame(width: pane)
                CompareCapsule(text: delivered).frame(width: pane)
            }
        } else {
            VStack(alignment: .trailing, spacing: Tokens.Spacing.s8) {
                HStack {
                    CompareCapsule(text: original)
                    Spacer()
                    CompareCapsule(text: delivered)
                }
                if compare.showsDifferences && comparing && !compare.showsOriginal {
                    CompareCapsule(text: CompareCopy.differencesLegend, symbol: "circle.lefthalf.filled")
                }
            }
            .padding(.horizontal, Tokens.Spacing.s16)
        }
    }

    @ViewBuilder
    private func centredCapsules(compare: CompareState, pair: ComparePair?, comparing: Bool) -> some View {
        if !compare.originalAvailable {
            CompareCapsule(text: CompareCopy.connectVolume(pair?.unavailableVolume), symbol: "externaldrive.badge.xmark", height: 32)
        } else if compare.showsOriginal && comparing {
            CompareCapsule(text: CompareCopy.originalCapsule, height: 32)
        }
    }

    // MARK: Data

    private struct LoadRequest: Equatable { var key: ComparePairLoader.Key; var upcoming: [PhotoID] }
    private struct DifferencesRequest: Equatable { var key: ComparePairLoader.Key; var stage: ComparePairLoader.Stage?; var wanted: Bool }

    private func upcoming(_ compare: CompareState) -> [PhotoID] {
        let next = compare.position + 1
        return compare.sequence.indices.contains(next) ? [compare.sequence[next]] : []
    }

    /// The screen-resolution request: 2 × the canvas's long edge in points (the pixel size on a Retina screen).
    private var screenPixels: Int {
        let size = proxy.view?.bounds.size ?? Tokens.Layout.windowDefault
        return max(1024, Int((max(size.width, size.height) * 2).rounded()))
    }

    /// nil while no pair has loaded; otherwise whether it carries the original.
    private func pairAvailability(_ pair: ComparePair?) -> Bool? { pair.map { $0.original != nil } }

    private func canvasImages(pair: ComparePair?, photo: SourcePhoto, result: PhotoResult?, key: ComparePairLoader.Key) -> CompareCanvasImages {
        let expected = Self.expectedSize(photo: photo, result: result)
        if let pair {
            let full = loader.stage == .full
            let size = full ? CGSize(width: pair.delivered.cgImage.width, height: pair.delivered.cgImage.height)
                            : Self.oriented(expected, like: pair.delivered.cgImage)
            return CompareCanvasImages(original: pair.original, delivered: pair.delivered,
                                       differences: loader.differences, imageSize: size)
        }
        if let placeholder = loader.key == key ? loader.placeholder : nil {
            return CompareCanvasImages(original: placeholder, delivered: placeholder, differences: nil,
                                       imageSize: Self.oriented(expected, like: placeholder.cgImage))
        }
        return CompareCanvasImages(original: nil, delivered: nil, differences: nil, imageSize: expected)
    }

    /// The delivered file's pixel size as recorded (falls back to the source's).
    static func expectedSize(photo: SourcePhoto, result: PhotoResult?) -> CGSize {
        CGSize(width: result?.outPixelWidth ?? photo.pixelWidth, height: result?.outPixelHeight ?? photo.pixelHeight)
    }

    /// `size`, swapped if `image` has the other orientation (a preview decoded with or without EXIF rotation).
    static func oriented(_ size: CGSize, like image: CGImage) -> CGSize {
        let imageLandscape = image.width >= image.height, sizeLandscape = size.width >= size.height
        return imageLandscape == sizeLandscape ? size : CGSize(width: size.height, height: size.width)
    }

    // MARK: Snapshot support

    /// Pairs registered by the snapshot harness before rendering, so a CompareView created anywhere (also inside
    /// RootView's navigation destination) shows its images in the first frame.
    @MainActor static var preloadedPairs: [ComparePairLoader.Key: ComparePair] = [:]

    /// Registers `pair` as already loaded for `photo` of `delivery` (see `preloadedPairs`).
    @MainActor public static func preload(_ pair: ComparePair, wedding: WeddingID, photo: PhotoID, delivery: DeliveryID) {
        preloadedPairs[ComparePairLoader.Key(wedding: wedding, photo: photo, delivery: delivery)] = pair
    }

    @MainActor private static func preloadedLoader(model: AppModel) -> ComparePairLoader? {
        guard let compare = model.state.compare, let photo = compare.currentPhoto else { return nil }
        let key = ComparePairLoader.Key(wedding: compare.route.wedding, photo: photo, delivery: compare.route.delivery)
        guard let pair = preloadedPairs[key] else { return nil }
        return ComparePairLoader(key: key, pair: pair, differencesTint: nil)
    }
}

/// `.inspector` (240–320 wide). The offscreen snapshot cannot render the inspector column, so the snapshot path lays
/// the same inspector out beside the canvas at its ideal width.
private struct CompareInspectorPresentation<Inspector: View>: ViewModifier {
    @Binding var isPresented: Bool
    let isSnapshotRendering: Bool
    @ViewBuilder let inspector: () -> Inspector

    func body(content: Content) -> some View {
        if isSnapshotRendering {
            HStack(spacing: 0) {
                content
                if isPresented {
                    Divider()
                    inspector().frame(width: 260).background(.background)
                }
            }
        } else {
            content.inspector(isPresented: $isPresented) {
                inspector().inspectorColumnWidth(min: 240, ideal: 260, max: 320)
            }
        }
    }
}
