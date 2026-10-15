import CoreGraphics
import Foundation
import HMBEngine
import HMBModel

/// `hmb score` and `hmb inspect`: thin wrappers over the engine primitives (§3.2).
public struct PrimitiveCommands: Sendable {
    public struct Mismatch: Error, CustomStringConvertible {
        public var description: String
    }

    public let primitives: EnginePrimitives

    public init(primitives: EnginePrimitives) { self.primitives = primitives }

    /// The engine metric (SSIMULACRA2 on the engine scale) of `candidate` against `reference`, both decoded with the
    /// engine decoder at stored orientation. The sizes must match.
    public func score(reference: URL, candidate: URL) throws -> Double {
        let a = try primitives.decoder.decode(primitives.decoder.inspect(reference))
        let b = try primitives.decoder.decode(primitives.decoder.inspect(candidate))
        guard a.width == b.width, a.height == b.height else {
            throw Mismatch(description: "sizes differ: \(a.width)×\(a.height) vs \(b.width)×\(b.height)")
        }
        let prepared = try primitives.metric.prepareReference(a)
        defer { primitives.metric.release(prepared) }
        return try primitives.metric.score(b, against: prepared)
    }

    public struct Inspection: Codable, Sendable, Hashable {
        public struct Marker: Codable, Sendable, Hashable { public var code: String; public var bytes: Int }
        public struct Features: Codable, Sendable, Hashable { public var textureP50: Double; public var chromaEnergy: Double }
        public var file: String
        public var kind: String
        public var fileBytes: Int
        public var width: Int?
        public var height: Int?
        public var colorSpace: String?
        public var orientation: Int
        public var estimatedJPEGQuality: Int?
        public var isCMYK: Bool
        public var isHoldMyByteOutput: Bool
        public var isArithmeticCoded: Bool
        public var markers: [Marker]
        public var iccBytes: Int?
        public var exifBytes: Int?
        public var xmpBytes: Int?
        public var features: Features?
        public var balancedTarget: Double?
        public var decodeError: String?
    }

    /// SourceInfo + features + the Balanced target.
    public func inspect(_ url: URL) throws -> Inspection {
        let info = try primitives.decoder.inspect(url)
        var inspection = Inspection(
            file: url.path, kind: info.kind.rawValue, fileBytes: info.fileBytes.count, width: nil, height: nil, colorSpace: nil,
            orientation: info.orientation, estimatedJPEGQuality: info.estimatedJPEGQuality, isCMYK: info.isCMYK,
            isHoldMyByteOutput: info.isHoldMyByteOutput, isArithmeticCoded: info.isArithmeticCoded,
            markers: info.markers.map { .init(code: String(format: "0x%02X", $0.code), bytes: $0.payload.count) },
            iccBytes: info.iccProfile?.count, exifBytes: info.exif?.count, xmpBytes: info.xmp?.count,
            features: nil, balancedTarget: nil, decodeError: nil)
        do {
            let image = try primitives.decoder.decode(info)
            inspection.width = image.width
            inspection.height = image.height
            inspection.colorSpace = image.colorSpace.name.map { $0 as String }
            let features = primitives.processing.features(image)
            inspection.features = .init(textureP50: features.textureP50, chromaEnergy: features.chromaEnergy)
            inspection.balancedTarget = BalancedTarget.target(textureP50: features.textureP50)
        } catch {
            inspection.decodeError = "\(error)"
        }
        return inspection
    }
}
