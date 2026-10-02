import Foundation
import Observation

struct UpstreamHistoryLocalRevision: Hashable {
    let appWriteRevision: Int
    let watcherEventSequence: UInt64

    static let initial = UpstreamHistoryLocalRevision(
        appWriteRevision: 0,
        watcherEventSequence: 0
    )
}

enum UpstreamHistoryLoadState: Equatable {
    case idle
    case loading
    case refreshing(UpstreamHistoryResult)
    case loaded(UpstreamHistoryResult)
    case loadedWithFailure(UpstreamHistoryResult, String)
    case failed(String)
}

/// Process-scoped owner for installed-skill history. Synchronous service work runs detached; only this
/// main-actor type publishes state. Successful reads live in memory until their question is invalidated.
@MainActor
@Observable
final class UpstreamHistoryViewModel {
    enum RequestIntent: Equatable {
        case appearance
        case retry
        case mountedRefresh
    }

    typealias ReadOperation = (InstalledOrigin, String, Int) throws -> UpstreamHistoryResult
    typealias HeadOperation = (InstalledOrigin) throws -> String
    typealias LocalEditsOperation = (
        String, String, UpstreamHistoryBaseline?
    ) throws -> UpstreamHistoryLocalEdits
    typealias LocalDirectoryResolver = (String) -> String?
    typealias UpdateCheckRequest = @MainActor (UUID) -> Void
    typealias RequestObserver = @MainActor (RequestIntent) -> Void

    var state = UpstreamHistoryLoadState.idle
    @ObservationIgnored var sequenceHooks: UpstreamHistorySequenceHooks?
    var currentSkillID: UUID?

    let readOperation: ReadOperation
    let headOperation: HeadOperation?
    let localEditsOperation: LocalEditsOperation
    let localDirectory: LocalDirectoryResolver
    @ObservationIgnored let cache: UpstreamHistoryCache?
    @ObservationIgnored let requestObserver: RequestObserver
    @ObservationIgnored var currentRequest: CurrentRequest?
    @ObservationIgnored var flows: [UUID: SkillFlow] = [:]
    // The view observes manual-check changes, not every job transition in the flow dictionary.
    var manualCheckRevision: UInt64 = 0
    @ObservationIgnored var nextReadOrdinal: UInt64 = 0
    @ObservationIgnored var eventQueue: [(UUID, FlowEvent)] = []
    @ObservationIgnored var isReducing = false

    init(
        readOperation: @escaping ReadOperation,
        headOperation: HeadOperation? = nil,
        localEditsOperation: @escaping LocalEditsOperation,
        localDirectory: @escaping LocalDirectoryResolver,
        cache: UpstreamHistoryCache? = nil,
        requestObserver: @escaping RequestObserver = { _ in }
    ) {
        self.readOperation = readOperation
        self.headOperation = headOperation
        self.localEditsOperation = localEditsOperation
        self.localDirectory = localDirectory
        self.cache = cache
        self.requestObserver = requestObserver
    }

    convenience init(
        service: UpstreamHistoryService,
        skillsRoot: String,
        fileService: FileServiceProtocol = FileService(),
        cacheDirectory: String? = nil
    ) {
        self.init(
            readOperation: { origin, directory, windowCount in
                try service.read(origin: origin, localDirectory: directory, windowCount: windowCount)
            },
            headOperation: { origin in try service.probeHead(origin: origin) },
            localEditsOperation: { directory, contentHash, baseline in
                try service.localEdits(
                    localDirectory: directory,
                    installedContentHash: contentHash,
                    baseline: baseline
                )
            },
            localDirectory: { slug in
                SkillStore.safeSkillDirectory(
                    slug: slug,
                    base: skillsRoot,
                    fileService: fileService
                )
            },
            cache: cacheDirectory.map {
                UpstreamHistoryCache(directory: $0, fileService: fileService)
            }
        )
    }

    func request(
        skill: Skill,
        windowCount: Int = 1,
        localRevision: UpstreamHistoryLocalRevision = .initial,
        intent: RequestIntent = .appearance,
        onUpdateCheck: @escaping UpdateCheckRequest = { _ in }
    ) async {
        sequenceHooks?.passed(.request, nil, UpstreamHistorySequenceContext.request)
        requestObserver(intent)
        guard skill.hasLinkedOrigin, let origin = skill.installedOrigin, origin != .empty else {
            receive(.remove(removeCache: true), skillID: skill.id)
            receive(.unavailable(nil), skillID: skill.id)
            return
        }
        guard let directory = localDirectory(skill.directoryName) else {
            receive(.unavailable("Couldn't read this skill's local files."), skillID: skill.id)
            return
        }
        let current = CurrentRequest(
            id: UUID(),
            key: RequestKey(skillID: skill.id, origin: OriginKey(origin: origin), recordedHead: skill.lastCheckedHead),
            localRevision: localRevision, windowCount: max(windowCount, 1), cacheGeneration: 0
        )
        let session = RequestSession(current: current, origin: origin, directory: directory,
                                     intent: intent, onUpdateCheck: onUpdateCheck)
        await withCheckedContinuation { continuation in
            session.continuation = continuation
            receive(.request(session), skillID: skill.id)
            if session.continuation != nil { sequenceHooks?.requestWaiting(current.id) }
        }
    }

    func invalidateForManualCheck(skillID: UUID) {
        acknowledgeAction()
        receive(.manualCheck, skillID: skillID)
    }

    private func acknowledgeAction() {
        let label = UpstreamHistorySequenceContext.request
        if !label.isEmpty { sequenceHooks?.passed(.request, nil, label) }
    }

    func manualCheckCount(skillID: UUID) -> UInt64 {
        _ = manualCheckRevision
        return flows[skillID]?.manualCount ?? 0
    }

    func remove(skillID: UUID) {
        acknowledgeAction()
        receive(.remove(removeCache: true), skillID: skillID)
    }

    func retain(skillIDs: Set<UUID>) {
        acknowledgeAction()
        let known = Set(flows.keys).union(currentSkillID.map { [$0] } ?? [])
        for skillID in known.subtracting(skillIDs) { receive(.remove(removeCache: false), skillID: skillID) }
        cache?.retain(skillIDs: skillIDs)
    }

}

extension UpstreamHistoryViewModel {
    struct OriginKey: Hashable {
        let repo: String
        let path: String
        let ref: String
        let installedCommit: String
        let installedTree: String
        let contentHash: String

        init(origin: InstalledOrigin) {
            repo = origin.repo
            path = origin.path
            ref = origin.ref
            installedCommit = origin.installedCommit
            installedTree = origin.installedTree
            contentHash = origin.contentHash
        }
    }

    struct RequestKey: Hashable {
        let skillID: UUID
        let origin: OriginKey
        let recordedHead: String?
    }

    struct ReadKey: Hashable {
        let request: RequestKey
        let windowCount: Int
    }

    struct CurrentRequest {
        let id: UUID
        let key: RequestKey
        let localRevision: UpstreamHistoryLocalRevision
        let windowCount: Int
        let cacheGeneration: UInt64

    }

    struct UpdateCheckKey: Hashable {
        let skillID: UUID
        let origin: OriginKey
        let head: String
    }

    struct CacheQuestion {
        let origin: OriginKey
        let recordedHead: String?
    }
}
