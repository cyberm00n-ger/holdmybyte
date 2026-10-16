// MemoryTrace: opt-in diagnostics for the §3.9 memory budget (HMB_MEMTRACE=<file>). Samples the process's
// physical footprint and resident size every 0.25 s together with how many workers are in each pipeline phase, so a
// peak can be attributed. Off unless the variable is set; costs one flag check per phase change otherwise.
import Darwin
import Foundation
import Synchronization

enum MemoryTrace {
    enum Phase: Int, CaseIterable { case decode, small, fullWait, full, archiveWait, archive }

    private static let counters = Mutex([Int](repeating: 0, count: Phase.allCases.count))
    static let enabled: Bool = {
        guard let path = ProcessInfo.processInfo.environment["HMB_MEMTRACE"], !path.isEmpty else { return false }
        start(path: path)
        return true
    }()

    @inline(__always) static func enter(_ phase: Phase) {
        guard enabled else { return }
        counters.withLock { $0[phase.rawValue] += 1 }
    }
    @inline(__always) static func leave(_ phase: Phase) {
        guard enabled else { return }
        counters.withLock { $0[phase.rawValue] -= 1 }
    }
    static func during<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T {
        enter(phase)
        defer { leave(phase) }
        return try body()
    }

    private static let marks = Mutex<FileHandle?>(nil)
    /// Writes one line with the current footprint (single-worker step attribution).
    static func mark(_ label: @autoclosure () -> String) {
        guard enabled else { return }
        let s = sample()
        let line = String(format: "mark\t%lld\t%lld\t", s.footprint >> 20, s.resident >> 20) + label() + "\n"
        marks.withLock { $0?.write(Data(line.utf8)) }
    }

    /// (physical footprint, resident) in bytes.
    static func sample() -> (footprint: Int64, resident: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, 0) }
        return (Int64(info.phys_footprint), Int64(info.resident_size))
    }

    private static func start(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        marks.withLock { $0 = handle }
        let thread = Thread {
            let t0 = monotonicSeconds()
            var peak: Int64 = 0
            handle.write(Data("t\tfootprintMB\trssMB\tpeakMB\t\(Phase.allCases.map { "\($0)" }.joined(separator: "\t"))\n".utf8))
            while true {
                let s = sample()
                peak = max(peak, s.footprint)
                let phases = counters.withLock { $0 }.map(String.init).joined(separator: "\t")
                let line = String(format: "%.2f\t%lld\t%lld\t%lld\t", monotonicSeconds() - t0, s.footprint >> 20,
                                  s.resident >> 20, peak >> 20) + phases + "\n"
                marks.withLock { _ in handle.write(Data(line.utf8)) }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        thread.name = "holdmybyte memtrace"
        thread.qualityOfService = .utility
        thread.start()
    }
}
