import Foundation

// Stage mapping during `git pull --rebase origin main` is OPPOSITE a plain merge:
//   stage 2 (:2:) = origin/main = the OTHER machine
//   stage 3 (:3:) = the replayed local commit = THIS machine
// `blob(atStage: 2, ...)` reads the OTHER machine (origin/main); `blob(atStage: 3, ...)` reads THIS
// machine (the replayed local commit). Invert this and every diff side is labeled backwards.
extension GitService {

    /// `git show :<stage>:<path>` — exact bytes, or nil when that stage is absent. Empty data is
    /// a present empty file. Optional-read fallbacks preserve host and local output-read failures.
    func blob(atStage stage: Int, path: String, in workingDir: String) throws -> Data? {
        guard let r = try GitError.preservingUnusability({
            try runData(["-C", workingDir, "show", ":\(stage):\(path)"], in: nil)
        }), r.exit == 0 else {
            return nil
        }
        return r.stdout
    }

    /// True iff a rebase is mid-flight. Git owns `.git`; this structural probe stays inside GitService.
    func isRebaseInProgress(at path: String) -> Bool {
        let git = path + "/.git"
        return FileManager.default.fileExists(atPath: git + "/rebase-merge")
            || FileManager.default.fileExists(atPath: git + "/rebase-apply")
    }

    /// Continue a rebase, skipping only when the replay is structurally proven empty.
    func continueRebase(at path: String) throws -> PullResult {
        let store = try storeOperation(at: path)
        let args = ["-C", path, "rebase", "--continue"]
        let r = try store.run(Array(args.dropFirst(2)))
        if r.exit == 0 { return .merged }
        let conflicts = try conflictedFiles(at: path)
        if !conflicts.isEmpty { return .conflicted(conflicts) }
        let cachedClean = try GitError.preservingUnusability {
            try store.run(["diff", "--cached", "--quiet"])
        }?.exit == 0
        let worktreeClean = try GitError.preservingUnusability {
            try store.run(["diff", "--quiet"])
        }?.exit == 0
        if isRebaseInProgress(at: path) && cachedClean && worktreeClean {
            _ = try skipRebase(at: path, using: store)
            return .merged
        }
        throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
            confirmingProbe: r.confirmingProbe)
    }

    /// `git rebase --skip`. Exit 0 => .merged (or .upToDate if HEAD is unchanged); else throw.
    func skipRebase(at path: String) throws -> PullResult {
        try skipRebase(at: path, using: storeOperation(at: path))
    }

    private func skipRebase(at path: String, using store: StoreGitOperation) throws -> PullResult {
        let before = try headSHA(at: path)
        let args = ["-C", path, "rebase", "--skip"]
        let r = try store.run(Array(args.dropFirst(2)))
        guard r.exit == 0 else {
            throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
                confirmingProbe: r.confirmingProbe)
        }
        return before == (try headSHA(at: path)) ? .upToDate : .merged
    }

    /// `git add -- <path>` — stage a resolved path. The `--` guards a leading-dash path.
    func stagePath(_ path: String, at root: String) throws {
        try storeOperation(at: root).stagePath(path)
    }

    /// Collapse unpushed divergence to one commit so the following rebase replays exactly one commit.
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?) throws -> Bool {
        try ensureCommitIdentity(at: root)
        let fetch = try run(["-C", root, "fetch", "origin", "main"], in: nil, credential: credential)
        if fetch.exit != 0 {
            let combined = fetch.stdout + fetch.stderr
            if isAuthFailure(combined) {
                throw GitError.authenticationFailed(remote: authenticationRemoteLabel(at: root), detail: combined)
            }
            return try stageAllAndCommit(at: root, message: message)
        }
        let store = try storeOperation(at: root)
        try store.stage()
        guard let baseR = try runBestEffort(["-C", root, "merge-base", "HEAD", "origin/main"], in: nil),
              baseR.exit == 0 else {
            return try store.commitStagedChanges(message: message)
        }
        let base = baseR.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return try store.commitStagedChanges(message: message) }
        try runOrThrow(["-C", root, "reset", "--soft", base], in: nil)
        return try store.commitStagedChanges(message: message)
    }

    /// True iff at least one local commit is not on origin/main.
    /// Ordinary failures return false. A confirmed host failure propagates.
    func hasCommitsToPush(at path: String) throws -> Bool {
        guard let r = try runBestEffort(["-C", path, "rev-list", "--count", "origin/main..HEAD"], in: nil),
              r.exit == 0 else {
            return false
        }
        return (Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }
}
