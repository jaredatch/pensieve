import Foundation

/// The async boundary for synchronous work that can run git or wait on a test service gate.
/// Cancellation reaches the worker task, but awaiting it always joins the operation and cleanup.
enum BlockingWork {
    private static let executor = BlockingTaskExecutor()

    static func task<Value>(priority: TaskPriority? = nil,
                            operation: @escaping @Sendable () -> Value) -> Task<Value, Never> {
        Task.detached(executorPreference: executor, priority: priority) { operation() }
    }

    static func task<Value>(priority: TaskPriority? = nil,
                            operation: @escaping @Sendable () throws -> Value) -> Task<Value, Error> {
        Task.detached(executorPreference: executor, priority: priority) { try operation() }
    }

    static func run<Value>(priority: TaskPriority? = nil,
                           operation: @escaping @Sendable () -> Value) async -> Value {
        let worker = task(priority: priority, operation: operation)
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    static func run<Value>(priority: TaskPriority? = nil,
                           operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = task(priority: priority, operation: operation)
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    fileprivate static func qos(_ priority: JobPriority) -> (thread: QualityOfService, dispatch: DispatchQoS) {
        switch priority.rawValue {
        case TaskPriority.high.rawValue...: (.userInitiated, .userInitiated)
        case TaskPriority.medium.rawValue...: (.default, .default)
        case TaskPriority.low.rawValue...: (.utility, .utility)
        default: (.background, .background)
        }
    }
}

/// A native thread for each runnable job avoids a worker cap or a shared serial queue delaying
/// independent calls. Running the Swift job retains task identity, including cancellation checks.
/// There is no mutable shared state; enqueue owns each job until its thread finishes it.
private final class BlockingTaskExecutor: TaskExecutor, @unchecked Sendable {
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let thread = Thread { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        thread.name = "Pensieve blocking work"
        thread.qualityOfService = BlockingWork.qos(job.priority).thread
        thread.start()
    }
}

/// Serial actor jobs run on an owned dispatch queue outside Swift's cooperative pool. Dispatch
/// serializes enqueue's only shared state. A synchronous cycle creates, uses and drops its context
/// within one job, without hopping executors while git or SwiftData holds mutable state.
/// Each work item's QoS follows the Swift job instead of imposing a utility queue on user work.
final class BlockingSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jaredatch.pensieve.sync-coordinator")

    func enqueue(_ job: consuming ExecutorJob) {
        let qos = BlockingWork.qos(job.priority).dispatch
        let job = UnownedJob(job)
        queue.async(qos: qos, flags: .enforceQoS) { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}
