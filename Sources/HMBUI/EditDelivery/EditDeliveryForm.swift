// The Edit Delivery sheet's form state (Docs/SPEC.md §2.4 S6). Pure value logic, unit-tested:
// which options are offered, which are disabled, and the preset the form describes. Invalid combinations are
// disabled and reported with `DeliveryPreset.validationError`'s exact message, never silently corrected.
import HMBModel

struct EditDeliveryForm: Equatable {
    enum SizeChoice: Hashable { case full, longEdge }

    let id: DeliveryID
    let isBuiltIn: Bool
    var name: String
    var symbol: String
    var format: OutputFormat
    var sizeChoice: SizeChoice
    /// What the long-edge field shows, exactly as typed. Validated live (Save is disabled while it is not a number
    /// in 400…12000), so the sheet never saves a value the field does not show.
    var longEdgeText: String
    /// The typed long edge; 0 when the field is empty or not a whole number (reported as out of range).
    var longEdge: Int {
        get { Int(longEdgeText.trimmingCharacters(in: .whitespaces)) ?? 0 }
        set { longEdgeText = String(newValue) }
    }
    /// The lossy quality. JPEG XL is always Lossless (the picker shows it, disabled); switching back to a lossy
    /// format brings this choice back.
    var lossyQuality: QualityLevel
    var colour: ColourHandling
    var metadata: MetadataPolicy
    var folderName: String

    static let symbols = ["heart", "globe", "square.grid.3x3", "archivebox", "book.closed", "printer", "iphone", "photo",
                          "star", "sparkles", "person.2", "folder"]
    static let lossyQualities: [QualityLevel] = [.highest, .high, .balanced, .web]
    static let defaultLongEdge = 2560

    init(_ preset: DeliveryPreset) {
        id = preset.id
        isBuiltIn = preset.isBuiltIn
        name = preset.name
        symbol = preset.symbol
        format = preset.format
        switch preset.size {
        case .full: sizeChoice = .full; longEdgeText = String(Self.defaultLongEdge)
        case .longEdge(let px): sizeChoice = .longEdge; longEdgeText = String(px)
        }
        lossyQuality = preset.quality == .lossless ? .high : preset.quality
        colour = preset.colour
        metadata = preset.metadata
        folderName = preset.folderName
    }

    /// What Quality shows and saves.
    var quality: QualityLevel { format == .jxlLossless ? .lossless : lossyQuality }

    var size: OutputSize { sizeChoice == .full ? .full : .longEdge(longEdge) }

    /// The preset as it would be saved. Name and folder are trimmed.
    var preset: DeliveryPreset {
        DeliveryPreset(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), symbol: symbol, format: format,
                       size: size, quality: quality, colour: colour, metadata: metadata,
                       folderName: folderName.trimmingCharacters(in: .whitespacesAndNewlines), isBuiltIn: isBuiltIn)
    }

    var validationError: String? { preset.validationError }
    var canSave: Bool { validationError == nil }

    // MARK: Offered and disabled options

    /// Quality options in the menu: the four levels, or Lossless alone for JPEG XL.
    var qualityOptions: [QualityLevel] { format == .jxlLossless ? [.lossless] : Self.lossyQualities }
    var isQualityPickerEnabled: Bool { format != .jxlLossless }
    /// Balanced is offered only for full-size JPEG.
    func isEnabled(_ level: QualityLevel) -> Bool {
        switch level {
        case .balanced: format == .jpeg && sizeChoice == .full
        case .lossless: format == .jxlLossless
        case .highest, .high, .web: format != .jxlLossless
        }
    }
    /// JPEG XL archives are full size, keep the profile and keep all metadata.
    var isLongEdgeEnabled: Bool { format != .jxlLossless }
    var isConvertToSRGBEnabled: Bool { format != .jxlLossless }
    var isMetadataRemovalEnabled: Bool { format != .jxlLossless }

    /// The built-in this form was opened for, if any.
    var builtInDefault: DeliveryPreset? { isBuiltIn ? DeliveryPreset.builtIns.first { $0.id == id } : nil }
    var canRestoreDefault: Bool { builtInDefault != nil }
    var isAtDefault: Bool { builtInDefault.map { $0 == preset } ?? false }

    /// Restore Default: every field back to the shipped built-in.
    mutating func restoreDefault() {
        guard let builtIn = builtInDefault else { return }
        self = EditDeliveryForm(builtIn)
    }
}

enum EditDeliveryCopy {
    static let editTitle = "Edit Delivery"
    static let newTitle = "New Delivery"
    static func formatTitle(_ format: OutputFormat) -> String {
        switch format {
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .jxlLossless: "JPEG XL (lossless, from JPEG)"
        }
    }

    static func colourTitle(_ colour: ColourHandling) -> String {
        switch colour {
        case .keepProfile: "Keep original profile"
        case .convertToSRGB: "Convert to sRGB"
        }
    }

    static func metadataTitle(_ policy: MetadataPolicy) -> String {
        switch policy {
        case .keepAll: "Keep all"
        case .removeLocation: "Remove location and camera serial"
        case .removeAll: "Remove all except copyright"
        }
    }

    static let colourFooter = "Use sRGB for websites and social media."
}
