// Where the stores keep their files (Docs/SPEC.md §5.4). Every store takes its directory or defaults in `init`,
// so tests run against temporary directories and suites, never against the user's real data.
import Foundation
import os

public enum StoreLocations {
    /// `~/Library/Application Support/holdmybyte`.
    public static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: "holdmybyte", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/holdmybyte/Weddings` (one folder per wedding, `record.json` inside).
    public static var weddings: URL { applicationSupport.appending(path: "Weddings", directoryHint: .isDirectory) }

    /// `~/Library/Caches/eu.sebastianhaas.holdmybyte/Thumbnails`.
    public static var thumbnails: URL {
        URL.cachesDirectory.appending(path: "eu.sebastianhaas.holdmybyte", directoryHint: .isDirectory)
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
    }
}

let storeLog = Logger(subsystem: "eu.sebastianhaas.holdmybyte", category: "store")
