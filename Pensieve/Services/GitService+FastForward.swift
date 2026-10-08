import Foundation

/// The outcome of a fast-forward-only sync (PLAN-12 / 12.4). SwiftData-free — the daemon (Stage 12.6)
/// consumes it. `.diverged` means `merge --ff-only` refused a non-fast-forward: HEAD and the worktree
/// are left exactly as before (the preceding fetch still advanced FETCH_HEAD/origin/main — harmless).
enum FastForwardResult: Equatable {
    case upToDate
    case fastForwarded(from: String, to: String)
    case diverged
}

/// Fast-forward-only sync primitives (PLAN-12 / 12.4). Split into their own file (like
/// `ManifestService+Snapshot`/`SkillSerializer+Skill`) so `GitService.swift` stays under the
/// file-length cap without compressing its security-hardening comments. Concrete-only for now:
/// `GitServiceProtocol` exposure lands in Stage 12.6, when the daemon injects a stub for its
/// branch tests.
extension GitService {
    /// True iff the worktree has no uncommitted changes sync would stage. New nested repositories
    /// stay local; tracked files and ordinary untracked files (including skill-ignored ones) count.
    /// A failed/non-zero
    /// `status` (e.g. the path is not a repo) is treated as NOT clean — the conservative default that
    /// keeps a downstream puller from fast-forwarding over a worktree it could not inspect.
    func isWorktreeClean(at path: String) -> Bool {
        guard let store = try? storeOperation(at: path),
              let r = try? store.run(["status", "--porcelain", "--untracked-files=no"]), r.exit == 0,
              let ordinary = try? store.ordinaryUntrackedPaths(), ordinary.isEmpty,
              let unstaged = try? store.unstagedSkillPaths(), unstaged.isEmpty else { return false }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fetch, guard protected local files, then merge the pinned fetched commit with `--ff-only`.
    /// Never creates a merge commit and never
    /// rebases: on a non-fast-forwardable divergence the merge exits non-zero, leaving HEAD AND the
    /// worktree exactly as before (the preceding fetch still advanced FETCH_HEAD/origin/main — expected,
    /// harmless) → `.diverged`. On a successful merge, classify by HEAD before/after:
    /// `.fastForwarded(from:to:)` when it moved, `.upToDate` when it did not. Auth failures propagate
    /// from `fetch` as `.authenticationFailed`. The local `merge` takes no credential (no network).
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        let store = try storeOperation(at: path)
        let before = try headSHA(at: path)
        try fetch(at: path, credential: credential)
        let revision = try runOrThrow(["-C", path, "rev-parse", "--verify", "FETCH_HEAD^{commit}"], in: nil)
            .stdout.trimmingCharacters(in: .newlines)
        try store.requireNoExcludedCollision(with: revision)
        let r = try store.run(["merge", "--ff-only", revision])
        guard r.exit == 0 else { return .diverged }
        let after = try headSHA(at: path)
        if let before, let after, before != after {
            return .fastForwarded(from: before, to: after)
        }
        return .upToDate
    }
}
