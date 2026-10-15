// HMBBench (WP5, Docs/SPEC.md §5.5): the bench runner, its reports and gates, the baselines, and the command-line
// front end that `hmb` calls. Everything here talks to the engine through `EngineService` (the same protocol the app
// uses), so the CLI goes through the engine's `OutputWriter` for every delivered file.
import HMBEngine
import HMBModel

public enum HMBBench {
    /// Version of the report schema (`BenchReport.schema`).
    public static let reportSchema = 1
}
