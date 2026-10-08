import Foundation

/// The result of one daemon pull cycle (PLAN-12 / 12.6). SwiftData-free; `Equatable` so branch tests
/// assert it directly. `.synced(changed:)` — the store was already up-to-date (`changed:false`) or
/// fast-forwarded (`changed:true`); reconcile ran. `.skipped` — a safe no-op precondition; reconcile did
/// NOT run. `.failed` — a git/auth error mid-cycle.
enum DaemonCycleResult: Equatable {
    case synced(changed: Bool)
    case skipped(SkipReason)
    case failed(FailureReason)

    enum SkipReason: String, Equatable {
        case locked, noRemote, branchless, rejectedRemote, dirtyTree, diverged
    }
    enum FailureReason: Equatable {
        case authentication, gitError
        case preflight(String)

        var detail: String {
            switch self {
            case .authentication: return "authentication"
            case .gitError: return "gitError"
            case let .preflight(message): return message
            }
        }
    }

    /// Coarse category for the status/log line ("synced" / "skipped" / "failed").
    var category: String {
        switch self {
        case .synced: return "synced"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }
    /// Fine detail for the status/log line.
    var detail: String {
        switch self {
        case let .synced(changed): return changed ? "fastForwarded" : "upToDate"
        case let .skipped(reason): return reason.rawValue
        case let .failed(reason): return reason.detail
        }
    }
}

/// The reconcile surface `runOnce` invokes on a successful pull (PLAN-12 / 12.6). The concrete
/// `DeployReconciler` (Stages 12.8–12.9) conforms; it reads the manifest and rewrites agent deploys.
/// Injected so `runOnce` builds + tests before the reconcile logic lands. The reconcile's own manifest
/// read runs while `runOnce` holds the sync lock, so it never overlaps the GUI's `ManifestService.write`.
protocol DeployReconciling {
    @discardableResult
    func reconcile(root: String) throws -> ReconcileOutcome
}

/// A summary of one reconcile pass (Stages 12.8–12.9 populate the counts). Opaque to `runOnce`.
struct ReconcileOutcome: Equatable {
    let prunedLinks: Int
    let recompiledRules: Int
    init(prunedLinks: Int = 0, recompiledRules: Int = 0) {
        self.prunedLinks = prunedLinks
        self.recompiledRules = recompiledRules
    }
}

/// One safe, logged pull cycle — the daemon's decision core (PLAN-12 / 12.6). A files-only downstream
/// puller: it fast-forwards the canonical store (never rewrites history), reconciles agent deploys, and
/// NEVER opens SwiftData (the GUI's launch rebuild is authoritative). All roots + services are injected so
/// tests drive it against a temp HOME with fakes; the clock is injected for deterministic timestamps.
struct SyncDaemon {
    let root: String
    let appSupport: String
    let git: FastForwardGitService
    /// Pass the cycle root to the supplied git branch probe; main supplies GitService.hasLocalBranches.
    /// This keeps branch observation on the repository being synced without expanding the git protocol.
    let hasLocalBranches: (String) throws -> Bool
    let credentials: CredentialStoreProtocol
    let reconciler: DeployReconciling
    let now: () -> Date

    /// Log rotates when it exceeds this size, so an unattended daemon can't grow it unbounded.
    static let logRotateThreshold = SyncAudit.logRotateThreshold

    private var lockPath: String { appSupport + "/sync.lock" }

    // swiftlint:disable cyclomatic_complexity
    /// Run one cycle. Pure over injected services; deterministic branches; a bounded, atomic audit trail.
    func runOnce() -> DaemonCycleResult {
        // 1. Cross-process lock — the GUI git mutators (Stage 12.5) hold the SAME lock. A locked cycle is a
        //    pure no-op: another holder is doing the real work and will write the real status, so we do NOT
        //    write status/log here (that would clobber the working instance's status with a bare "locked").
        guard let lock = SyncLock.tryAcquire(at: lockPath) else {
            return .skipped(.locked)
        }
        defer { lock.release() }

        // 2. Remote must exist AND re-pass the RemoteURLPolicy allowlist EVERY cycle — a hand-edited
        //    .git/config can't ride an unchecked path (C1 defense in depth).
        let origin: String
        do {
            try git.probeUsability().requireUsable()
            guard let remote = try git.remoteURL(at: root) else { return finish(.skipped(.noRemote)) }
            guard try hasLocalBranches(root) else { return finish(.skipped(.branchless)) }
            origin = remote
        } catch {
            return finish(.failed(.preflight(error.localizedDescription)))
        }
        guard let spec = RemoteURLPolicy.parse(origin) else { return finish(.skipped(.rejectedRemote)) }

        // 3. Resolve the credential headlessly. ssh → agent; https → the Keychain PAT for the host (nil
        //    tolerated — git then fails fast with an auth error we map to .failed(.authentication)).
        let credential: GitCredential?
        switch spec.transport {
        case .ssh:   credential = .sshAgent
        case .https: credential = credentials.credential(forHost: spec.host)
        }

        // 4. Never fast-forward over a worktree we could not safely advance. Do NOT reconcile.
        guard git.isWorktreeClean(at: root) else { return finish(.skipped(.dirtyTree)) }

        // 5. Fast-forward only — never rewrites history. Auth error → .failed(.authentication); any other
        //    git error → .failed(.gitError). A non-fast-forwardable divergence → .skipped(.diverged).
        let ff: FastForwardResult
        do {
            ff = try git.fastForwardOnly(at: root, credential: credential)
        } catch GitError.authenticationFailed {
            return finish(.failed(.authentication))
        } catch {
            return finish(.failed(.gitError))
        }

        let changed: Bool
        switch ff {
        case .upToDate:      changed = false
        case .fastForwarded: changed = true
        case .diverged:      return finish(.skipped(.diverged))
        }

        // 6. Reconcile on BOTH success branches (self-heals even when already up-to-date). Reconcile is
        //    fail-safe internally (Stage 12.9); a reconcile error never fails the pull that already landed.
        //    Runs inside the held lock, so the reconcile's manifest read never overlaps a GUI write-swap.
        _ = try? reconciler.reconcile(root: root)
        return finish(.synced(changed: changed))
    }
    // swiftlint:enable cyclomatic_complexity

    /// Write the atomic status file + append the rotated log, then return the result. Called at every exit
    /// EXCEPT the locked no-op (which must not clobber the working instance's status).
    @discardableResult
    private func finish(_ result: DaemonCycleResult) -> DaemonCycleResult {
        SyncAudit(appSupport: appSupport, now: now)
            .record(category: result.category, detail: result.detail)
        return result
    }
}
