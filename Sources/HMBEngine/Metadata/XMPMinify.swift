// XMP without layout whitespace (variant "postpass", Docs/variants/postpass.md). Lightroom's and CGImageMetadata's
// packets are pretty-printed (one level of indentation per element) and Lightroom pads the packet with ~2.5 KB of
// spaces for in-place editing; on the Website and Social deliveries that is 1.3 % of the file. RDF/XML ignores
// whitespace-only text between elements, so dropping it changes nothing a reader sees. The result is only used when
// CGImageMetadata reads exactly the same tags and values from it.
import Foundation
import HMBModel
import ImageIO

/// Which outputs carry minified XMP. `keepAll` promises the source's metadata verbatim, so by default it keeps the
/// packet byte for byte (`.minified` is measured in Docs/variants/postpass.md, an owner decision).
public enum XMPLayout: String, Sendable, Hashable, Codable {
    case verbatim, minifiedUnlessKeepAll, minified
    func minifies(_ policy: MetadataPolicy) -> Bool {
        switch self {
        case .verbatim: false
        case .minifiedUnlessKeepAll: policy != .keepAll
        case .minified: true
        }
    }
}

enum XMPMinify {
    /// `xmp` without whitespace runs that contain a line break and sit between two markup tokens (or end the
    /// packet); nil when nothing would change, the packet holds XML literals (whitespace there is content), or the
    /// result does not read back to the same tags.
    static func minified(_ xmp: Data) -> Data? {
        guard !xmp.isEmpty, xmp.range(of: Data("parseType=\"Literal\"".utf8)) == nil,
              xmp.range(of: Data("parseType='Literal'".utf8)) == nil else { return nil }
        let bytes = [UInt8](xmp)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            out.append(b)
            i += 1
            guard b == UInt8(ascii: ">") else { continue }
            var j = i, lineBreak = false
            while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D {
                if bytes[j] == 0x0A || bytes[j] == 0x0D { lineBreak = true }
                j += 1
            }
            if lineBreak, j == bytes.count || bytes[j] == UInt8(ascii: "<") { i = j }
        }
        guard out.count < bytes.count else { return nil }
        let result = Data(out)
        guard let before = tags(xmp), let after = tags(result), before == after, !before.isEmpty else { return nil }
        return result
    }

    /// Every top-level tag as path → namespace, type, value (arrays, structures and qualifiers expanded), as
    /// CGImageMetadata reads it.
    static func tags(_ xmp: Data) -> [String: String]? {
        guard let metadata = CGImageMetadataCreateFromXMPData(xmp as CFData) else { return nil }
        var out: [String: String] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            out[path as String] = describe(tag)
            return true
        }
        return out
    }

    static func describe(_ tag: CGImageMetadataTag) -> String {
        let ns = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
        let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
        let type = CGImageMetadataTagGetType(tag).rawValue
        let qualifiers = (CGImageMetadataTagCopyQualifiers(tag) as? [CGImageMetadataTag])?.map(describe).joined(separator: ",") ?? ""
        return "\(ns)|\(name)|\(type)|\(describeValue(CGImageMetadataTagCopyValue(tag)))|\(qualifiers)"
    }

    static func describeValue(_ value: CFTypeRef?) -> String {
        guard let value else { return "" }
        if CFGetTypeID(value) == CGImageMetadataTagGetTypeID() { return describe(value as! CGImageMetadataTag) }
        if let array = value as? [CFTypeRef] { return "[" + array.map(describeValue).joined(separator: ",") + "]" }
        if let dictionary = value as? [String: CFTypeRef] {
            return "{" + dictionary.keys.sorted().map { "\($0)=\(describeValue(dictionary[$0]))" }.joined(separator: ",") + "}"
        }
        return String(describing: value)
    }
}
