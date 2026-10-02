import XCTest

@MainActor
extension UpstreamHistorySequenceHarness {
    var settled: Bool {
        frontierChecks += 1
        guard acknowledgements == 0 else { return false }
        guard work.values.allSatisfy({ [.entering, .finishing, .finished].contains($0.phase) }) else { return false }
        return lanes.allSatisfy { label, lane in
            switch lane {
            case .running: return false
            case let .waiting(id): return work[id]?.phase != .finished
            case .dormant: return gates["\(label).request"] != nil
            case .parked, .done: return true
            }
        }
    }

    var enabled: [String] {
        gates.keys.filter { event in
            guard event.hasSuffix(".request") else { return true }
            let label = String(event.dropLast(".request".count))
            guard let dependency = dependencies[label] else { return true }
            guard let lane = lanes[dependency] else { return false }
            return lane != .dormant
        }.sorted()
    }

    var finished: Bool { lanes.values.allSatisfy { $0 == .done } && gates.isEmpty && workers.isEmpty }

    func settle() async throws {
        if let failure { throw failure }
        frontierWaits += 1
        let outcome = await frontier.wait(timeout: frontierTimeout) { self.failure != nil || self.settled }
        switch outcome {
        case .satisfied: break
        case .timedOut:
            recordTimeout("frontier")
            stop("Timed out waiting for frontier")
        case .cancelled: stop("Cancelled waiting for frontier")
        }
        if let failure { throw failure }
    }

    func release(_ event: String) async throws {
        try await settle()
        guard enabled.contains(event), let continuation = gates.removeValue(forKey: event) else {
            stop("Disabled event: \(event); enabled: \(enabled)")
            throw failure ?? HistorySequenceFailure("Disabled event: \(event)")
        }
        scheduled.append(event)
        acknowledgements += 1
        if event.hasSuffix(".request") || event.hasSuffix(".resume") {
            let label = String(event.prefix(while: { $0 != "." }))
            lanes[label] = .running
        } else if let id = work.first(where: { event.hasPrefix($0.value.name + ".") })?.key {
            work[id]?.phase = event.hasSuffix(".start") ? .running : .finished
        }
        continuation.resume()
        try await settle()
    }

    func run(_ events: [String]) async throws {
        for event in events { try await release(event) }
    }

    func drain() async throws {
        for _ in 0..<80 {
            try await settle()
            if finished { return }
            guard let next = enabled.first else {
                stop("Deadlocked sequence")
                throw failure ?? HistorySequenceFailure("Deadlocked sequence")
            }
            try await release(next)
        }
        stop("Sequence exceeded its finite two-request bound")
        throw failure ?? HistorySequenceFailure("Unbounded sequence")
    }
}
