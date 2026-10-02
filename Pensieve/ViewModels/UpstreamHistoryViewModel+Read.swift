import Foundation

extension UpstreamHistoryViewModel {
    func startRead(_ session: RequestSession, fallback: HeldResult?, flow: inout SkillFlow) {
        publish(fallback.map { .refreshing($0.result) } ?? .loading, skillID: session.current.key.skillID)
        flow.probeSpent = true
        flow.probeAnswer = nil
        retireProbes(flow: &flow)
        if joinRead(session, exactOnly: false, flow: &flow) { return }
        flow.manualPending = false
        session.joinedManualAsk = false
        session.decidedRead = true
        nextReadOrdinal &+= 1
        let read = readOperation
        let origin = session.origin
        let directory = session.directory
        let window = session.current.windowCount
        start(.read, purpose: .read(refresh: fallback != nil, ordinal: nextReadOrdinal), session: session, flow: &flow) {
            .read(Result { try read(origin, directory, window) })
        }
    }

    func completeRead(_ outcome: Result<UpstreamHistoryResult, Error>, job: Job,
                      active: RequestSession?, flow: inout SkillFlow) {
        for id in job.waiters { flow.requests[id]?.readFinished = true }
        let request = job.owner.current
        let key = ReadKey(request: request.key, windowCount: request.windowCount)
        switch outcome {
        case let .success(result):
            let cached = HeldResult(origin: request.key.origin, recordedHeadAtRead: request.key.recordedHead,
                                    readHead: result.headCommit, result: result, localRevision: request.localRevision)
            hold(cached, for: key, flow: &flow)
            flow.probeSpent = true
            flow.probeAnswer = nil
            retireProbes(flow: &flow)
            flow.failures = flow.failures.filter {
                $0.key.request.origin != request.key.origin || $0.key.windowCount > result.windowCount
            }
            let advanceNow = active.map {
                cache == nil || answeringReadHead(for: $0.current.key, flow: flow) == cached.readHead
            } ?? false
            startPersist(cached, job: job, advancedRequest: advanceNow ? active?.current.id : nil, flow: &flow)
            if let active, advanceNow {
                advance(active, flow: &flow, allowsManual: false)
            }
        case let .failure(error):
            let fallback = heldEntry(request.key, flow: flow, maximumWindow: request.windowCount)
            let message = fallback == nil ? Self.readable(SkillInstallService.mappedRepositoryError(error))
                : Self.refreshFailureMessage(error)
            let failure = HeldFailure(message: message, localRevision: request.localRevision)
            flow.failures[key] = failure
            if let active {
                let activeKey = ReadKey(request: active.current.key, windowCount: active.current.windowCount)
                flow.failures[activeKey] = failure
                advance(active, flow: &flow, allowsManual: false)
            }
        }
    }

    func startPersist(_ cached: HeldResult, job: Job, advancedRequest: UUID?, flow: inout SkillFlow) {
        guard let cache, case let .read(_, ordinal) = job.purpose else { return }
        let request = job.owner.current
        let origin = job.owner.origin
        // Persistence belongs to the whole read outcome. An already-returned kept-row join
        // must not take the starter's wait, but remains eligible for the completion decision.
        start(.persist, purpose: .persist(advancedRequest: advancedRequest), session: job.owner,
              waiters: job.waiters, flow: &flow) {
            cache.store(skillID: request.key.skillID, origin: origin, recordedHeadAtRead: request.key.recordedHead,
                        result: cached.result, generation: request.cacheGeneration, ordinal: ordinal)
            return .persist
        }
    }

    func start(_ kind: UpstreamHistorySequenceHooks.Work, purpose: WorkPurpose,
               session: RequestSession, waiters: Set<UUID>? = nil, flow: inout SkillFlow,
               operation: @escaping @Sendable () -> Completion) {
        let id = UUID()
        let waiters = waiters ?? [session.current.id]
        flow.jobs[id] = Job(id: id, owner: session, purpose: purpose, waiters: waiters)
        for waiter in waiters { flow.requests[waiter]?.pending.insert(id) }
        sequenceHooks?.workerStarted(id)
        let priority: TaskPriority = kind == .persist || kind == .localEdits ? .utility : .userInitiated
        let task = sequenceTask(kind, id: id, priority: priority, operation: operation)
        Task {
            await UpstreamHistorySequenceContext.$request.withValue("") {
                let result = await sequenceValue(task, id: id)
                receive(.completed(id, result), skillID: session.current.key.skillID)
                sequenceHooks?.workEnded(id)
            }
        }
    }
}
