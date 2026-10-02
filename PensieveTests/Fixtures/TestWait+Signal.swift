import Foundation

extension TestWait {
    enum SignalOutcome { case satisfied, timedOut, cancelled }

    private struct SignalWaiter {
        let condition: @MainActor () -> Bool
        let continuation: CheckedContinuation<SignalOutcome, Never>
        let deadline: Task<Void, Never>
    }

    /// Notifications are hints: check after registration and again when the caller resumes.
    /// All state and conditions are main-actor isolated. Re-waits share the original deadline.
    @MainActor
    final class Signal {
        private var waiters: [UUID: SignalWaiter] = [:]

        func wait(timeout: Duration, condition: @escaping @MainActor () -> Bool) async -> SignalOutcome {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !condition() {
                if Task.isCancelled { return .cancelled }
                guard clock.now < deadline else {
                    recordTimeout()
                    return .timedOut
                }
                let notified = await suspend(timeout: clock.now.duration(to: deadline), condition: condition)
                if notified != .satisfied { return notified }
            }
            return .satisfied
        }

        private func suspend(timeout: Duration, condition: @escaping @MainActor () -> Bool) async -> SignalOutcome {
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let deadline = Task {
                        do { try await Task.sleep(for: timeout) } catch { return }
                        complete(id, outcome: .timedOut)
                    }
                    waiters[id] = SignalWaiter(condition: condition, continuation: continuation, deadline: deadline)
                    if condition() { complete(id, outcome: .satisfied) }
                    if Task.isCancelled { complete(id, outcome: .cancelled) }
                }
            } onCancel: {
                Task { @MainActor in self.complete(id, outcome: .cancelled) }
            }
        }

        func notify() {
            let ready = waiters.filter { $0.value.condition() }.map(\.key)
            for id in ready { complete(id, outcome: .satisfied) }
        }

        private func recordTimeout() {
            let pending = waiters.map { "\($0.key): deadlineCancelled=\($0.value.deadline.isCancelled)" }.sorted()
            TestTimeoutDiagnostics.note("TestWait.Signal: condition=false; pending continuations=\(pending)")
        }

        private func complete(_ id: UUID, outcome: SignalOutcome) {
            if outcome == .timedOut, waiters[id] != nil { recordTimeout() }
            guard let waiter = waiters.removeValue(forKey: id) else { return }
            waiter.deadline.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }
}
