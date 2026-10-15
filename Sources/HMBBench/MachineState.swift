import Darwin
import Foundation
import HMBEngine

/// The machine state recorded with every timing (§5.5 "Machine state"; LESSONSLEARNED §14).
public struct MachineState: Codable, Sendable, Hashable {
    public var capturedAt: Date
    /// `uptime` load averages (1, 5, 15 min).
    public var loadAverage: [Double]
    public var thermalState: String
    public var hardwareModel: String
    public var activeProcessors: Int
    public var physicalMemoryBytes: UInt64
    /// Free + inactive + purgeable pages.
    public var availableMemoryBytes: UInt64?
    public var lightroomRunning: Bool
    public var macOS: String

    public var load1: Double { loadAverage.first ?? 0 }

    public static func capture() -> MachineState {
        let info = ProcessInfo.processInfo
        return MachineState(capturedAt: Date(), loadAverage: loadAverage(), thermalState: thermal(info.thermalState),
                            hardwareModel: sysctlString("hw.model") ?? "unknown", activeProcessors: info.activeProcessorCount,
                            physicalMemoryBytes: info.physicalMemory, availableMemoryBytes: availableMemory(),
                            lightroomRunning: isRunning(nameContains: ["Lightroom"]), macOS: info.operatingSystemVersionString)
    }

    public static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads.map { ($0 * 100).rounded() / 100 } : []
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return cString(buffer)
    }

    static func cString(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func availableMemory() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * pageSize
    }

    /// Whether a process whose name contains one of `names` runs (libproc; no subprocess).
    static func isRunning(nameContains names: [String]) -> Bool {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return false }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var name = [CChar](repeating: 0, count: 1024)
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let text = cString(name)
            if names.contains(where: { text.contains($0) }) { return true }
        }
        return false
    }
}

/// CPU time and peak memory of this process (and of finished children, for the old engine).
public struct ResourceUsage: Sendable {
    public var userSeconds: Double
    public var systemSeconds: Double
    public var maxRSSBytes: Int64
    public var cpuSeconds: Double { userSeconds + systemSeconds }

    public static func current(children: Bool = false) -> ResourceUsage {
        var usage = rusage()
        getrusage(children ? RUSAGE_CHILDREN : RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        // macOS reports ru_maxrss in bytes.
        return ResourceUsage(userSeconds: seconds(usage.ru_utime), systemSeconds: seconds(usage.ru_stime), maxRSSBytes: Int64(usage.ru_maxrss))
    }
}

/// Where the numbers came from (§5.5 "Provenance").
public struct Provenance: Codable, Sendable, Hashable {
    public var gitCommit: String
    public var gitDirty: Bool?
    public var codecVersions: String
    public var executable: String

    public static func capture(repository: URL? = nil) -> Provenance {
        let directory = repository ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let commit = git(["rev-parse", "HEAD"], in: directory) ?? ProcessInfo.processInfo.environment["HMB_GIT_COMMIT"] ?? "unknown"
        let dirty = git(["status", "--porcelain", "--untracked-files=no"], in: directory).map { !$0.isEmpty }
        return Provenance(gitCommit: commit, gitDirty: dirty, codecVersions: EnginePrimitives.codecVersions,
                          executable: CommandLine.arguments.first ?? "hmb")
    }

    static func git(_ arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
