import Foundation

@MainActor
extension UpstreamHistorySequenceHarness {
    func recordTimeout(_ wait: String) {
        let pendingWork = work.map { id, item in
            "\(id): \(item.name) kind=\(item.kind) phase=\(item.phase) workerLive=\(workers.contains(id))"
        }.sorted()
        let pendingLanes = lanes.map { "\($0.key): \($0.value)" }.sorted()
        let pendingTasks = tasks.enumerated().map { "task[\($0.offset)]: cancelled=\($0.element.isCancelled)" }
        TestTimeoutDiagnostics.note("""
        History wait=\(wait); scenario=\(scenario); draining=\(draining)
        schedule=\(scheduled)
        observed=\(observed); acknowledgements=\(acknowledgements)
        pending gates/continuations=\(gates.keys.sorted())
        dependencies=\(dependencies.sorted { $0.key < $1.key })
        lanes (done means request completed)=\(pendingLanes)
        work=\(pendingWork)
        live workers=\(workers.map(\.uuidString).sorted())
        retained tasks=\(pendingTasks)
        failure=\(String(describing: failure))
        """, threadSample: timeoutThreadSample())
    }
}
