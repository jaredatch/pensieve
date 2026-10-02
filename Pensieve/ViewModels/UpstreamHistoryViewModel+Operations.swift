import Foundation

extension UpstreamHistoryViewModel {
    func begin(_ session: RequestSession, flow: inout SkillFlow) {
        let current = session.current
        let key = ReadKey(request: current.key, windowCount: current.windowCount)
        let fallback = heldEntry(current.key, flow: flow, maximumWindow: current.windowCount)
        if flow.failures[key] != nil {
            let mayRetry = session.intent == .retry || flow.manualPending
                || (session.intent == .appearance && fallback == nil)
            if mayRetry { flow.failures[key] = nil }
        }
        _ = joinRead(session, exactOnly: true, flow: &flow)
        if heldEntry(current.key, flow: flow, minimumWindow: current.windowCount) != nil || flow.failures[key] != nil {
            advance(session, flow: &flow)
        } else {
            publish(fallback.map { .refreshing($0.value.result) } ?? .loading, skillID: current.key.skillID)
            startDisk(session, flow: &flow)
        }
    }

    func advance(_ session: RequestSession, flow: inout SkillFlow, allowsManual: Bool = true) {
        let current = session.current
        let key = ReadKey(request: current.key, windowCount: current.windowCount)
        let manual = flow.manualPending && (allowsManual || session.joinedManualAsk)
        if manual { flow.failures[key] = nil }
        let failure = flow.failures[key]
        let entry = heldEntry(current.key, flow: flow, minimumWindow: current.windowCount)
            ?? heldEntry(current.key, flow: flow, maximumWindow: current.windowCount)
        let running = flow.jobs.values.contains {
            if case .read = $0.purpose { return $0.waiters.contains(current.id) }; return false
        }
        if let cached = entry?.value {
            if expandWindow(session, cached: cached, hasFailure: failure != nil, flow: &flow) { return }
            let requiresRead = failure == nil && (answeringReadHead(for: current.key, flow: flow) != cached.readHead
                || manual || (session.intent == .retry && !session.decidedRead))
            if !running, requiresRead, cached.localRevision == current.localRevision {
                startRead(session, fallback: cached, flow: &flow)
                return
            }
            let visible: UpstreamHistoryLoadState = running || requiresRead ? .refreshing(cached.result)
                : failure.map { .loadedWithFailure(cached.result, $0.message) } ?? .loaded(cached.result)
            publish(visible, skillID: current.key.skillID)
            requestUpdateCheck(cached, session: session, flow: &flow)
            if cached.localRevision != current.localRevision, let entry {
                startLocalEdits(session, entry: entry, flow: &flow, allowsManual: allowsManual)
                return
            }
            if running {
                returnKeptJoin(session, flow: flow)
                return
            }
            if failure == nil && !flow.probeSpent { useProbe(session, cached: cached, flow: &flow) }
        } else if let failure {
            publish(.failed(failure.message), skillID: current.key.skillID)
        } else if !running && !session.readFinished {
            startRead(session, fallback: nil, flow: &flow)
        }
    }

    private func expandWindow(_ session: RequestSession, cached: HeldResult,
                              hasFailure: Bool, flow: inout SkillFlow) -> Bool {
        guard cached.result.windowCount < session.current.windowCount, !hasFailure else { return false }
        startRead(session, fallback: cached, flow: &flow)
        return true
    }

    private func returnKeptJoin(_ session: RequestSession, flow: SkillFlow) {
        let current = session.current
        let joinedExact = flow.jobs.values.contains {
            guard case .read = $0.purpose else { return false }
            return $0.waiters.contains(current.id) && $0.owner.current.id != current.id
                && $0.owner.current.key == current.key
        }
        if joinedExact { finish(session) }
    }

    func joinRead(_ session: RequestSession, exactOnly: Bool, flow: inout SkillFlow) -> Bool {
        let current = session.current
        guard let job = flow.jobs.values.first(where: { job in
            guard case let .read(refresh, _) = job.purpose else { return false }
            let other = job.owner.current
            return other.windowCount == current.windowCount
                && (other.key == current.key || (!exactOnly && refresh && other.key.origin == current.key.origin))
        }) else { return false }
        join(session, job: job, flow: &flow)
        session.decidedRead = true
        session.joinedManualAsk = session.joinedManualAsk || flow.manualPending
        return true
    }

    func join(_ session: RequestSession, job: Job, flow: inout SkillFlow) {
        flow.jobs[job.id]?.waiters.insert(session.current.id)
        session.pending.insert(job.id)
    }

    func requestUpdateCheck(_ cached: HeldResult, session: RequestSession, flow: inout SkillFlow) {
        let key = session.current.key
        guard answeringReadHead(for: key, flow: flow) == cached.readHead, cached.readHead != key.recordedHead else { return }
        let check = UpdateCheckKey(skillID: key.skillID, origin: cached.origin, head: cached.readHead)
        if flow.requestedChecks.insert(check).inserted { session.onUpdateCheck(key.skillID) }
    }
}
