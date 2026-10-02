import Foundation

extension UpstreamHistoryViewModel {
    struct HeldResult {
        let origin: OriginKey
        let recordedHeadAtRead: String?
        let readHead: String
        let result: UpstreamHistoryResult
        let localRevision: UpstreamHistoryLocalRevision
        var certifiedRecordedHeads: Set<String?> = []

        func replacing(
            result: UpstreamHistoryResult,
            localRevision: UpstreamHistoryLocalRevision
        ) -> HeldResult {
            HeldResult(
                origin: origin,
                recordedHeadAtRead: recordedHeadAtRead,
                readHead: readHead,
                result: result,
                localRevision: localRevision,
                certifiedRecordedHeads: certifiedRecordedHeads
            )
        }
    }

    struct HeldFailure {
        let message: String
        let localRevision: UpstreamHistoryLocalRevision

        func replacing(localRevision: UpstreamHistoryLocalRevision) -> HeldFailure {
            HeldFailure(message: message, localRevision: localRevision)
        }
    }

    func prepareRequest(_ session: RequestSession, flow: inout SkillFlow) {
        let current = session.current
        let key = current.key
        let recordedHead = key.recordedHead
        let windowCount = current.windowCount
        let previous = flow.cacheQuestion
        if previous?.origin != key.origin { pruneOtherOrigins(keeping: key.origin, flow: &flow) }
        let answered = answeringReadHead(for: key, flow: flow) != nil
        let compatible = flow.jobs.values.contains {
            if case .read(true, _) = $0.purpose {
                return $0.owner.current.key.origin == key.origin && $0.owner.current.windowCount == windowCount
            }
            return false
        }
        let superseding = previous.map {
            $0.origin != key.origin || ($0.recordedHead != recordedHead && !answered && !compatible)
        } ?? false
        let generation = cache?.beginRequest(skillID: key.skillID, superseding: superseding) ?? 0
        flow.cacheQuestion = CacheQuestion(origin: key.origin, recordedHead: recordedHead)
        session.current = CurrentRequest(id: current.id, key: key, localRevision: current.localRevision,
                                         windowCount: windowCount, cacheGeneration: generation)
    }

    private func pruneOtherOrigins(keeping origin: OriginKey, flow: inout SkillFlow) {
        flow.held = flow.held.filter { $0.value.origin == origin }
        flow.failures = flow.failures.filter { $0.key.request.origin == origin }
        flow.requestedChecks = flow.requestedChecks.filter { $0.origin == origin }
        if flow.probeAnswer?.origin != origin { flow.probeAnswer = nil }
        // Workers still finish, but their retired identities cannot refill the old origin's state.
        for job in flow.jobs.values where job.owner.current.key.origin != origin {
            sequenceHooks?.discarded(job.id)
            flow.jobs[job.id] = nil
            for waiter in job.waiters { flow.requests[waiter]?.pending.remove(job.id) }
        }
    }

    /// A held question certifies its read head for every window at that origin.
    /// Keep the provenance in held entries; consumers share this answer relation.
    func answeringReadHead(for request: RequestKey, flow: SkillFlow) -> String? {
        flow.held.values.first {
            $0.origin == request.origin
                && (request.recordedHead == $0.recordedHeadAtRead || request.recordedHead == $0.readHead
                    || $0.certifiedRecordedHeads.contains(request.recordedHead))
        }?.readHead
    }

    func heldEntry(_ request: RequestKey, flow: SkillFlow, minimumWindow: Int? = nil,
                   maximumWindow: Int? = nil) -> (key: ReadKey, value: HeldResult)? {
        flow.held.filter { _, value in
            value.origin == request.origin
                && minimumWindow.map { value.result.windowCount >= $0 } != false
                && maximumWindow.map { value.result.windowCount <= $0 } != false
        }.max { $0.value.result.windowCount < $1.value.result.windowCount }
    }

    func hold(_ incoming: HeldResult, for key: ReadKey, flow: inout SkillFlow) {
        var result = incoming
        // Transfer the answered questions before wider rows replace their certifying entry.
        // The original recorded head still describes this read for disk persistence.
        for existing in flow.held.values where existing.origin == result.origin {
            for head in existing.certifiedRecordedHeads.union([existing.recordedHeadAtRead]) {
                let question = RequestKey(skillID: key.request.skillID, origin: result.origin, recordedHead: head)
                if answeringReadHead(for: question, flow: flow) == result.readHead {
                    result.certifiedRecordedHeads.insert(head)
                }
            }
        }
        flow.held = flow.held.filter { _, existing in
            existing.origin != result.origin
                || (existing.readHead == result.readHead && existing.result.windowCount > result.result.windowCount)
        }
        flow.held[key] = result
    }
}
