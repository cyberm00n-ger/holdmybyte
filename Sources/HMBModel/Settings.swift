import Foundation

public enum SaveLocation: Codable, Sendable, Hashable { case nextToOriginals, folder(URL) }

public struct AppSettings: Codable, Sendable, Hashable {
    public var saveLocation: SaveLocation = .nextToOriginals
    public var folderNamePattern: String = "{wedding} – Deliveries"   // tokens {wedding} {date} {year}
    public var naming: NamingScheme = .default
    public var notifyWhenFinished = true
    public var playSound = false
    public var menuBarWhileClosed = true
    public var processorUse: ProcessorUse = .automatic
    public var detailedLogs = false
    public init() {}
}
