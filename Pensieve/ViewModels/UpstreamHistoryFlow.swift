import Foundation

extension UpstreamHistoryViewModel {
    struct SkillFlow {
        var held: [ReadKey: HeldResult] = [:]
        var failures: [ReadKey: HeldFailure] = [:]
        var jobs: [UUID: Job] = [:]
        var requests: [UUID: RequestSession] = [:]
        var requestedChecks: Set<UpdateCheckKey> = []
        var cacheQuestion: CacheQuestion?
        var probeAnswer: (origin: OriginKey, outcome: Result<String, Error>)?
        var probeSpent = false
        var manualPending = false
        var manualCount: UInt64 = 0
    }

    @MainActor
    final class RequestSession {
        var current: CurrentRequest
        let sequenceLabel = UpstreamHistorySequenceContext.request
        let origin: InstalledOrigin
        let directory: String
        let intent: RequestIntent
        let onUpdateCheck: UpdateCheckRequest
        var continuation: CheckedContinuation<Void, Never>?
        var pending: Set<UUID> = []
        var decidedRead = false
        var readFinished = false
        // A re-ask that joined older work must still decide the pending manual read on completion.
        var joinedManualAsk = false

        init(current: CurrentRequest, origin: InstalledOrigin, directory: String,
             intent: RequestIntent, onUpdateCheck: @escaping UpdateCheckRequest) {
            self.current = current
            self.origin = origin
            self.directory = directory
            self.intent = intent
            self.onUpdateCheck = onUpdateCheck
        }
    }

    enum WorkPurpose {
        case disk
        case read(refresh: Bool, ordinal: UInt64)
        case probe
        case localEdits(ReadKey, HeldResult, allowsManual: Bool)
        case persist(advancedRequest: UUID?)
    }

    struct Job {
        let id: UUID
        let owner: RequestSession
        var purpose: WorkPurpose
        var waiters: Set<UUID>
    }

    enum Completion {
        case disk(UpstreamHistoryCache.Entry?)
        case read(Result<UpstreamHistoryResult, Error>)
        case probe(Result<String, Error>)
        case localEdits(UpstreamHistoryLocalEdits)
        case persist
    }

    enum FlowEvent {
        case request(RequestSession)
        case unavailable(String?)
        case completed(UUID, Completion)
        case manualCheck
        case remove(removeCache: Bool)
    }
}
