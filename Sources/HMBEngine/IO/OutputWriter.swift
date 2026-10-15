// OutputWriter (§3.8): the only code in the app that writes into delivery folders.
//
// 1. Source protection: every target (and each of its existing ancestors) is compared by (device, inode) with
//    every source file and every source root/folder. Comparing identities instead of path strings covers
//    symlinks, case variants (APFS is case-insensitive) and hard links. Violations throw `.wouldTouchSource`.
// 2. Staging: bytes go to `<deliveryDir>/.holdmybyte-partial/<UUID>.tmp` (O_CREAT|O_EXCL, fsync) and are moved
//    into place with renamex_np(RENAME_EXCL): an existing file is never replaced; a clash retries " 2", " 3", …
// 3. A cancelled or failed write removes its .tmp.
import Darwin
import Foundation
import HMBModel

public enum OutputError: Error, Sendable, Equatable, CustomStringConvertible {
    case wouldTouchSource(String)
    case diskFull(String)
    case notWritable(String)
    case io(String, Int32)

    public var description: String {
        switch self {
        case .wouldTouchSource(let p): "refused to write at \(p): it is a source or inside a source folder"
        case .diskFull(let p): "disk full while writing \(p)"
        case .notWritable(let p): "not writable: \(p)"
        case .io(let p, let e): "I/O error \(e) (\(String(cString: strerror(e)))) at \(p)"
        }
    }

    static func from(errno code: Int32, path: String) -> OutputError {
        switch code {
        case ENOSPC, EDQUOT: .diskFull(path)
        case EACCES, EROFS, EPERM: .notWritable(path)
        default: .io(path, code)
        }
    }
}

/// File identity on disk.
struct FileIdentity: Hashable, Sendable {
    var device: dev_t
    var inode: ino_t

    /// Identity of `path`, following symlinks; nil if it does not exist.
    static func of(_ path: String) -> FileIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileIdentity(device: st.st_dev, inode: st.st_ino)
    }
}

/// The set of everything the job must never write to or below.
final class SourceGuard: Sendable {
    private let files: Set<FileIdentity>
    private let folders: Set<FileIdentity>

    init(sourceRoots: [URL], sourceFiles: [URL]) {
        var files = Set<FileIdentity>(), folders = Set<FileIdentity>()
        for url in sourceFiles {
            if let id = FileIdentity.of(url.path) { files.insert(id) }
            if let id = FileIdentity.of(url.deletingLastPathComponent().path) { folders.insert(id) }
        }
        for url in sourceRoots {
            guard let id = FileIdentity.of(url.path) else { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.insert(id)
            } else {
                files.insert(id)
                if let parent = FileIdentity.of(url.deletingLastPathComponent().path) { folders.insert(parent) }
            }
        }
        self.files = files
        self.folders = folders
    }

    /// Throws if `url` is a source file, a source folder or anywhere below one.
    func check(_ url: URL) throws {
        var current = url.standardizedFileURL.path
        var isTarget = true
        while true {
            if let id = FileIdentity.of(current) {
                if folders.contains(id) || (isTarget && files.contains(id)) {
                    throw OutputError.wouldTouchSource(url.path)
                }
            }
            isTarget = false
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return }
            current = parent
        }
    }

    /// True if `url` is a source or inside a source folder.
    func touches(_ url: URL) -> Bool { (try? check(url)) == nil }
}

final class OutputWriter: Sendable {
    static let partialDirectoryName = ".holdmybyte-partial"

    let guardian: SourceGuard
    /// Test hook: returns an errno to inject for a write to the given final path (e.g. ENOSPC).
    let faultHook: (@Sendable (URL) -> Int32?)?
    /// Test hook: called after a successful rename, before the result is journaled (crash simulation).
    let afterRename: (@Sendable (URL) throws -> Void)?

    init(guardian: SourceGuard, faultHook: (@Sendable (URL) -> Int32?)? = nil,
         afterRename: (@Sendable (URL) throws -> Void)? = nil) {
        self.guardian = guardian
        self.faultHook = faultHook
        self.afterRename = afterRename
    }

    /// Creates `parent/name`, or `parent/name 2`, … if it exists (unless `reuseExisting`). Returns the name used.
    func makeDirectory(in parent: URL, named name: String, reuseExisting: Bool) throws -> String {
        try guardian.check(parent.appending(path: name, directoryHint: .isDirectory))
        try createDirectoryChain(parent)
        var attempt = 1
        while true {
            let candidate = attempt == 1 ? name : "\(name) \(attempt)"
            let url = parent.appending(path: candidate, directoryHint: .isDirectory)
            try guardian.check(url)
            if mkdir(url.path, 0o755) == 0 { return candidate }
            let code = errno
            guard code == EEXIST else { throw OutputError.from(errno: code, path: url.path) }
            var isDirectory: ObjCBool = false
            if reuseExisting, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue, FileIdentity.of(url.path) != nil, !isSymlink(url.path) {
                return candidate
            }
            attempt += 1
            guard attempt < 10_000 else { throw OutputError.io(url.path, EEXIST) }
        }
    }

    /// mkdir -p for the output folder chain (each created component is checked against the sources first).
    func createDirectoryChain(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw OutputError.io(path, ENOTDIR) }
            return
        }
        try createDirectoryChain(url.deletingLastPathComponent())
        try guardian.check(url)
        if mkdir(path, 0o755) != 0, errno != EEXIST { throw OutputError.from(errno: errno, path: path) }
    }

    private func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    struct Written: Sendable {
        var url: URL
        var adopted: Bool        // an identical file was already there (resume after a crash)
    }

    /// Writes `data` as `directory/stem.ext` (or "stem 2.ext", …). With `adoptIdentical`, an existing file at the
    /// planned name with exactly these bytes is taken as already written (crash between rename and journal).
    func write(_ data: Data, directory: URL, stem: String, ext: String, adoptIdentical: Bool,
               cancel: CancelToken) throws -> Written {
        let planned = directory.appending(path: "\(stem).\(ext)")
        try guardian.check(planned)
        if adoptIdentical, let existing = try? Data(contentsOf: planned, options: .mappedIfSafe), existing == data {
            return Written(url: planned, adopted: true)
        }
        try cancel.check()
        if let injected = faultHook?(planned) { throw OutputError.from(errno: injected, path: planned.path) }

        let partial = directory.appending(path: Self.partialDirectoryName, directoryHint: .isDirectory)
        try guardian.check(partial)
        if mkdir(partial.path, 0o755) != 0, errno != EEXIST { throw OutputError.from(errno: errno, path: partial.path) }
        let tmp = partial.appending(path: UUID().uuidString + ".tmp")
        try guardian.check(tmp)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw OutputError.from(errno: errno, path: tmp.path) }
        var keepTmp = false
        defer { if !keepTmp { unlink(tmp.path) } }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw OutputError.from(errno: errno, path: tmp.path)
                    }
                    offset += n
                }
            }
            if fsync(fd) != 0 { throw OutputError.from(errno: errno, path: tmp.path) }
        }
        try cancel.check()

        var attempt = 1
        while true {
            let name = attempt == 1 ? "\(stem).\(ext)" : "\(stem) \(attempt).\(ext)"
            let final = directory.appending(path: name)
            try guardian.check(final)
            if renamex_np(tmp.path, final.path, UInt32(RENAME_EXCL)) == 0 {
                keepTmp = true          // it is the final file now
                try afterRename?(final)
                return Written(url: final, adopted: false)
            }
            let code = errno
            guard code == EEXIST else { throw OutputError.from(errno: code, path: final.path) }
            attempt += 1
            guard attempt < 10_000 else { throw OutputError.io(final.path, EEXIST) }
        }
    }

    /// Removes leftover `.tmp` files (and the partial directory, when `removeDirectory`) inside a delivery folder.
    func cleanPartial(in directory: URL, removeDirectory: Bool) {
        let partial = directory.appending(path: Self.partialDirectoryName, directoryHint: .isDirectory)
        guard !guardian.touches(partial),
              let names = try? FileManager.default.contentsOfDirectory(atPath: partial.path) else { return }
        for name in names where name.hasSuffix(".tmp") { unlink(partial.appending(path: name).path) }
        if removeDirectory { rmdir(partial.path) }
    }
}
