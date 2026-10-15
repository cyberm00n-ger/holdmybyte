// Journal (§3.8): `<support>/Jobs/<weddingID>/request.json` + `journal.jsonl` (+ `layout.json`, `finished`).
//
// One PhotoResult per line, appended after the file's rename; fsync every 10 lines, at pause/stop and at the
// end. The `finished` marker file is written last. A truncated last line (crash mid-append) is ignored when
// reading and cut off before the next append.
import Darwin
import Foundation
import HMBModel

/// Resolved on-disk layout of a job, so a resume writes into the same delivery folders.
struct JobLayout: Codable, Sendable, Equatable {
    /// DeliveryID.rawValue → folder name inside the output folder (after " 2" resolution).
    var deliveryFolders: [String: String]
    var createdOutputFolder: Bool
}

final class Journal: @unchecked Sendable {
    static let requestFile = "request.json"
    static let journalFile = "journal.jsonl"
    static let layoutFile = "layout.json"
    static let finishedFile = "finished"
    static let syncEvery = 10

    let directory: URL
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var unsynced = 0
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func directory(support: URL, wedding: WeddingID) -> URL {
        support.appending(path: "Jobs", directoryHint: .isDirectory)
            .appending(path: wedding.description, directoryHint: .isDirectory)
    }

    private init(directory: URL) { self.directory = directory }

    /// Starts a fresh journal (an existing one for the same wedding is discarded).
    static func create(support: URL, request: JobRequest, layout: JobLayout) throws -> Journal {
        let dir = directory(support: support, wedding: request.wedding)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let journal = Journal(directory: dir)
        try journal.writeJSON(request, to: requestFile)
        try journal.writeJSON(layout, to: layoutFile)
        try journal.openForAppend()
        return journal
    }

    /// Re-opens an existing journal for appending (resume); returns nil if there is none.
    static func reopen(support: URL, wedding: WeddingID, layout: JobLayout? = nil, request: JobRequest? = nil) throws -> Journal? {
        let dir = directory(support: support, wedding: wedding)
        guard FileManager.default.fileExists(atPath: dir.appending(path: requestFile).path) else { return nil }
        let journal = Journal(directory: dir)
        try? FileManager.default.removeItem(at: dir.appending(path: finishedFile))
        if let request { try journal.writeJSON(request, to: requestFile) }
        if let layout { try journal.writeJSON(layout, to: layoutFile) }
        try journal.openForAppend()
        return journal
    }

    struct Contents: Sendable {
        var request: JobRequest
        var layout: JobLayout?
        var results: [PhotoResult]          // in journal order; later entries supersede earlier ones
        var finished: Bool
    }

    static func load(support: URL, wedding: WeddingID) -> Contents? { load(directory: directory(support: support, wedding: wedding)) }

    static func load(directory dir: URL) -> Contents? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: dir.appending(path: requestFile)),
              let request = try? decoder.decode(JobRequest.self, from: data) else { return nil }
        let layout = (try? Data(contentsOf: dir.appending(path: layoutFile))).flatMap { try? decoder.decode(JobLayout.self, from: $0) }
        var results: [PhotoResult] = []
        if let lines = try? Data(contentsOf: dir.appending(path: journalFile)) {
            for line in lines.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let r = try? decoder.decode(PhotoResult.self, from: Data(line)) { results.append(r) }   // torn line: skipped
            }
        }
        let finished = FileManager.default.fileExists(atPath: dir.appending(path: finishedFile).path)
        return Contents(request: request, layout: layout, results: results, finished: finished)
    }

    static func discard(support: URL, wedding: WeddingID) {
        try? FileManager.default.removeItem(at: directory(support: support, wedding: wedding))
    }

    /// Every job directory with a request but no finished marker.
    static func unfinished(support: URL) -> [Contents] {
        let jobs = support.appending(path: "Jobs", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: jobs.path) else { return [] }
        return names.sorted().compactMap { load(directory: jobs.appending(path: $0, directoryHint: .isDirectory)) }
            .filter { !$0.finished }
    }

    // MARK: Writing

    private func writeJSON<T: Encodable>(_ value: T, to name: String) throws {
        let data = try encoder.encode(value)
        try data.write(to: directory.appending(path: name), options: .atomic)
    }

    private func openForAppend() throws {
        let path = directory.appending(path: Self.journalFile).path
        let handle = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard handle >= 0 else { throw OutputError.from(errno: errno, path: path) }
        // Cut a torn last line (no trailing newline) so the next append starts on a fresh line.
        let size = lseek(handle, 0, SEEK_END)
        if size > 0 {
            var keep = size
            var byte: UInt8 = 0
            while keep > 0 {
                guard pread(handle, &byte, 1, keep - 1) == 1 else { break }
                if byte == UInt8(ascii: "\n") { break }
                keep -= 1
            }
            if keep != size { ftruncate(handle, keep) }
            lseek(handle, 0, SEEK_END)
        }
        fd = handle
    }

    func append(_ result: PhotoResult) throws {
        var line = try encoder.encode(result)
        line.append(UInt8(ascii: "\n"))
        try lock.withLock {
            guard fd >= 0 else { return }
            try line.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw OutputError.from(errno: errno, path: directory.appending(path: Self.journalFile).path)
                    }
                    offset += n
                }
            }
            unsynced += 1
            if unsynced >= Self.syncEvery { fsync(fd); unsynced = 0 }
        }
    }

    func sync() {
        lock.withLock {
            if fd >= 0 { fsync(fd); unsynced = 0 }
        }
    }

    /// Final fsync, then the `finished` marker.
    func markFinished() throws {
        sync()
        let url = directory.appending(path: Self.finishedFile)
        let handle = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard handle >= 0 else { throw OutputError.from(errno: errno, path: url.path) }
        fsync(handle)
        Darwin.close(handle)
    }

    func close() {
        lock.withLock {
            if fd >= 0 { fsync(fd); Darwin.close(fd); fd = -1 }
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}
