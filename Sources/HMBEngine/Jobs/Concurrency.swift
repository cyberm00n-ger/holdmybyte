// Small concurrency building blocks for the job engine (§3.9): a lock box, the cooperative cancellation token
// and the worker pool of dedicated threads. Workers never run on the Swift cooperative pool.
import Foundation
import HMBModel
import Synchronization

/// A value behind a lock. Used for state shared between worker threads and the coordinator.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
    var snapshot: Value { withLock { $0 } }
}

/// Why a running job is being wound down.
enum StopRequest: Sendable, Equatable {
    case pause(PauseReason)
    case stop
}

/// Thrown by `CancelToken.check()`; unwinds the in-flight probe or write.
struct JobCancelled: Error, Sendable { let request: StopRequest }

/// Cooperative cancellation, checked before every probe and every write (§3.8). The first request wins.
final class CancelToken: Sendable {
    private let state = Mutex<StopRequest?>(nil)
    init() {}

    /// Returns true if this request is the one that took effect.
    @discardableResult
    func request(_ request: StopRequest) -> Bool {
        state.withLock { current in
            guard current == nil else { return false }
            current = request
            return true
        }
    }
    var current: StopRequest? { state.withLock { $0 } }
    var isCancelled: Bool { current != nil }
    func check() throws {
        if let request = current { throw JobCancelled(request: request) }
    }
}

/// N dedicated `Thread`s (8 MB stacks) pulling item indices from locked FIFOs (§3.9).
///
/// Items come in kinds (one FIFO each). A worker takes the head of the first kind, in `kinds` order, that `admit`
/// lets start given how many items of each kind are running and queued; when items are left but none may start,
/// it waits until a running item ends (or the job is cancelled). With a single kind and no `admit` this is the plain
/// FIFO pool of §3.9. The job runner uses two kinds to cap concurrent archive transcodes without idling workers
/// (D-ENG-10): a worker that may not start an archive takes the next photo's lossy work instead.
final class WorkerPool: @unchecked Sendable {
    /// What `admit` sees: running and queued items per kind.
    struct Load: Sendable {
        var running: [Int]
        var queued: [Int]
    }

    private let condition = NSCondition()
    private var queues: [[Int]]                         // reversed: popLast() serves the FIFO head
    private var running: [Int]
    private let group = DispatchGroup()
    private let count: Int
    private let qos: QualityOfService
    private let name: String
    private let work: @Sendable (_ item: Int, _ kind: Int, _ worker: Int) -> Void
    private let admit: @Sendable (_ kind: Int, _ load: Load) -> Bool
    private let shouldContinue: @Sendable () -> Bool

    init(kinds: [[Int]], count: Int, qos: QualityOfService, name: String,
         admit: @escaping @Sendable (_ kind: Int, _ load: Load) -> Bool = { _, _ in true },
         shouldContinue: @escaping @Sendable () -> Bool,
         work: @escaping @Sendable (_ item: Int, _ kind: Int, _ worker: Int) -> Void) {
        self.queues = kinds.map { Array($0.reversed()) }
        self.running = Array(repeating: 0, count: kinds.count)
        self.count = max(1, count)
        self.qos = qos
        self.name = name
        self.work = work
        self.admit = admit
        self.shouldContinue = shouldContinue
    }

    convenience init(items: [Int], count: Int, qos: QualityOfService, name: String,
                     shouldContinue: @escaping @Sendable () -> Bool,
                     work: @escaping @Sendable (_ item: Int, _ worker: Int) -> Void) {
        self.init(kinds: [items], count: count, qos: qos, name: name, shouldContinue: shouldContinue) { item, _, worker in
            work(item, worker)
        }
    }

    /// The next item to run and its kind, or nil when nothing is left or the job is cancelled.
    private func take() -> (item: Int, kind: Int)? {
        condition.lock()
        defer { condition.unlock() }
        while shouldContinue() {
            if queues.allSatisfy(\.isEmpty) { return nil }
            let load = Load(running: running, queued: queues.map(\.count))
            for kind in queues.indices where !queues[kind].isEmpty && admit(kind, load) {
                running[kind] += 1
                return (queues[kind].removeLast(), kind)
            }
            // Something is queued but nothing may start: wait for a running item to end (poll the token meanwhile).
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        return nil
    }

    private func finished(_ kind: Int) {
        condition.lock()
        running[kind] -= 1
        condition.broadcast()
        condition.unlock()
    }

    func start() {
        for index in 0..<count {
            group.enter()
            let thread = Thread { [self] in
                defer { group.leave() }
                while let (item, kind) = take() {
                    work(item, kind, index)
                    finished(kind)
                }
            }
            thread.stackSize = 8 << 20
            thread.qualityOfService = qos
            thread.name = "\(name) \(index + 1)"
            thread.start()
        }
    }

    /// Waits up to `timeout` seconds; true when every worker has exited.
    func wait(timeout: Double) -> Bool { group.wait(timeout: .now() + timeout) == .success }

    /// Items not yet taken by a worker.
    var remaining: Int {
        condition.lock()
        defer { condition.unlock() }
        return queues.reduce(0) { $0 + $1.count }
    }

    /// Worker count for a processor-use setting (§3.9).
    static func workerCount(_ use: ProcessorUse, processors: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        switch use {
        case .automatic: min(8, max(2, processors - 2))
        case .gentle: 2
        }
    }

    static func qos(_ use: ProcessorUse) -> QualityOfService {
        use == .gentle ? .utility : .userInitiated
    }
}

/// Runs `body` on a dedicated thread and returns its result asynchronously (keeps blocking work off the
/// cooperative pool).
func onDedicatedThread<T: Sendable>(name: String, qos: QualityOfService = .userInitiated,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        let thread = Thread {
            do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
        }
        thread.stackSize = 8 << 20
        thread.qualityOfService = qos
        thread.name = name
        thread.start()
    }
}

/// Monotonic seconds.
@inline(__always) func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}
