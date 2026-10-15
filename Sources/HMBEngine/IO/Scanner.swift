// Scanner (§3.8): recursive, metadata-only scan of dropped items.
//
// Skips hidden items, packages, symlinks, `.holdmybyte-partial` and folders ending in " – Deliveries".
// Accepts .jpg .jpeg .jpe .heic .heif .png .tif .tiff (UTType-verified); counts RAW and other files.
// Reads properties with CGImageSourceCopyPropertiesAtIndex only (no decode), plus the JPEG header bytes for the
// DQT quality estimate and the holdmybyte COM marker. Sort order: capture date, then relative path.
import Foundation
import HMBModel
import ImageIO
import UniformTypeIdentifiers

struct Scanner: Sendable {
    static let acceptedExtensions: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif", "png", "tif", "tiff"]
    static let rawExtensions: Set<String> = ["cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef",
                                             "dng", "srw", "x3f", "3fr", "iiq", "erf", "mef", "mos", "rwl"]
    static let deliveriesSuffix = " \u{2013} Deliveries"
    /// "Already compressed" notice: DQT quality below this on more than `precompressedShare` of the JPEGs.
    static let precompressedQuality = 90
    static let precompressedShare = 0.2

    /// One accepted file found by the walk.
    struct Candidate: Sendable {
        var url: URL
        var root: URL
        var byteCount: Int64
        var modified: Date
        var kind: SourceKind
    }

    /// Per-file facts read from the properties and the header.
    struct Facts: Sendable {
        var width = 0, height = 0
        var captureDate: Date?
        var camera: String?
        var isCMYK = false
        var jpegQuality: Int?
        var isHoldMyByteOutput = false
        var readable = true
    }

    func scan(_ items: [URL], progress: (Int) -> Void) -> ScanResult {
        var candidates: [Candidate] = []
        var rawCount = 0
        var otherCount = 0
        var otherExtensions = Set<String>()
        var roots: [URL] = []
        var droppedFolders: [URL] = []
        var lastProgress = monotonicSeconds()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey,
                                      .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]

        func consider(_ url: URL, root: URL, values: URLResourceValues) {
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isHidden != true else { return }
            let ext = url.pathExtension.lowercased()
            if Self.acceptedExtensions.contains(ext), let kind = Self.kind(forExtension: ext) {
                candidates.append(Candidate(url: url, root: root, byteCount: Int64(values.fileSize ?? 0),
                                            modified: values.contentModificationDate ?? .distantPast, kind: kind))
                let now = monotonicSeconds()
                if now - lastProgress >= 0.1 { lastProgress = now; progress(candidates.count) }
            } else if Self.rawExtensions.contains(ext) {
                rawCount += 1
            } else {
                otherCount += 1
                if !ext.isEmpty { otherExtensions.insert(ext.uppercased()) }
            }
        }

        for item in items {
            let url = item.standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                // A dropped " – Deliveries" folder itself is scanned (its COM markers raise the holdmybyte-output
                // notice); only nested ones are skipped.
                guard values.isPackage != true, url.lastPathComponent != OutputWriter.partialDirectoryName else { continue }
                roots.append(url); droppedFolders.append(url)
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let child as URL in walker {
                    guard let v = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                    if v.isSymbolicLink == true { if v.isDirectory == true { walker.skipDescendants() }; continue }
                    if v.isDirectory == true {
                        if v.isPackage == true || Self.isSkippedFolder(child.lastPathComponent) { walker.skipDescendants() }
                        continue
                    }
                    consider(child, root: url, values: v)
                }
            } else {
                let parent = url.deletingLastPathComponent()
                if !roots.contains(parent) { roots.append(parent) }
                consider(url, root: parent, values: values)
            }
        }

        // Metadata, in parallel (properties only; no pixel decode).
        let facts = Locked([Facts](repeating: Facts(), count: candidates.count))
        let list = candidates
        let chunk = 16
        DispatchQueue.concurrentPerform(iterations: (list.count + chunk - 1) / chunk) { block in
            var local: [(Int, Facts)] = []
            for i in (block * chunk)..<min(list.count, (block + 1) * chunk) {
                local.append((i, Self.readFacts(list[i])))
            }
            facts.withLock { all in for (i, f) in local { all[i] = f } }
        }
        let allFacts = facts.snapshot

        var photos: [(Candidate, Facts)] = Array(zip(candidates, allFacts))
        photos.sort { a, b in
            switch (a.1.captureDate, b.1.captureDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let order = Self.relativePath(a.0.url, root: a.0.root).localizedStandardCompare(Self.relativePath(b.0.url, root: b.0.root))
                return order == .orderedSame ? a.0.url.path < b.0.url.path : order == .orderedAscending
            }
        }

        let sourcePhotos = photos.enumerated().map { index, entry in
            SourcePhoto(id: PhotoID(index), url: entry.0.url, relativePath: Self.relativePath(entry.0.url, root: entry.0.root),
                        byteCount: entry.0.byteCount, pixelWidth: entry.1.width, pixelHeight: entry.1.height,
                        captureDate: entry.1.captureDate, camera: entry.1.camera, kind: entry.0.kind,
                        modified: entry.0.modified)
        }

        var notices: [ScanNotice] = []
        if otherCount > 0 { notices.append(.skippedNonPhotos(count: otherCount, extensions: otherExtensions.sorted())) }
        if rawCount > 0 { notices.append(.skippedRaw(count: rawCount)) }
        let cmyk = allFacts.filter(\.isCMYK).count
        if cmyk > 0 { notices.append(.cmyk(count: cmyk)) }
        let jpegCount = candidates.filter { $0.kind == .jpeg }.count
        let precompressed = allFacts.filter { ($0.jpegQuality ?? 100) < Self.precompressedQuality }.count
        if jpegCount > 0, Double(precompressed) > Self.precompressedShare * Double(jpegCount) {
            notices.append(.alreadyCompressed(count: precompressed, of: jpegCount))
        }
        let ours = allFacts.filter(\.isHoldMyByteOutput).count
        if ours > 0 { notices.append(.holdMyByteOutput(count: ours)) }
        let converted = candidates.count - jpegCount
        if converted > 0 { notices.append(.convertedToJPEG(count: converted)) }

        var cameraCounts: [String: Int] = [:]
        for f in allFacts { if let c = f.camera { cameraCounts[c, default: 0] += 1 } }
        let camera = cameraCounts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key

        let nameFolders = droppedFolders.isEmpty ? roots : droppedFolders + roots.filter { !droppedFolders.contains($0) }
        return ScanResult(photos: sourcePhotos, sourceRoots: roots,
                          suggestedName: WeddingNaming.suggestedName(for: nameFolders),
                          weddingDate: sourcePhotos.compactMap(\.captureDate).min(), camera: camera,
                          totalBytes: sourcePhotos.reduce(0) { $0 + $1.byteCount }, rawCount: rawCount, notices: notices)
    }

    static func isSkippedFolder(_ name: String) -> Bool {
        name == OutputWriter.partialDirectoryName || name.hasSuffix(deliveriesSuffix) || name.hasPrefix(".")
    }

    static func kind(forExtension ext: String) -> SourceKind? {
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return nil }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .tiff) { return .tiff }
        return nil
    }

    static func relativePath(_ url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    static func readFacts(_ c: Candidate) -> Facts {
        var facts = Facts()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(c.url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            facts.readable = false
            return facts
        }
        facts.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        facts.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        facts.isCMYK = (props[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelCMYK as String)
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            facts.camera = model
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            facts.captureDate = parseEXIFDate(original, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
                                              subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
        }
        if c.kind == .jpeg, let header = try? JPEGContainer.readHeader(of: c.url, limit: 256 * 1024) {
            for segment in JPEGContainer.headerSegments(header) {
                if segment.code == 0xDB, facts.jpegQuality == nil {
                    facts.jpegQuality = JPEGMarkerScan.estimateQuality(dqt: segment.payload)
                } else if segment.code == 0xFE,
                          String(decoding: segment.payload, as: UTF8.self).localizedCaseInsensitiveContains("holdmybyte") {
                    facts.isHoldMyByteOutput = true
                }
            }
        }
        return facts
    }

    /// "2026:07:12 14:03:22" with optional "+02:00" offset and subseconds "45"; local time zone without offset.
    static func parseEXIFDate(_ text: String, offset: String?, subseconds: String?) -> Date? {
        let digits = text.unicodeScalars.split { !CharacterSet.decimalDigits.contains($0) }.map { Int(String($0)) ?? 0 }
        guard digits.count >= 6, digits[0] > 1800, (1...12).contains(digits[1]), (1...31).contains(digits[2]) else { return nil }
        var zone = TimeZone.current
        if let offset, let parsed = parseOffset(offset) { zone = parsed }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: digits[0], month: digits[1], day: digits[2],
                                        hour: digits[3], minute: digits[4], second: digits[5])
        guard var date = calendar.date(from: components) else { return nil }
        if let subseconds, let value = Double("0." + subseconds.filter(\.isNumber)) { date += value }
        return date
    }

    static func parseOffset(_ text: String) -> TimeZone? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 6, let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let parts = t.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (h * 3600 + m * 60))
    }
}
