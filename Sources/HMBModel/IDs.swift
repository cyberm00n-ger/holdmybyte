import Foundation

public struct WeddingID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
    public var id: UUID { uuid }
    public var description: String { uuid.uuidString }
}

/// Index of a photo in its wedding's capture-time order (0-based). Stable for the life of a record.
public struct PhotoID: Hashable, Codable, Sendable, Comparable {
    public let index: Int
    public init(_ index: Int) { self.index = index }
    public static func < (l: PhotoID, r: PhotoID) -> Bool { l.index < r.index }
}

public struct DeliveryID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let couple  = DeliveryID(rawValue: "couple")
    public static let website = DeliveryID(rawValue: "website")
    public static let social  = DeliveryID(rawValue: "social")
    public static let archive = DeliveryID(rawValue: "archive")
    public static func newCustom() -> DeliveryID { DeliveryID(rawValue: "custom-" + UUID().uuidString.lowercased()) }
}
