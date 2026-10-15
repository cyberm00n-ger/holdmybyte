import Foundation
import HMBModel

/// History on disk: one `record.json` per wedding in `<directory>/<wedding id>/` (Docs/SPEC.md §5.4).
///
/// - Writes are atomic (temporary file + rename), so a crash leaves either the old or the new record.
/// - A record that cannot be decoded is quarantined: `record.json` is renamed `record.json.corrupt` (or
///   `record.json.corrupt 2`, … if that exists), logged, and skipped. A file that cannot be read at all (permissions,
///   I/O error) is skipped but left in place. Loading never fails because of one record.
/// - `loadAll` decodes the records in parallel and returns them newest wedding first (wedding date, then creation
///   date), the order the sidebar groups them in.
public actor JSONHistoryStore: HistoryStoring {
    public nonisolated let directory: URL
    /// Files quarantined by the last `loadAll` (for tests and diagnostics).
    public private(set) var lastQuarantined: [URL] = []

    public static let recordFileName = "record.json"

    public init(directory: URL = StoreLocations.weddings) {
        self.directory = directory
    }

    public func loadAll() async throws -> [WeddingRecord] {
        let files = recordFiles()
        let decoded = Self.decodeAll(files)
        var records: [WeddingRecord] = []
        var quarantined: [URL] = []
        for (file, outcome) in zip(files, decoded) {
            switch outcome {
            case .success(let record): records.append(record)
            case .failure(let error) where error is DecodingError:
                storeLog.error("Quarantining unreadable record \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
                if let moved = Self.quarantine(file) { quarantined.append(moved) }
            case .failure(let error):
                // Could not be read (permissions, I/O): skipped this time, but never renamed. Only a file whose
                // contents are not a record is quarantined.
                storeLog.error("Skipping record that could not be read \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        lastQuarantined = quarantined
        return records.sorted(by: Self.newestFirst)
    }

    public func save(_ record: WeddingRecord) async throws {
        let folder = folder(for: record.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(record)
        try data.write(to: folder.appending(path: Self.recordFileName, directoryHint: .notDirectory), options: .atomic)
    }

    /// Removes the wedding's entry (its folder in the history directory). Delivered photos are never touched:
    /// the store only ever writes inside `directory`.
    public func remove(_ id: WeddingID) async throws {
        let folder = folder(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func removeAll() async throws {
        for folder in weddingFolders() { try FileManager.default.removeItem(at: folder) }
    }

    /// `<directory>/<uuid>/`.
    public nonisolated func folder(for id: WeddingID) -> URL {
        directory.appending(path: id.uuid.uuidString, directoryHint: .isDirectory)
    }

    // MARK: Private

    /// Only folders named like a wedding id are ours; anything else in the directory is left alone.
    private func weddingFolders() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return contents.filter { url in
            UUID(uuidString: url.lastPathComponent) != nil
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func recordFiles() -> [URL] {
        weddingFolders()
            .map { $0.appending(path: Self.recordFileName, directoryHint: .notDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private static func decodeAll(_ files: [URL]) -> [Result<WeddingRecord, any Error>] {
        let results = UnsafeMutableBufferPointer<Result<WeddingRecord, any Error>?>.allocate(capacity: files.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        let slots = UncheckedSendableBuffer(buffer: results)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let decoder = JSONDecoder()
            slots.buffer[i] = Result {
                let data = try Data(contentsOf: files[i], options: .mappedIfSafe)
                return try decoder.decode(WeddingRecord.self, from: data)
            }
        }
        return results.map { $0! }
    }

    /// Renames `file` to `<name>.corrupt` (adding " 2", " 3", … if taken). Returns the new location.
    private static func quarantine(_ file: URL) -> URL? {
        let folder = file.deletingLastPathComponent()
        let base = file.lastPathComponent + ".corrupt"
        var candidate = folder.appending(path: base, directoryHint: .notDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) \(n)", directoryHint: .notDirectory)
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: file, to: candidate)
            return candidate
        } catch {
            storeLog.error("Could not quarantine \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static func newestFirst(_ a: WeddingRecord, _ b: WeddingRecord) -> Bool {
        let da = a.weddingDate ?? a.createdAt, db = b.weddingDate ?? b.createdAt
        if da != db { return da > db }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.uuid.uuidString < b.id.uuid.uuidString
    }
}

/// Lets `concurrentPerform` workers write disjoint slots of one buffer.
private struct UncheckedSendableBuffer<T>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<T>
}
