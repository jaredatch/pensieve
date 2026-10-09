import Foundation

/// A readable conflict entry retains its Git type and object identity beside its exact bytes.
struct ConflictEntry {
    let mode: String
    let objectID: String
    let bytes: Data
}

/// A present entry whose bytes are unavailable, distinct from an absent (deleted) side.
struct UnavailableConflictSide: Error, Equatable {
    let mode: String
    let objectID: String
}

// Stage mapping during `git pull --rebase origin main` is OPPOSITE a plain merge:
//   stage 2 (:2:) = origin/main = the OTHER machine
//   stage 3 (:3:) = the replayed local commit = THIS machine
// `blob(atStage: 2, ...)` reads the OTHER machine (origin/main); `blob(atStage: 3, ...)` reads THIS
// machine (the replayed local commit). Invert this and every diff side is labeled backwards.
extension GitService {

    /// `git show :<stage>:<path>` — exact bytes, or nil when that stage is absent. Empty data is
    /// a present empty file. Gitlinks or missing objects throw UnavailableConflictSide; command
    /// failures propagate. Only an absent index stage is a deletion.
    func blob(atStage stage: Int, path: String, in workingDir: String) throws -> Data? {
        try conflictEntry(atStage: stage, path: path, in: workingDir)?.bytes
    }

    func conflictEntry(atStage stage: Int, path: String, in workingDir: String) throws -> ConflictEntry? {
        let indexArgs = ["--literal-pathspecs", "-C", workingDir, "ls-files", "--stage", "-z", "--", path]
        let index = try runData(indexArgs, in: nil)
        guard index.exit == 0 else { throw dataCommandError(index, args: indexArgs) }
        let entry = index.stdout.split(separator: 0).compactMap { record -> UnavailableConflictSide? in
            let fields = record.split(separator: 9, maxSplits: 1)
            guard fields.count == 2, fields[1].elementsEqual(path.utf8) else { return nil }
            let header = fields[0].split(separator: 32)
            guard header.count == 3, header[2].elementsEqual(String(stage).utf8) else { return nil }
            guard let mode = String(bytes: header[0], encoding: .ascii),
                  let objectID = String(bytes: header[1], encoding: .ascii) else { return nil }
            return UnavailableConflictSide(mode: mode, objectID: objectID)
        }.first
        guard let entry else { return nil }
        guard entry.mode != "160000" else { throw entry }
        let args = ["-C", workingDir, "show", ":\(stage):\(path)"]
        let result = try runData(args, in: nil)
        if result.exit == 0 {
            return ConflictEntry(mode: entry.mode, objectID: entry.objectID, bytes: result.stdout)
        }
        let objectArgs = ["-C", workingDir, "cat-file", "-e", entry.objectID]
        let object = try runData(objectArgs, in: nil)
        if object.exit == 1 && object.stdout.isEmpty && object.stderr.isEmpty { throw entry }
        guard object.exit == 0 else { throw dataCommandError(object, args: objectArgs) }
        throw dataCommandError(result, args: args)
    }

    /// Git restores the selected entry's link type and executable mode without byte conversions.
    func restoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String) throws {
        let store = try storeOperation(at: root)
        try store.runOrThrow(["-c", "core.symlinks=true", "--literal-pathspecs", "checkout-index",
                             "--force", "--stage=\(stage)", "--", path])
        try store.runOrThrow(["--literal-pathspecs", "update-index", "--add", "--cacheinfo",
                             entry.mode + "," + entry.objectID + "," + path])
    }

    /// A legacy gitlink is removed only from the index. Its anchored root ignore travels to other
    /// Macs so later syncs cannot add ordinary local files beneath the retired path.
    func retireConflictPath(_ path: String, at root: String) throws {
        try storeOperation(at: root).runOrThrow(["--literal-pathspecs", "update-index", "--force-remove", "--", path])
        let escaped = path.unicodeScalars.map { scalar -> String in
            let text = String(scalar)
            return "\\*?[]!# ".unicodeScalars.contains(scalar) ? "\\" + text : text
        }.joined()
        let ignore = root + "/.gitignore"
        var rules = try fileService.readFile(at: ignore)
        let rule = "/" + escaped
        if !rules.split(separator: "\n").contains(where: { $0 == Substring(rule) }) {
            if !rules.hasSuffix("\n") { rules += "\n" }
            try fileService.writeFile(at: ignore, content: rules + rule + "\n")
        }
        try stagePath(".gitignore", at: root)
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
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                fetchedRevision: FetchedStoreRevision? = nil) throws -> Bool {
        try ensureCommitIdentity(at: root)
        if fetchedRevision == nil {
            let fetch = try run(["-C", root, "fetch", "origin", "main"], in: nil, credential: credential)
            if fetch.exit != 0 {
                let combined = fetch.stdout + fetch.stderr
                if isAuthFailure(combined) {
                    throw GitError.authenticationFailed(remote: authenticationRemoteLabel(at: root), detail: combined)
                }
                return try stageAllAndCommit(at: root, message: message)
            }
        }
        let store = try storeOperation(at: root)
        try store.stage()
        let upstream = fetchedRevision?.commit ?? "origin/main"
        guard let baseR = try runBestEffort(["-C", root, "merge-base", "HEAD", upstream], in: nil),
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
