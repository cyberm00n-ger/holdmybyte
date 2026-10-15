// Compare's inspector (Docs/SPEC.md §2.4 S14 "PhotoInspector").
import AppKit
import HMBModel
import SwiftUI

struct PhotoInspector: View {
    let record: WeddingRecord
    let photo: SourcePhoto
    let preset: DeliveryPreset
    let result: PhotoResult?
    let pair: ComparePair?

    @State private var detailsExpanded = false
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.url.lastPathComponent)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                        .help(photo.url.lastPathComponent)
                    if let captured = photo.captureDate {
                        Text("Captured \(captured.formatted(.dateTime.month(.wide).day().year().locale(Locale(identifier: "en_US")))) at \(captured.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB"))))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Quality") {
                VStack(alignment: .leading, spacing: 2) {
                    if result?.status == .keptOriginal {
                        Text("Kept as original").font(Tokens.Typography.title)
                        Text("Already as small as this quality allows.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(result?.score.map(HMBFormat.score) ?? "–")
                            .font(Tokens.Typography.counter).monospacedDigit()
                        Text(CompareCopy.targetLine(target: result?.target, quality: preset.quality))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let edge = pair?.comparedAtLongEdge ?? preset.size.longEdge {
                        Text(CompareCopy.comparedResized(edge, locale: locale)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Size") {
                LabeledContent("Original", value: "\(HMBFormat.bytes(photo.byteCount, locale: locale)) · \(photo.pixelWidth) × \(photo.pixelHeight)")
                LabeledContent("Delivered", value: deliveredText)
                LabeledContent("Saved", value: savedText)
            }
            .monospacedDigit()
            Section {
                DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                    LabeledContent("Encoder", value: result?.encoder ?? "–")
                    LabeledContent("Chroma", value: result?.chroma?.rawValue ?? "–")
                    LabeledContent("Colour", value: colourText)
                    LabeledContent("Metadata", value: CompareCopy.metadataText(preset.metadata))
                    LabeledContent("Time", value: result.map { String(format: "%.2f s", locale: Locale(identifier: "en_US_POSIX"), $0.seconds) } ?? "–")
                }
            }
            Section {
                Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
                Button("Show Delivered in Finder") {
                    if let url = deliveredURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(deliveredURL == nil)
            }
        }
        .formStyle(.grouped)
    }

    private var deliveredURL: URL? {
        result?.outRelativePath.map { record.outputFolder.appending(path: $0, directoryHint: .notDirectory) }
    }

    private var deliveredFormat: String {
        switch (result?.outRelativePath as NSString?)?.pathExtension.lowercased() {
        case "jpg", "jpeg": "JPEG"
        case "webp": "WebP"
        case "jxl": "JPEG XL"
        default: preset.format.displayName
        }
    }

    private var deliveredBytes: Int64? { result?.outBytes ?? pair?.deliveredBytes }

    private var deliveredText: String {
        guard let bytes = deliveredBytes else { return "–" }
        let kept = result?.status == .keptOriginal ? " (original)" : ""
        return "\(HMBFormat.bytes(bytes, locale: locale)) · \(deliveredFormat)\(kept)"
    }

    private var savedText: String {
        guard let bytes = deliveredBytes, photo.byteCount > 0 else { return "–" }
        let saved = photo.byteCount - bytes
        return "\(HMBFormat.bytes(max(0, saved), locale: locale)) · \(HMBFormat.savedPercent(Double(saved) / Double(photo.byteCount), locale: locale))"
    }

    private var colourText: String {
        if preset.colour == .convertToSRGB { return "Converted to sRGB" }
        return CompareCopy.colourName(pair?.original?.cgImage.colorSpace ?? pair?.delivered.cgImage.colorSpace) ?? "Original profile"
    }
}
