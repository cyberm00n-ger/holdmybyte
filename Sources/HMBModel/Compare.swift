import CoreGraphics
import Foundation

public struct SendableImage: @unchecked Sendable, Hashable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
    public static func == (l: SendableImage, r: SendableImage) -> Bool { l.cgImage === r.cgImage }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(cgImage)) }
}

public struct ComparePair: Sendable, Hashable {
    public var original: SendableImage?      // nil: source unavailable
    public var delivered: SendableImage
    public var originalBytes: Int64
    public var deliveredBytes: Int64
    public var comparedAtLongEdge: Int?      // resized deliveries
    public var unavailableVolume: String?    // e.g. "Wedding SSD"
    public init(original: SendableImage?, delivered: SendableImage, originalBytes: Int64, deliveredBytes: Int64,
                comparedAtLongEdge: Int?, unavailableVolume: String?) {
        self.original = original; self.delivered = delivered; self.originalBytes = originalBytes
        self.deliveredBytes = deliveredBytes; self.comparedAtLongEdge = comparedAtLongEdge
        self.unavailableVolume = unavailableVolume
    }
}
