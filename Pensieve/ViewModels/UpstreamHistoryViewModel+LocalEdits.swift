import Foundation

extension UpstreamHistoryViewModel {
    func startDisk(_ session: RequestSession, flow: inout SkillFlow) {
        guard let cache else { advance(session, flow: &flow); return }
        let current = session.current
        let origin = session.origin
        let directory = session.directory
        let localEdits = localEditsOperation
        start(.disk, purpose: .disk, session: session, flow: &flow) {
            guard let entry = cache.load(skillID: current.key.skillID, origin: origin,
                                         minimumWindow: current.windowCount, generation: current.cacheGeneration) else {
                return .disk(nil)
            }
            let edits = (try? localEdits(directory, origin.contentHash, entry.result.installedBaseline)) ?? .countsUnknown
            return .disk(UpstreamHistoryCache.Entry(origin: entry.origin, recordedHeadAtRead: entry.recordedHeadAtRead,
                                                    readHead: entry.readHead, result: entry.result.replacing(localEdits: edits)))
        }
    }

    func startLocalEdits(_ session: RequestSession, entry: (key: ReadKey, value: HeldResult),
                         flow: inout SkillFlow, allowsManual: Bool) {
        if let existing = flow.jobs.values.first(where: {
            if case let .localEdits(_, cached, _) = $0.purpose {
                return cached.readHead == entry.value.readHead
                    && $0.owner.current.localRevision == session.current.localRevision
            }
            return false
        }) {
            if allowsManual, case let .localEdits(key, cached, _) = existing.purpose {
                flow.jobs[existing.id]?.purpose = .localEdits(key, cached, allowsManual: true)
            }
            join(session, job: existing, flow: &flow)
            return
        }
        let measure = localEditsOperation
        let directory = session.directory
        let hash = session.origin.contentHash
        let baseline = entry.value.result.installedBaseline
        let purpose = WorkPurpose.localEdits(entry.key, entry.value, allowsManual: allowsManual)
        start(.localEdits, purpose: purpose, session: session, flow: &flow) {
            .localEdits((try? measure(directory, hash, baseline)) ?? .countsUnknown)
        }
    }

    static func readable(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return error.localizedDescription
    }
}

extension UpstreamHistoryResult {
    func replacing(localEdits: UpstreamHistoryLocalEdits) -> UpstreamHistoryResult {
        UpstreamHistoryResult(headCommit: headCommit, rows: rows, installedPosition: installedPosition,
                              hasOlderHistory: hasOlderHistory, installedBaseline: installedBaseline,
                              localEdits: localEdits, windowCount: windowCount)
    }
}
