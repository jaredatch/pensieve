import Foundation

extension UpstreamHistoryViewModel {
    func useProbe(_ session: RequestSession, cached: HeldResult, flow: inout SkillFlow) {
        if let answer = flow.probeAnswer, answer.origin == session.current.key.origin {
            flow.probeAnswer = nil
            flow.probeSpent = true
            switch answer.outcome {
            case let .success(head):
                if head != cached.readHead { startRead(session, fallback: cached, flow: &flow) }
            case let .failure(error):
                let message = Self.refreshFailureMessage(error)
                let key = ReadKey(request: session.current.key, windowCount: session.current.windowCount)
                flow.failures[key] = HeldFailure(message: message, localRevision: session.current.localRevision)
                publish(.loadedWithFailure(cached.result, message), skillID: session.current.key.skillID)
            }
            return
        }
        guard let headOperation else { return }
        if let existing = flow.jobs.values.first(where: {
            if case .probe = $0.purpose { return $0.owner.current.key.origin == session.current.key.origin }
            return false
        }) {
            join(session, job: existing, flow: &flow)
            return
        }
        retireProbes(flow: &flow)
        let origin = session.origin
        start(.probe, purpose: .probe, session: session, flow: &flow) {
            .probe(Result { try headOperation(origin) })
        }
    }

    func retireProbes(flow: inout SkillFlow) {
        for job in flow.jobs.values {
            guard case .probe = job.purpose else { continue }
            sequenceHooks?.discarded(job.id)
            flow.jobs[job.id] = nil
            for id in job.waiters { flow.requests[id]?.pending.remove(job.id) }
        }
    }

    static func refreshFailureMessage(_ error: Error) -> String {
        "History couldn't be refreshed. \(readable(SkillInstallService.mappedRepositoryError(error)))"
    }
}
