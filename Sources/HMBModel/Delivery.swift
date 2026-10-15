import Foundation

public enum OutputFormat: String, Codable, Sendable, CaseIterable {
    case jpeg, webp, jxlLossless
    public var fileExtension: String { switch self { case .jpeg: "jpg"; case .webp: "webp"; case .jxlLossless: "jxl" } }
    public var displayName: String { switch self { case .jpeg: "JPEG"; case .webp: "WebP"; case .jxlLossless: "JPEG XL" } }
}

public enum OutputSize: Codable, Sendable, Hashable {
    case full
    case longEdge(Int)                       // 400...12000
    public var longEdge: Int? { if case .longEdge(let px) = self { px } else { nil } }
}

public enum QualityLevel: String, Codable, Sendable, CaseIterable {
    case highest, high, balanced, web, lossless
    /// Fixed SSIMULACRA2 floor (engine scale). nil: per-photo target (balanced) or byte-exact (lossless).
    public var floor: Double? { switch self { case .highest: 90; case .high: 85; case .web: 70; case .balanced, .lossless: nil } }
    public var displayName: String {
        switch self { case .highest: "Highest"; case .high: "High"; case .balanced: "Balanced"; case .web: "Web"; case .lossless: "Lossless" }
    }
    public var levelDescription: String {
        switch self {
        case .highest:  "Visually lossless, even when you flick between both at 100 %. For albums and print."
        case .high:     "Indistinguishable from the original at normal viewing; only a flicker test at 100 % can reveal it."
        case .balanced: "Adapts to each photo: detailed scenes keep more, smooth scenes give more. The quality clients are used to, at a fraction of the size."
        case .web:      "High quality on screens. For resized website and social images."
        case .lossless: "Byte-exact: every file restores to the identical original."
        }
    }
}

public enum ColourHandling: String, Codable, Sendable { case keepProfile, convertToSRGB }
public enum MetadataPolicy: String, Codable, Sendable { case keepAll, removeLocation, removeAll }
public enum ChromaSubsampling: String, Codable, Sendable { case s420 = "4:2:0", s444 = "4:4:4" }

public struct DeliveryPreset: Identifiable, Codable, Sendable, Hashable {
    public var id: DeliveryID
    public var name: String
    public var symbol: String
    public var format: OutputFormat
    public var size: OutputSize
    public var quality: QualityLevel
    public var colour: ColourHandling
    public var metadata: MetadataPolicy
    public var folderName: String
    public var isBuiltIn: Bool

    public init(id: DeliveryID, name: String, symbol: String, format: OutputFormat, size: OutputSize,
                quality: QualityLevel, colour: ColourHandling, metadata: MetadataPolicy,
                folderName: String, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.symbol = symbol; self.format = format; self.size = size
        self.quality = quality; self.colour = colour; self.metadata = metadata
        self.folderName = folderName; self.isBuiltIn = isBuiltIn
    }

    public var isFullSize: Bool { size == .full }
    public var isLossy: Bool { format != .jxlLossless }

    /// nil when valid. Rules (each returns the quoted message):
    /// jxlLossless ⇔ quality == .lossless, and then size == .full, colour == .keepProfile, metadata == .keepAll
    ///   → "JPEG XL deliveries are lossless, full size and keep everything."
    /// quality == .balanced ⇒ format == .jpeg && size == .full → "Balanced is available for full-size JPEG only."
    /// longEdge ∈ 400...12000 → "Long edge must be between 400 and 12000 px."
    /// name, folderName non-empty after trimming; folderName contains none of "/:" → "Enter a name and a folder name."
    public var validationError: String? {
        let isJXL = format == .jxlLossless
        if isJXL != (quality == .lossless)
            || (isJXL && (size != .full || colour != .keepProfile || metadata != .keepAll)) {
            return "JPEG XL deliveries are lossless, full size and keep everything."
        }
        if quality == .balanced && !(format == .jpeg && size == .full) {
            return "Balanced is available for full-size JPEG only."
        }
        if let px = size.longEdge, !(400...12000).contains(px) {
            return "Long edge must be between 400 and 12000 px."
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFolder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedFolder.isEmpty || trimmedFolder.contains(where: { $0 == "/" || $0 == ":" }) {
            return "Enter a name and a folder name."
        }
        return nil
    }

    /// Built-ins return their fixed spec lines (§2.6). Custom: "<size> · <format> · <quality>" + " · sRGB" if converted
    /// + " · location removed" / " · metadata removed". Size text: "Full size" or "2560 px". Lossless: "Lossless · JPEG XL · byte-exact".
    public var specLine: String {
        // A built-in keeps its fixed line only while its output-defining fields match the shipped definition;
        // an edited built-in describes itself like a custom preset.
        if isBuiltIn, let line = Self.builtInSpecLines[id.rawValue],
           let shipped = Self.builtIns.first(where: { $0.id == id }),
           shipped.format == format, shipped.size == size, shipped.quality == quality,
           shipped.colour == colour, shipped.metadata == metadata {
            return line
        }
        if format == .jxlLossless || quality == .lossless { return "Lossless · JPEG XL · byte-exact" }
        let sizeText = size.longEdge.map { "\($0) px" } ?? "Full size"
        var line = "\(sizeText) · \(format.displayName) · \(quality.displayName)"
        if colour == .convertToSRGB { line += " · sRGB" }
        switch metadata {
        case .keepAll: break
        case .removeLocation: line += " · location removed"
        case .removeAll: line += " · metadata removed"
        }
        return line
    }

    static let builtInSpecLines: [String: String] = [
        DeliveryID.couple.rawValue: "Full size · JPEG · Balanced",
        DeliveryID.website.rawValue: "2560 px · WebP · location removed",
        DeliveryID.social.rawValue: "1440 px · JPEG · sRGB",
        DeliveryID.archive.rawValue: "Lossless · JPEG XL · byte-exact",
    ]

    public static let builtIns: [DeliveryPreset] = [
        DeliveryPreset(id: .couple, name: "Couple’s Package", symbol: "heart", format: .jpeg, size: .full,
                       quality: .balanced, colour: .keepProfile, metadata: .keepAll, folderName: "Couple", isBuiltIn: true),
        DeliveryPreset(id: .website, name: "Website", symbol: "globe", format: .webp, size: .longEdge(2560),
                       quality: .web, colour: .convertToSRGB, metadata: .removeLocation, folderName: "Website", isBuiltIn: true),
        DeliveryPreset(id: .social, name: "Social & Blog", symbol: "square.grid.3x3", format: .jpeg, size: .longEdge(1440),
                       quality: .high, colour: .convertToSRGB, metadata: .removeLocation, folderName: "Social", isBuiltIn: true),
        DeliveryPreset(id: .archive, name: "Archive", symbol: "archivebox", format: .jxlLossless, size: .full,
                       quality: .lossless, colour: .keepProfile, metadata: .keepAll, folderName: "Archive", isBuiltIn: true),
    ]
    public static let defaultOnIDs: [DeliveryID] = [.couple, .website]
}
