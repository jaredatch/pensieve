import Foundation

extension UpstreamHistoryViewModel {
    /// This is the only event entry and request-currency decision. Effects never suspend this
    /// transaction: owned workers return tagged completions, and joins only register waiter IDs.
    func receive(_ event: FlowEvent, skillID: UUID) {
        eventQueue.append((skillID, event))
        guard !isReducing else { return }
        isReducing = true
        defer { isReducing = false }
        while !eventQueue.isEmpty {
            let (skillID, event) = eventQueue.removeFirst()
            reduce(event, skillID: skillID)
        }
    }

    private func reduce(_ event: FlowEvent, skillID: UUID) {
        if case let .remove(removeCache) = event {
            removeFlow(skillID: skillID, removeCache: removeCache)
            return
        }
        if case let .unavailable(message) = event {
            showUnavailable(message, skillID: skillID)
            return
        }
        if flows[skillID] == nil {
            switch event {
            case .completed: return
            default: break
            }
        }
        var flow = flows.removeValue(forKey: skillID) ?? SkillFlow()
        let eligible = register(event, skillID: skillID, flow: &flow)
        let active = currentQuestion(matching: eligible).flatMap { flow.requests[$0.id] }
        apply(event, active: active, skillID: skillID, flow: &flow)
        for session in flow.requests.values where session.pending.isEmpty { finish(session) }
        flow.requests = flow.requests.filter { $0.value.continuation != nil || !$0.value.pending.isEmpty }
        flows[skillID] = flow
        if case .manualCheck = event { manualCheckRevision &+= 1 }
    }

    private func register(_ event: FlowEvent, skillID: UUID, flow: inout SkillFlow) -> Set<UUID> {
        switch event {
        case let .request(session):
            prepareRequest(session, flow: &flow)
            currentSkillID = skillID
            currentRequest = session.current
            flow.requests[session.current.id] = session
            return [session.current.id]
        case let .completed(id, _): return flow.jobs[id]?.waiters ?? []
        case .manualCheck, .remove, .unavailable: return []
        }
    }

    private func apply(_ event: FlowEvent, active: RequestSession?, skillID: UUID, flow: inout SkillFlow) {
        switch event {
        case let .request(session): begin(session, flow: &flow)
        case let .completed(id, outcome):
            if let job = flow.jobs.removeValue(forKey: id) {
                sequenceHooks?.applied(id)
                for waiter in job.waiters { flow.requests[waiter]?.pending.remove(id) }
                complete(outcome, job: job, active: active, flow: &flow)
            }
        case .manualCheck:
            recordManualCheck(flow: &flow)
        case .remove, .unavailable: break
        }
    }

    private func recordManualCheck(flow: inout SkillFlow) {
        flow.manualPending = true
        flow.manualCount &+= 1
        if flow.jobs.values.contains(where: { if case .read(false, _) = $0.purpose { return true }; return false }) {
            discardReads(flow: &flow)
        }
    }

    private func showUnavailable(_ message: String?, skillID: UUID) {
        guard let message else { showNoQuestion(); return }
        currentSkillID = skillID
        currentRequest = nil
        publish(.failed(message), skillID: skillID)
    }

    private func removeFlow(skillID: UUID, removeCache: Bool) {
        let removed = flows.removeValue(forKey: skillID)
        if let removed, removed.manualCount > 0 { manualCheckRevision &+= 1 }
        removed?.requests.values.forEach { finish($0) }
        removed?.jobs.keys.forEach { sequenceHooks?.discarded($0) }
        if removeCache { cache?.remove(skillID: skillID) }
        if currentSkillID == skillID { showNoQuestion() }
    }

    func currentQuestion(matching request: CurrentRequest) -> CurrentRequest? {
        currentQuestion(matching: [request.id])
    }

    func currentQuestion(matching identities: Set<UUID>) -> CurrentRequest? {
        guard let currentRequest, identities.contains(currentRequest.id) else { return nil }
        return currentRequest
    }

    func finish(_ session: RequestSession) {
        guard let continuation = session.continuation else { return }
        session.continuation = nil
        sequenceHooks?.requestFinished(session.sequenceLabel)
        continuation.resume()
    }

    func discardReads(flow: inout SkillFlow) {
        let removed = flow.jobs.values.filter {
            switch $0.purpose {
            case .read, .localEdits: return true
            default: return false
            }
        }
        for job in removed {
            sequenceHooks?.discarded(job.id)
            flow.jobs[job.id] = nil
            for waiter in job.waiters { flow.requests[waiter]?.pending.remove(job.id) }
        }
    }

    func complete(_ outcome: Completion, job: Job, active: RequestSession?, flow: inout SkillFlow) {
        switch outcome {
        case let .disk(entry):
            guard let active else { return }
            let held = heldEntry(active.current.key, flow: flow)?.value
            if let entry, held.map({ $0.result.windowCount < active.current.windowCount
                && $0.readHead == entry.readHead }) ?? true {
                let value = HeldResult(origin: active.current.key.origin,
                                       recordedHeadAtRead: entry.recordedHeadAtRead, readHead: entry.readHead,
                                       result: entry.result, localRevision: job.owner.current.localRevision)
                hold(value, for: ReadKey(request: active.current.key, windowCount: entry.result.windowCount), flow: &flow)
            }
            advance(active, flow: &flow)
        case let .read(result): completeRead(result, job: job, active: active, flow: &flow)
        case let .probe(result):
            flow.probeAnswer = (job.owner.current.key.origin, result)
            if let active, let cached = heldEntry(active.current.key, flow: flow)?.value {
                useProbe(active, cached: cached, flow: &flow)
            }
        case let .localEdits(edits):
            completeLocalEdits(edits, job: job, active: active, flow: &flow)
        case .persist:
            // Read completion owns this decision. Held rows may change while persistence waits.
            guard let active, case let .persist(advancedRequest) = job.purpose,
                  advancedRequest != active.current.id else { return }
            advance(active, flow: &flow, allowsManual: false)
        }
    }

    private func completeLocalEdits(_ edits: UpstreamHistoryLocalEdits, job: Job,
                                    active: RequestSession?, flow: inout SkillFlow) {
        guard case let .localEdits(_, cached, allowsManual) = job.purpose, let active else { return }
        for (key, latest) in flow.held where latest.origin == cached.origin && latest.readHead == cached.readHead {
            flow.held[key] = latest.replacing(result: latest.result.replacing(localEdits: edits),
                                              localRevision: active.current.localRevision)
        }
        advance(active, flow: &flow, allowsManual: allowsManual)
    }

    func publish(_ value: UpstreamHistoryLoadState, skillID: UUID?) {
        sequenceHooks?.published(value, skillID)
        guard state != value else { return }
        state = value
    }

    func showNoQuestion() {
        currentSkillID = nil
        currentRequest = nil
        publish(.idle, skillID: nil)
    }
}
