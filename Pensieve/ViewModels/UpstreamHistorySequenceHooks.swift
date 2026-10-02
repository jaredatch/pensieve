import Foundation

/// Internal, opt-in suspension seams. Nil in the app. Hooks observe and suspend work; they never
/// supply an answer or decide request currency. Detached service work keeps its existing boundary.
@MainActor
struct UpstreamHistorySequenceHooks {
    enum Work: String {
        case disk, read, probe, localEdits, persist
    }

    enum Point { case request, start, finish, resume }

    var started: @MainActor (Work, UUID) -> Void
    var enter: @MainActor (UUID) async -> Void
    var finish: @MainActor (UUID) async -> Void
    var waiting: @MainActor (UUID) -> Void
    var resume: @MainActor (UUID) async -> Void
    var published: @MainActor (UpstreamHistoryLoadState, UUID?) -> Void
    var passed: @MainActor (Point, UUID?, String) -> Void = { _, _, _ in }
    var workerStarted: @MainActor (UUID) -> Void = { _ in }
    var discarded: @MainActor (UUID) -> Void = { _ in }
    var requestFinished: @MainActor (String) -> Void = { _ in }
    var requestWaiting: @MainActor (UUID) -> Void = { _ in }
    var workEnded: @MainActor (UUID) -> Void = { _ in }
    var scheduled: @MainActor (Work, TaskPriority) -> Void = { _, _ in }
    var applied: @MainActor (UUID) -> Void = { _ in }
}

enum UpstreamHistorySequenceContext {
    @TaskLocal static var request = ""
}

extension UpstreamHistoryViewModel {
    func sequenceTask<Value>(
        _ work: UpstreamHistorySequenceHooks.Work,
        id: UUID,
        priority: TaskPriority,
        operation: @escaping @Sendable () -> Value
    ) -> Task<Value, Never> {
        sequenceHooks?.scheduled(work, priority)
        guard let hooks = sequenceHooks else {
            return Task.detached(priority: priority) { operation() }
        }
        hooks.started(work, id)
        return Task.detached(priority: priority) {
            await hooks.enter(id)
            await hooks.passed(.start, id, "")
            let value = operation()
            await hooks.finish(id)
            await hooks.passed(.finish, id, "")
            return value
        }
    }

    func sequenceValue<Value>(_ task: Task<Value, Never>, id: UUID) async -> Value {
        sequenceHooks?.waiting(id)
        let value = await task.value
        await sequenceHooks?.resume(id)
        sequenceHooks?.passed(.resume, id, UpstreamHistorySequenceContext.request)
        return value
    }
}
