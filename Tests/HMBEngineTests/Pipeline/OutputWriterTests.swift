// Acceptance §5.2.1: OutputWriter safety — never into a source, never overwrite, no .tmp left behind.
import Darwin
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite struct OutputWriterTests {
    let dir = TempDir("writer")
    let root: URL
    let photo: URL
    let original = Data("original bytes".utf8)

    init() throws {
        root = dir.sub("Wedding/fertig")
        photo = root.appending(path: "IMG_0001.jpg")
        try original.write(to: photo)
        try Data("nested".utf8).write(to: dir.sub("Wedding/fertig/sub").appending(path: "IMG_0002.jpg"))
    }

    var writer: OutputWriter {
        OutputWriter(guardian: SourceGuard(sourceRoots: [root],
                                           sourceFiles: [photo, root.appending(path: "sub/IMG_0002.jpg")]))
    }

    func refuses(_ directory: URL, stem: String = "x", ext: String = "jpg") -> Bool {
        do {
            _ = try writer.write(Data("new".utf8), directory: directory, stem: stem, ext: ext, adoptIdentical: false,
                                 cancel: CancelToken())
            return false
        } catch OutputError.wouldTouchSource {
            return true
        } catch {
            Issue.record("unexpected error \(error)")
            return false
        }
    }

    @Test func refusesSourceFileAndSourceRoot() throws {
        #expect(refuses(root, stem: "IMG_0001"))                    // the source file itself
        #expect(refuses(root, stem: "new-file"))                    // a new file inside the source root
        #expect(refuses(root.appending(path: "sub"), stem: "y"))    // below a source root
        #expect(try Data(contentsOf: photo) == original)
    }

    @Test func refusesSymlinkToSourceFolder() throws {
        let link = dir.url.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(refuses(link, stem: "z"))
        let fileLink = dir.sub("out").appending(path: "linked.jpg")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: photo)
        // The planned name is a symlink to a source: refused, and the source stays untouched.
        #expect(refuses(dir.sub("out"), stem: "linked"))
        #expect(try Data(contentsOf: photo) == original)
    }

    @Test func refusesCaseVariantPath() throws {
        // APFS is case-insensitive: "FERTIG" names the same folder as "fertig".
        let variant = URL(fileURLWithPath: root.path.replacingOccurrences(of: "/fertig", with: "/FERTIG"))
        guard FileManager.default.fileExists(atPath: variant.path) else { return }   // case-sensitive volume: n/a
        #expect(refuses(variant, stem: "IMG_0001"))
        #expect(refuses(variant, stem: "other"))
    }

    @Test func refusesHardLinkToSource() throws {
        let out = dir.sub("out")
        let hard = out.appending(path: "hard.jpg")
        #expect(link(photo.path, hard.path) == 0)
        #expect(refuses(out, stem: "hard"))
        #expect(try Data(contentsOf: photo) == original)
    }

    @Test func neverOverwritesAndLeavesNoTmp() throws {
        let out = dir.sub("out")
        let existing = out.appending(path: "Finn-0001.jpg")
        try Data("someone else's file".utf8).write(to: existing)
        let a = try writer.write(Data("A".utf8), directory: out, stem: "Finn-0001", ext: "jpg", adoptIdentical: false,
                                 cancel: CancelToken())
        let b = try writer.write(Data("B".utf8), directory: out, stem: "Finn-0001", ext: "jpg", adoptIdentical: false,
                                 cancel: CancelToken())
        #expect(a.url.lastPathComponent == "Finn-0001 2.jpg")
        #expect(b.url.lastPathComponent == "Finn-0001 3.jpg")
        #expect(try Data(contentsOf: existing) == Data("someone else's file".utf8))
        let partial = out.appending(path: OutputWriter.partialDirectoryName)
        #expect(try FileManager.default.contentsOfDirectory(atPath: partial.path).isEmpty)
        writer.cleanPartial(in: out, removeDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func adoptsIdenticalFileOnlyWhenAsked() throws {
        let out = dir.sub("out")
        try Data("same".utf8).write(to: out.appending(path: "a.jpg"))
        let adopted = try writer.write(Data("same".utf8), directory: out, stem: "a", ext: "jpg", adoptIdentical: true,
                                       cancel: CancelToken())
        #expect(adopted.adopted && adopted.url.lastPathComponent == "a.jpg")
        let different = try writer.write(Data("other".utf8), directory: out, stem: "a", ext: "jpg", adoptIdentical: true,
                                         cancel: CancelToken())
        #expect(!different.adopted && different.url.lastPathComponent == "a 2.jpg")
    }

    @Test func cancelledWriteLeavesNothing() throws {
        let out = dir.sub("out")
        let token = CancelToken()
        token.request(.pause(.user))
        #expect(throws: JobCancelled.self) {
            _ = try writer.write(Data("x".utf8), directory: out, stem: "c", ext: "jpg", adoptIdentical: false, cancel: token)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path)
        let partial = (try? FileManager.default.contentsOfDirectory(atPath: out.appending(path: ".holdmybyte-partial").path)) ?? []
        #expect(!names.contains("c.jpg"))
        #expect(partial.isEmpty)
    }

    @Test func injectedErrorsMapToPauseReasons() throws {
        let out = dir.sub("out")
        let full = OutputWriter(guardian: SourceGuard(sourceRoots: [root], sourceFiles: [photo]), faultHook: { _ in ENOSPC })
        #expect(throws: OutputError.diskFull(out.appending(path: "d.jpg").path)) {
            _ = try full.write(Data("x".utf8), directory: out, stem: "d", ext: "jpg", adoptIdentical: false, cancel: CancelToken())
        }
        let readOnly = OutputWriter(guardian: SourceGuard(sourceRoots: [root], sourceFiles: [photo]), faultHook: { _ in EROFS })
        #expect(throws: OutputError.notWritable(out.appending(path: "d.jpg").path)) {
            _ = try readOnly.write(Data("x".utf8), directory: out, stem: "d", ext: "jpg", adoptIdentical: false, cancel: CancelToken())
        }
    }

    @Test func deliveryFolderGetsSuffixUnlessReused() throws {
        let out = dir.sub("out")
        _ = dir.sub("out/Couple")
        #expect(try writer.makeDirectory(in: out, named: "Couple", reuseExisting: false) == "Couple 2")
        #expect(try writer.makeDirectory(in: out, named: "Couple", reuseExisting: true) == "Couple")
        #expect(throws: OutputError.self) { _ = try writer.makeDirectory(in: root, named: "Couple", reuseExisting: false) }
    }
}
