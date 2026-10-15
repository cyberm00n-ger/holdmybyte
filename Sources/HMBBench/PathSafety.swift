import Darwin
import Foundation

/// The CLI's own guard before it hands anything to the engine (§5.5: every command refuses to write inside a source).
/// The engine's `OutputWriter` enforces the same rule per file; this check fails early, before any work, and also
/// covers the files the CLI writes itself (reports, CSVs, old-engine outputs).
public enum PathSafety {
    public struct Violation: Error, CustomStringConvertible, Equatable {
        public var output: String
        public var source: String
        public var description: String { "refusing to write to \(output): it is inside the source \(source)" }
    }

    /// Throws when `output` is a source file, a source folder, or lies below one (after resolving symlinks, comparing
    /// case- and normalisation-insensitively as APFS does, and comparing device and inode of every existing ancestor).
    /// A loose source file's folder counts as a source root.
    public static func check(output: URL, sources: [URL]) throws {
        let target = resolved(output)
        let targetChain = identities(of: target)
        for source in sources {
            let resolvedSource = resolved(source)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: resolvedSource.path, isDirectory: &isDirectory)
            let roots = exists && !isDirectory.boolValue ? [resolvedSource, resolvedSource.deletingLastPathComponent()] : [resolvedSource]
            for root in roots {
                let rootKey = key(root)
                let targetKey = key(target)
                if targetKey == rootKey || targetKey.hasPrefix(rootKey.hasSuffix("/") ? rootKey : rootKey + "/") {
                    throw Violation(output: output.path, source: root.path)
                }
                if let identity = identity(of: root), targetChain.contains(identity) {
                    throw Violation(output: output.path, source: root.path)
                }
            }
        }
    }

    /// Absolute, standardised, with symlinks resolved for the part that exists.
    static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var result = URL(fileURLWithPath: realpath(existing.path) ?? existing.path)
        for component in tail { result.append(path: component) }
        return result.standardizedFileURL
    }

    static func realpath(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func key(_ url: URL) -> String {
        url.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    struct Identity: Hashable { var device: dev_t; var inode: ino_t }

    static func identity(of url: URL) -> Identity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    /// Identities of `url` and each existing ancestor.
    static func identities(of url: URL) -> Set<Identity> {
        var result: Set<Identity> = []
        var current = url
        while true {
            if let identity = identity(of: current) { result.insert(identity) }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
        return result
    }
}
