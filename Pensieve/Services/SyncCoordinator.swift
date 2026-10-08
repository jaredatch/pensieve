import Foundation
import SwiftData

enum SyncCycleResult: Equatable {
    case synced(pushed: Bool, warnings: [String], completedAt: Date, headAdvanced: Bool = false)
    case conflicted([String])
    case noRemote
    case branchless
    case locked
    case failed(String)
    case storeUnreadable(String)

    var provesGitUsable: Bool {
        switch self {
        // Credential resolution probes git before entering the engine, including its lock and store checks.
        case .synced, .conflicted, .noRemote, .branchless, .locked, .storeUnreadable: true
        case .failed: false
        }
    }

    var auditFields: (category: String, detail: String) {
        switch self {
        case let .synced(pushed, _, _, _):
            return ("synced", pushed ? "pushed" : "upToDate")
        case .conflicted:
            return ("skipped", "conflicted")
        case .noRemote:
            return ("skipped", "noRemote")
        case .branchless:
            return ("skipped", "branchless")
        case .locked:
            return ("skipped", "locked")
        case .failed:
            return ("failed", "syncError")
        case .storeUnreadable:
            return ("failed", "storeUnreadable")
        }
    }
}

/// Serial resident sync runs outside the cooperative pool. Each synchronous cycle owns a fresh
/// SwiftData context created and used entirely within its executor job.
actor SyncCoordinator {
    nonisolated private let executor = BlockingSerialExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }
    private var engine: SyncEngineProtocol = SyncEngine()
    private var git: GitServiceProtocol = GitService()
    private var credentials: CredentialStoreProtocol = KeychainCredentialStore()
    private var rebuildService: StoreRebuildServiceProtocol = StoreRebuildService()
    private var root = Constants.pensieveBaseDir
    private var audit: SyncAuditWriting = SyncAudit()
    private var machineIdentity: MachineIdentityProviding = MachineIdentity()
    private var machineStateService: MachineStateServicing = MachineStateService()
    private var now: () -> Date = Date.init
    private var headStamp: () -> String? = { GitHeadStamp().read(root: Constants.pensieveBaseDir) }
    private var lastIngestedHeadStamp: String?

    func configure(
        engine: SyncEngineProtocol = SyncEngine(),
        git: GitServiceProtocol = GitService(),
        credentials: CredentialStoreProtocol = KeychainCredentialStore(),
        rebuildService: StoreRebuildServiceProtocol = StoreRebuildService(),
        root: String = Constants.pensieveBaseDir,
        audit: SyncAuditWriting = SyncAudit(),
        machineIdentity: MachineIdentityProviding = MachineIdentity(),
        machineStateService: MachineStateServicing = MachineStateService(),
        now: @escaping () -> Date = Date.init,
        headStamp: (() -> String?)? = nil
    ) {
        self.engine = engine
        self.git = git
        self.credentials = credentials
        self.rebuildService = rebuildService
        self.root = root
        self.audit = audit
        self.machineIdentity = machineIdentity
        self.machineStateService = machineStateService
        self.now = now
        self.headStamp = headStamp ?? { GitHeadStamp().read(root: root) }
    }

    func seedLastIngestedHeadStamp(_ stamp: String?) {
        lastIngestedHeadStamp = stamp
    }

    func runCycle() -> SyncCycleResult {
        let result: SyncCycleResult
        do {
            // A fresh context prevents an earlier cycle's registered objects from hiding a newer UI save.
            let cycleContext = ModelContext(modelContainer)
            var preflightWarnings: [String] = [], preparedHeadStamp: String?, preflightAdvanced = false
            let outcome = try engine.sync(root: root, message: Self.commitMessage(at: now()),
                                          credential: resolveCredential(), context: cycleContext,
                                          prepare: { context in
                    let currentStamp = self.headStamp()
                    preparedHeadStamp = currentStamp
                    if self.lastIngestedHeadStamp == nil
                        || currentStamp == nil
                        || currentStamp != self.lastIngestedHeadStamp {
                        let rebuild = self.rebuildService.rebuild(fromRoot: self.root, context: context)
                        if rebuild.storeUnreadable {
                            throw SyncError.storeUnreadable(rebuild.warnings)
                        }
                        preflightWarnings = rebuild.warnings
                        preflightAdvanced = true
                        self.lastIngestedHeadStamp = currentStamp
                    }
                    // Machine state is observability: a publication failure must never block the pull
                    // that follows, or a persistent local fault would wedge sync on this machine for good.
                    do {
                        let machineID = try self.machineIdentity.identifier()
                        // Republish only on content change (ignoring the timestamp): an unchanged parsed
                        // on-disk state is the ONLY skip; absent/corrupt/unreadable all route to the write
                        // arm (self-heal). Skipping here is what keeps an idle cycle commit-free.
                        try self.machineStateService.publishIfChanged(
                            machineID: machineID,
                            context: context,
                            publishedAt: self.now(),
                            root: self.root
                        )
                    } catch {
                        preflightWarnings.append(
                            "Machine state not published: "
                                + ((error as? LocalizedError)?.errorDescription ?? "unknown error")
                        )
                    }
                }
            )
            result = cycleResult(from: outcome, preflightWarnings: preflightWarnings,
                                 preparedHeadStamp: preparedHeadStamp, preflightAdvanced: preflightAdvanced)
        } catch {
            result = Self.cycleFailure(error)
        }
        let fields = result.auditFields
        audit.record(category: fields.category, detail: fields.detail)
        return result
    }

    private func cycleResult(
        from outcome: SyncOutcome,
        preflightWarnings: [String],
        preparedHeadStamp: String?,
        preflightAdvanced: Bool
    ) -> SyncCycleResult {
        switch outcome {
        case let .synced(pushed, warnings, engineIngestedHeadStamp):
            let engineAdvanced = engineIngestedHeadStamp != nil
                && preparedHeadStamp != nil
                && engineIngestedHeadStamp != preparedHeadStamp
            if let ingestedHeadStamp = engineIngestedHeadStamp ?? preparedHeadStamp {
                lastIngestedHeadStamp = ingestedHeadStamp
            }
            return .synced(
                pushed: pushed,
                warnings: preflightWarnings + warnings,
                completedAt: now(),
                headAdvanced: preflightAdvanced || engineAdvanced
            )
        case let .conflicted(paths):
            return .conflicted(paths)
        case .noRemote:
            return .noRemote
        case .branchless:
            return .branchless
        }
    }

    func runCycle(completion: @escaping @MainActor (SyncCycleResult) -> Void) async {
        let result = runCycle()
        await completion(result)
    }

    /// The one place a thrown cycle becomes a result: a busy lock is `.locked`; the store refusing to be
    /// read (the pre-write read or a preflight rebuild) is the typed `.storeUnreadable`, carrying the
    /// same message `.failed` carried before PLAN-31; everything else is `.failed`.
    private static func cycleFailure(_ error: Error) -> SyncCycleResult {
        switch error {
        case SyncError.syncInProgress:
            return .locked
        case let SyncError.storeUnreadable(warnings):
            return .storeUnreadable(SyncError.storeUnreadable(warnings).errorDescription ?? "Sync failed.")
        case let error as LocalizedError:
            return .failed(error.errorDescription ?? "Sync failed.")
        default:
            return .failed("Sync failed.")
        }
    }

    private func resolveCredential() throws -> GitCredential? {
        try git.probeUsability().requireUsable()
        guard let remote = try git.remoteURL(at: root),
              let spec = RemoteURLPolicy.parse(remote) else { return nil }
        switch spec.transport {
        case .ssh:
            return .sshAgent
        case .https:
            return credentials.credential(forHost: spec.host)
        }
    }

    private static func commitMessage(at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "Sync Pensieve skills — " + formatter.string(from: date)
    }
}
