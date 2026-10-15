// Demo wiring for running the real app without the live engine (`HMB_FIXTURE_ENGINE=1 swift run holdmybyte`):
// FixtureEngine replays jobs and never touches the file system. The app target cannot import HMBFixtures directly.
import Foundation
import HMBFixtures
import HMBModel

public enum DemoSupport {
    /// True when `HMB_FIXTURE_ENGINE` is set to a non-empty value other than "0".
    public static var isEnabled: Bool {
        guard let value = ProcessInfo.processInfo.environment["HMB_FIXTURE_ENGINE"] else { return false }
        return !value.isEmpty && value != "0"
    }

    /// A FixtureEngine that replays at `secondsPerPhoto` (default 0.02 s, i.e. a 535-photo wedding in ~11 s).
    public static func engine(secondsPerPhoto: Double = 0.02) -> any EngineService {
        FixtureEngine(.init(estimateDuration: .milliseconds(600), secondsPerPhoto: secondsPerPhoto))
    }

    /// Demo mode keeps everything in memory: the real history and settings are never touched. Starts with the
    /// fixture history (38 weddings) so the sidebar, search and Done views can be tried at once.
    public static func history() -> any HistoryStoring { InMemoryHistory(Fixtures.history) }
    public static func presets() -> any PresetStoring { InMemoryPresets() }
    public static func settings() -> any SettingsStoring { InMemorySettings() }

    /// Synthetic thumbnails (or `HMB_FIXTURE_PHOTOS`).
    public static func thumbnails() -> any ThumbnailProviding { FixtureThumbnails() }
}
