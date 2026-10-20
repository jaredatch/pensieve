import Foundation
import SwiftData

enum SyncCycleResult: Equatable {
    case synced(pushed: Bool, warnings: [String], completedAt: Date, headAdvanced: Bool = false, pulled: Bool = false)
    case conflicted([String])
    case noRemote
    case branchless
    case locked
    case failed(String)
    case storeUnreadable(String)
    case manifestDamaged(String)

    var provesGitUsable: Bool {
        switch self {
        // Credential resolution probes git before entering the engine, including its lock and store checks.
        case .synced, .conflicted, .noRemote, .branchless, .locked, .storeUnreadable, .manifestDamaged: true
        case .failed: false
        }
    }

    var auditFields: (category: String, detail: String) {
        switch self {
        case let .synced(pushed, _, _, _, _):
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
        case .storeUnreadable, .manifestDamaged:
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
    private var engine: SyncEngineProtocol?
    private var git: GitServiceProtocol?
    private var credentials: CredentialStoreProtocol?
    private var rebuildService: StoreRebuildServiceProtocol = StoreRebuildService()
    private var root = ""
    private var audit: SyncAuditWriting?
    private var machineIdentity: MachineIdentityProviding?
    private var machineStateService: MachineStateServicing?
    private var now: () -> Date = Date.init
    private var headState: () -> GitHeadStamp.State = { .unreadable }

    func configure(
        engine: SyncEngineProtocol,
        git: GitServiceProtocol,
        credentials: CredentialStoreProtocol,
        rebuildService: StoreRebuildServiceProtocol = StoreRebuildService(),
        root: String,
        audit: SyncAuditWriting,
        machine: (identity: MachineIdentityProviding, stateService: MachineStateServicing),
        now: @escaping () -> Date = Date.init,
        headStamp: (() -> GitHeadStamp.State)? = nil
    ) {
        self.engine = engine
        self.git = git
        self.credentials = credentials
        self.rebuildService = rebuildService
        self.root = root
        self.audit = audit
        self.machineIdentity = machine.identity
        self.machineStateService = machine.stateService
        self.now = now
        self.headState = headStamp ?? { GitHeadStamp().state(root: root) }
    }

    func seedLastIngestedHeadStamp(_ stamp: String?) {
        StoreIngestState.shared(for: modelContainer).seedHead(stamp)
    }

    func runCycle() -> SyncCycleResult {
        guard let engine, let machineIdentity, let machineStateService, let audit else {
            return .failed("Sync coordinator has not been configured.")
        }
        let result: SyncCycleResult
        var cycleError: Error?
        var authentication = SyncAuthentication(remote: nil, credential: nil)
        do {
            // A fresh context prevents an earlier cycle's registered objects from hiding a newer UI save.
            let cycleContext = ModelContext(modelContainer)
            var preflightWarnings: [String] = [], preparedHeadStamp: String?, preflightAdvanced = false
            authentication = try resolveAuthentication()
            let outcome = try engine.sync(root: root, message: Self.commitMessage(at: now()),
                                          credential: authentication.credential, context: cycleContext,
                                          prepare: { context in
                    let currentStamp = self.headState()
                    preparedHeadStamp = currentStamp.oid
                    if let rebuild = try self.ingestIfNeeded(context: context, stamp: currentStamp) {
                        preflightWarnings = rebuild.warnings
                        preflightAdvanced = true
                    }
                    // Machine state is observability: a publication failure must never block the pull
                    // that follows, or a persistent local fault would wedge sync on this machine for good.
                    do {
                        let machineID = try machineIdentity.identifier()
                        // Republish only on content change (ignoring the timestamp): an unchanged parsed
                        // on-disk state is the ONLY skip; absent/corrupt/unreadable all route to the write
                        // arm (self-heal). Skipping here is what keeps an idle cycle commit-free.
                        try machineStateService.publishIfChanged(
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
            if let recovery = error as? ManifestRecoveryFailure {
                cycleError = recovery.underlying
                result = .manifestDamaged(recoveryMessage(recovery.underlying, authentication: authentication))
            } else {
                cycleError = error
                result = Self.cycleFailure(authentication.reporting(error))
            }
        }
        Self.recordAudit(for: result, error: cycleError, audit: audit)
        return result
    }

    private func recoveryMessage(_ error: Error, authentication: SyncAuthentication) -> String {
        let damage = ManifestError.damaged.localizedDescription
        guard let advice = authentication.reporting(error) as? SyncAuthentication.Failure else { return damage }
        return damage + ". " + advice.localizedDescription
    }

    private func ingestIfNeeded(context: ModelContext, stamp: GitHeadStamp.State) throws -> RebuildResult? {
        guard StoreIngestState.shared(for: modelContainer).requiresRebuild(at: stamp) else { return nil }
        return try StoreIngestState.rebuild(using: rebuildService, root: root, context: context,
                                           headStamp: { self.headState().oid })
    }

    /// Recovery keeps damage and app-authored credential advice in the UI; audit retains the underlying error.
    private static func recordAudit(for result: SyncCycleResult, error: Error?, audit: SyncAuditWriting) {
        let fields = result.auditFields
        if let error, case ManifestError.damaged = error {
            audit.record(category: fields.category, detail: fields.detail)
        } else if let error, case .manifestDamaged = result {
            audit.record(category: fields.category, detail: error.localizedDescription)
        } else if let error, case GitError.authenticationFailed = error {
            audit.record(category: fields.category, detail: error.localizedDescription)
        } else {
            audit.record(category: fields.category, detail: fields.detail)
        }
    }

    private func cycleResult(
        from outcome: SyncOutcome,
        preflightWarnings: [String],
        preparedHeadStamp: String?,
        preflightAdvanced: Bool
    ) -> SyncCycleResult {
        switch outcome {
        case let .synced(pushed, warnings, engineIngestedHeadStamp, pulled):
            let engineAdvanced = engineIngestedHeadStamp != nil
                && preparedHeadStamp != nil
                && engineIngestedHeadStamp != preparedHeadStamp
            return .synced(
                pushed: pushed,
                warnings: preflightWarnings + warnings,
                completedAt: now(),
                headAdvanced: preflightAdvanced || engineAdvanced,
                pulled: pulled
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

    /// Keep repairable damage distinct from the newer-schema fence when a cycle refuses the store.
    /// Busy locks remain retryable; other errors retain their localized failure.
    private static func cycleFailure(_ error: Error) -> SyncCycleResult {
        switch error {
        case SyncError.syncInProgress:
            return .locked
        case ManifestError.damaged:
            return .manifestDamaged(ManifestError.damaged.localizedDescription)
        case let SyncError.storeUnreadable(warnings):
            return .storeUnreadable(SyncError.storeUnreadable(warnings).errorDescription ?? "Sync failed.")
        case let error as LocalizedError:
            return .failed(error.errorDescription ?? "Sync failed.")
        default:
            return .failed("Sync failed.")
        }
    }

    private func resolveAuthentication() throws -> SyncAuthentication {
        guard let git, let credentials else { return SyncAuthentication(remote: nil, credential: nil) }
        try git.probeUsability().requireUsable()
        guard let remote = try git.remoteURL(at: root),
              let spec = RemoteURLPolicy.parse(remote) else { return SyncAuthentication(remote: nil, credential: nil) }
        return SyncAuthentication(remote: spec, credential: spec.transport == .ssh
            ? .sshAgent : credentials.credential(forHost: spec.host))
    }

    private static func commitMessage(at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "Sync Pensieve skills — " + formatter.string(from: date)
    }
}
