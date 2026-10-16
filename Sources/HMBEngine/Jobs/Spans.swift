// Spans: opt-in timing diagnostics (HMB_SPANS=<file>). Accumulates wall seconds and counts per named span across all
// threads and writes the table when the process exits. Off unless the variable is set; costs one flag check per
// span otherwise. Used to attribute a job's wall time to encode / decode / metric / waits (Docs/variants/speed.md).
import Darwin
import Foundation
import Synchronization

enum Spans {
    private static let totals = Mutex([String: (seconds: Double, count: Int, faults: Int)]())
    static let enabled: Bool = {
        guard let path = ProcessInfo.processInfo.environment["HMB_SPANS"], !path.isEmpty else { return false }
        atexit { Spans.write() }
        return true
    }()

    @inline(__always) static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = monotonicSeconds()
        let faults0 = faults()
        defer {
            let elapsed = monotonicSeconds() - start
            let df = faults() - faults0
            let key = "\(name)"
            totals.withLock { t in
                let old = t[key] ?? (0, 0, 0)
                t[key] = (old.seconds + elapsed, old.count + 1, old.faults + df)
            }
        }
        return try body()
    }

    /// Page faults of the whole task so far (meaningful per span with one worker).
    static func faults() -> Int {
        var info = task_events_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.faults) : 0
    }

    static func write() {
        guard let path = ProcessInfo.processInfo.environment["HMB_SPANS"] else { return }
        let rows = totals.withLock { $0 }.sorted { $0.key < $1.key }
        var text = "span\tseconds\tcount\tmean_ms\tfaults\n"
        for (name, v) in rows {
            text += String(format: "%@\t%.3f\t%d\t%.1f\t%d\n", name, v.seconds, v.count, v.count > 0 ? 1000 * v.seconds / Double(v.count) : 0, v.faults)
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
