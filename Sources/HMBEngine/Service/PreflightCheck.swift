// Preflight (§3.1, S5): resolves the output folder (" 2" if it exists), and checks that it is not inside a
// source, that it is writable and that there is room. Writes nothing.
import Darwin
import Foundation
import HMBModel

enum PreflightCheck {
    static func run(_ request: JobRequest, estimatedBytes: Int64?) -> Preflight {
        var output = request.outputFolder.standardizedFileURL
        var notices: [ScanNotice] = []
        let fm = FileManager.default

        if isInsideSource(output, request: request) {
            return Preflight(outputFolder: output, estimatedBytes: estimatedBytes, notices: [.outputInsideSource])
        }
        if !request.appendToExistingFolder, fm.fileExists(atPath: output.path) {
            let parent = output.deletingLastPathComponent(), name = output.lastPathComponent
            var n = 2
            var candidate = parent.appending(path: "\(name) \(n)", directoryHint: .isDirectory)
            while fm.fileExists(atPath: candidate.path) {
                n += 1
                candidate = parent.appending(path: "\(name) \(n)", directoryHint: .isDirectory)
            }
            notices.append(.outputFolderExists(existing: name, used: candidate.lastPathComponent))
            output = candidate
        }

        let anchor = nearestExisting(output)
        let volume = SourceAvailability.volumeName(for: anchor)
        let values = try? anchor.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        if values?.volumeIsReadOnly == true || access(anchor.path, W_OK) != 0 {
            notices.append(.notWritable(volume: volume))
        }
        let needed = estimatedBytes ?? Estimator.roughBytes(photos: scope(request), deliveries: request.deliveries)
        let available = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        if let available, available >= 0, Double(needed) * 1.05 > Double(available) {
            notices.append(.notEnoughSpace(volume: volume, needed: needed, available: available))
        }
        return Preflight(outputFolder: output, estimatedBytes: needed, notices: notices)
    }

    static func scope(_ request: JobRequest) -> [SourcePhoto] {
        request.photos.filter { request.onlyPhotos?.contains($0.id) ?? true }
    }

    /// By identity (symlinks, case variants, hard links) and, for roots that are not reachable, by path.
    static func isInsideSource(_ output: URL, request: JobRequest) -> Bool {
        let guardian = SourceGuard(sourceRoots: request.sourceRoots, sourceFiles: request.photos.map(\.url))
        if guardian.touches(output) { return true }
        let path = output.standardizedFileURL.path.lowercased()
        for root in request.sourceRoots {
            let r = root.standardizedFileURL.path.lowercased()
            if path == r || path.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return true }
        }
        return false
    }

    static func nearestExisting(_ url: URL) -> URL {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        return probe
    }
}
