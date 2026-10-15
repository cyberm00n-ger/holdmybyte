import Foundation
import HMBModel

/// The `--delivery` names of `hmb` (§5.5) and the old engine's equivalents for A/B runs.
public enum DeliveryCatalog {
    public struct UnknownDelivery: Error, CustomStringConvertible {
        public var name: String
        public var description: String { "unknown delivery “\(name)” (use one of: \(DeliveryCatalog.names.joined(separator: ", ")))" }
    }

    public struct InvalidPreset: Error, CustomStringConvertible {
        public var message: String
        public var description: String { "invalid delivery preset: \(message)" }
    }

    public static let names = ["couple", "website", "social", "archive", "high-full", "highest-full"]

    /// G4's custom "High full-size": JPEG, full size, ≥ 85, keep everything.
    public static let highFull = DeliveryPreset(id: DeliveryID(rawValue: "high-full"), name: "High full-size", symbol: "photo",
                                                format: .jpeg, size: .full, quality: .high, colour: .keepProfile,
                                                metadata: .keepAll, folderName: "High")
    public static let highestFull = DeliveryPreset(id: DeliveryID(rawValue: "highest-full"), name: "Highest full-size",
                                                   symbol: "star", format: .jpeg, size: .full, quality: .highest,
                                                   colour: .keepProfile, metadata: .keepAll, folderName: "Highest")

    public static func preset(named name: String) throws -> DeliveryPreset {
        switch name.lowercased() {
        case "couple": DeliveryPreset.builtIns[0]
        case "website": DeliveryPreset.builtIns[1]
        case "social": DeliveryPreset.builtIns[2]
        case "archive": DeliveryPreset.builtIns[3]
        case "high-full": highFull
        case "highest-full": highestFull
        default: throw UnknownDelivery(name: name)
        }
    }

    /// A `DeliveryPreset` JSON file (the Codable form the app stores), validated with `validationError`.
    public static func preset(jsonAt url: URL) throws -> DeliveryPreset {
        let preset = try JSONDecoder().decode(DeliveryPreset.self, from: Data(contentsOf: url))
        if let message = preset.validationError { throw InvalidPreset(message: message) }
        return preset
    }

    /// Arguments for the old `squeeze` CLI that correspond to `preset`, or nil when it has no equivalent.
    public static func oldEngineArguments(for preset: DeliveryPreset) -> [String]? {
        switch preset.id.rawValue {
        case "couple": ["-p", "classic"]
        case "website": ["-p", "web"]
        case "social": ["-p", "social"]
        case "archive": ["-p", "archive"]
        case "high-full": ["-t", "85"]
        case "highest-full": ["-t", "90"]
        default: nil
        }
    }
}

/// The Balanced per-photo target (§3.3, ported from jpegos `ClassicTarget.swift`).
public enum BalancedTarget {
    public static func target(textureP50: Double) -> Double {
        textureP50 < 4.5 ? 74 : min(87, max(75, 88 - 0.62 * textureP50))
    }
}
