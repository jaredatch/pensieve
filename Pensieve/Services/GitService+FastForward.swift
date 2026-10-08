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
    /// True iff the worktree has no uncommitted changes (tracked OR untracked). A failed/non-zero
    /// `status` (e.g. the path is not a repo) is treated as NOT clean — the conservative default that
    /// keeps a downstream puller from fast-forwarding over a worktree it could not inspect.
    func isWorktreeClean(at path: String) -> Bool {
        // Upgrade an existing store before status can run a skill's clean filter. A branchless
        // repository is still observed without installing metadata; sync refuses it before pulling.
        do {
            if try hasLocalBranches(at: path) { try ensureStoreAttributes(at: path) }
        } catch { return false }
        guard let r = try? run(["-C", path, "status", "--porcelain"], in: nil, storeRules: true), r.exit == 0,
              let unstaged = try? unstagedSkillPaths(at: path), unstaged.isEmpty else {
            return false
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `git -C <path> fetch origin main`. Advances FETCH_HEAD and (opportunistically) the `origin/main`
    /// remote-tracking ref without touching HEAD or the worktree. Throws `.authenticationFailed` on an
    /// auth error, `.commandFailed` on any other non-zero exit.
    func fetch(at path: String, credential: GitCredential?) throws {
        let args = ["-C", path, "fetch", "origin", "main"]
        let r = try run(args, in: nil, credential: credential)
        guard r.exit != 0 else { return }
        let combined = r.stdout + r.stderr
        if isAuthFailure(combined) {
            throw GitError.authenticationFailed(remote: authenticationRemoteLabel(at: path), detail: combined)
        }
        throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
            confirmingProbe: r.confirmingProbe)
    }

    /// Fetch, then `git -C <path> merge --ff-only origin/main`. Never creates a merge commit and never
    /// rebases: on a non-fast-forwardable divergence the merge exits non-zero, leaving HEAD AND the
    /// worktree exactly as before (the preceding fetch still advanced FETCH_HEAD/origin/main — expected,
    /// harmless) → `.diverged`. On a successful merge, classify by HEAD before/after:
    /// `.fastForwarded(from:to:)` when it moved, `.upToDate` when it did not. Auth failures propagate
    /// from `fetch` as `.authenticationFailed`. The local `merge` takes no credential (no network).
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        try ensureStoreAttributes(at: path)
        let before = try headSHA(at: path)
        try fetch(at: path, credential: credential)
        let r = try run(["-C", path, "merge", "--ff-only", "origin/main"], in: nil, storeRules: true)
        guard r.exit == 0 else { return .diverged }
        let after = try headSHA(at: path)
        if let before, let after, before != after {
            return .fastForwarded(from: before, to: after)
        }
        return .upToDate
    }
}
