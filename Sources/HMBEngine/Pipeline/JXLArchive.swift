// Archive (§3.6): lossless JPEG → JPEG XL transcode, effort 7, verified for every file by reconstruction and
// SHA-256 against the source bytes. Anything that is not a Huffman-coded JPEG, or fails verification, is
// copied byte for byte instead (status keptOriginal, encoder "copy"). Metadata policy never applies.
import CryptoKit
import Foundation
import HMBModel
import os

enum JXLArchive {
    static let effort = 7
    private static let log = Logger(subsystem: "eu.sebastianhaas.holdmybyte", category: "archive")

    struct Product: Sendable {
        var data: Data
        var ext: String
        var transcoded: Bool     // false: original bytes copied
    }

    static func make(_ info: SourceInfo, sourceExtension: String, jxl: any JXLTranscoding, cancel: CancelToken,
                     label: String) throws -> Product {
        let copy = Product(data: info.fileBytes, ext: copyExtension(sourceExtension), transcoded: false)
        guard info.kind == .jpeg, !info.isArithmeticCoded else { return copy }
        do {
            try cancel.check()
            let encoded = try jxl.transcodeLossless(jpeg: info.fileBytes, effort: effort)
            try cancel.check()
            let restored = try jxl.reconstructJPEG(jxl: encoded)
            guard SHA256.hash(data: restored) == SHA256.hash(data: info.fileBytes) else {
                log.error("archive verification failed for \(label, privacy: .public): reconstruction differs; original copied")
                return copy
            }
            return Product(data: encoded, ext: OutputFormat.jxlLossless.fileExtension, transcoded: true)
        } catch let error as JobCancelled {
            throw error
        } catch {
            log.error("archive transcode failed for \(label, privacy: .public): \(String(describing: error), privacy: .public); original copied")
            return copy
        }
    }

    /// Extension for a byte copy: the source's own type (".jpeg"/".jpe" normalised to ".jpg").
    static func copyExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe", "": "jpg"
        case "tif", "tiff": "tif"
        case "heif": "heic"
        default: ext.lowercased()
        }
    }
}
