import Foundation

public enum SourceKind: String, Codable, Sendable { case jpeg, heic, png, tiff }

public struct SourcePhoto: Identifiable, Codable, Sendable, Hashable {
    public var id: PhotoID
    public var url: URL
    public var relativePath: String          // relative to its source root
    public var byteCount: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var captureDate: Date?
    public var camera: String?
    public var kind: SourceKind
    public var modified: Date
    public init(id: PhotoID, url: URL, relativePath: String, byteCount: Int64, pixelWidth: Int, pixelHeight: Int,
                captureDate: Date?, camera: String?, kind: SourceKind, modified: Date) {
        self.id = id; self.url = url; self.relativePath = relativePath; self.byteCount = byteCount
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.captureDate = captureDate
        self.camera = camera; self.kind = kind; self.modified = modified
    }
}

public enum NoticeSeverity: String, Codable, Sendable { case info, warning, block }

public enum ScanNotice: Codable, Sendable, Hashable {
    case skippedNonPhotos(count: Int, extensions: [String])
    case skippedRaw(count: Int)
    case cmyk(count: Int)
    case alreadyCompressed(count: Int, of: Int)
    case holdMyByteOutput(count: Int)
    case convertedToJPEG(count: Int)
    case outputFolderExists(existing: String, used: String)
    case notEnoughSpace(volume: String, needed: Int64, available: Int64)
    case notWritable(volume: String)
    case outputInsideSource
    public var severity: NoticeSeverity {
        switch self {
        case .skippedNonPhotos, .skippedRaw, .convertedToJPEG, .outputFolderExists: .info
        case .cmyk, .alreadyCompressed, .holdMyByteOutput: .warning
        case .notEnoughSpace, .notWritable, .outputInsideSource: .block
        }
    }
}

public struct ScanResult: Codable, Sendable, Hashable {
    public var photos: [SourcePhoto]         // capture order; ids are 0..<count
    public var sourceRoots: [URL]
    public var suggestedName: String
    public var weddingDate: Date?
    public var camera: String?               // most frequent Model
    public var totalBytes: Int64
    public var rawCount: Int
    public var notices: [ScanNotice]
    public init(photos: [SourcePhoto], sourceRoots: [URL], suggestedName: String, weddingDate: Date?,
                camera: String?, totalBytes: Int64, rawCount: Int, notices: [ScanNotice]) {
        self.photos = photos; self.sourceRoots = sourceRoots; self.suggestedName = suggestedName
        self.weddingDate = weddingDate; self.camera = camera; self.totalBytes = totalBytes
        self.rawCount = rawCount; self.notices = notices
    }
}

public enum ScanUpdate: Sendable {
    case progress(found: Int)
    case finished(ScanResult)
}

/// Generic folder names (case-insensitive) that defer to the parent folder's name.
public enum WeddingNaming {
    public static let genericFolderNames: Set<String> = ["export", "exports", "final", "finals", "fertig", "jpg", "jpeg",
        "jpgs", "selects", "edited", "bearbeitet", "output", "delivery", "lieferung", "web", "highres", "full"]

    /// Used when no folder name is usable (empty input, or nothing but generic names up to the volume root).
    static let fallbackName = "Untitled Wedding"

    /// Applies the rule in §2.4 S4. `folders` = dropped folders (or the common parent of dropped files).
    /// One folder: its name; if that name is generic, the nearest non-generic ancestor's name.
    /// Several folders: the same rule applied to their deepest common ancestor.
    public static func suggestedName(for folders: [URL]) -> String {
        guard var folder = commonAncestor(of: folders) else { return fallbackName }
        while true {
            let name = folder.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name == "/" { return fallbackName }
            if !isGeneric(name) { return name }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent.path == folder.path || parent.path == "/" || parent.path == "/Volumes" { return fallbackName }
            folder = parent
        }
    }

    /// "Finn und Lissy" → "Finn-und-Lissy" (whitespace → "-", removes / : \)
    public static func slug(_ name: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in name.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingDash = !result.isEmpty
                continue
            }
            if scalar == "/" || scalar == ":" || scalar == "\\" { continue }
            if pendingDash { result.append("-"); pendingDash = false }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    static func isGeneric(_ name: String) -> Bool { genericFolderNames.contains(name.lowercased()) }

    static func commonAncestor(of urls: [URL]) -> URL? {
        let paths = urls.map { $0.standardizedFileURL.pathComponents }
        guard var common = paths.first else { return nil }
        for components in paths.dropFirst() {
            var n = 0
            while n < common.count, n < components.count, common[n] == components[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        guard !common.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }
}
