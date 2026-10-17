import Foundation

/// A readable conflict entry retains its Git type and object identity beside its exact bytes.
struct ConflictEntry {
    let mode: String
    let objectID: String
    let bytes: Data
    var isGitlink: Bool { mode == "160000" }
}

/// A present entry whose bytes are unavailable, distinct from an absent (deleted) side.
struct UnavailableConflictSide: Error, Equatable {
    let mode: String
    let objectID: String
    enum Reason: Equatable { case gitlink, unsafeRetirement, missingObject }
    var reason: Reason = .missingObject
    var isGitlink: Bool { mode == "160000" }
    var canChoose: Bool { isGitlink && reason == .gitlink }
}

struct ConflictFolderMustMove: Error {}

struct ConflictAbortBlocked: LocalizedError {
    let paths: [String]
    let underlying: Error
    var errorDescription: String? {
        underlying.localizedDescription + " Move the folder at " + paths.joined(separator: ", ")
            + " out of the store, then sync again."
    }
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
    @_disfavoredOverload
    func blob(atStage stage: Int, path: String, in workingDir: String) throws -> Data? {
        try conflictEntry(atStage: stage, path: path, in: workingDir)?.bytes
    }

    @_disfavoredOverload
    func conflictEntry(atStage stage: Int, path: String, in workingDir: String) throws -> ConflictEntry? {
        if let entry = try indexConflictEntry(atStage: stage, path: path, in: workingDir) { return entry }
        for folder in try relocatedFolderConflicts(at: workingDir) {
            if path.utf8.elementsEqual(folder.path.utf8) {
                return stage == folder.fileStage
                    ? try indexConflictEntry(atStage: stage, path: folder.auxiliary, in: workingDir) : nil
            }
            if folder.children.contains(where: { $0.utf8.elementsEqual(path.utf8) }) {
                return stage == 5 - folder.fileStage ? try indexConflictEntry(atStage: 0, path: path, in: workingDir) : nil
            }
        }
        return nil
    }

    private func indexConflictEntry(atStage stage: Int, path: String, in workingDir: String) throws -> ConflictEntry? {
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
        if entry.isGitlink {
            throw UnavailableConflictSide(mode: entry.mode, objectID: entry.objectID,
                reason: StoreIgnoreRules.canRetire(path) ? .gitlink : .unsafeRetirement)
        }
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
    @_disfavoredOverload
    func restoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String) throws {
        let folder = try relocatedFolderConflicts(at: root).first { $0.path.utf8.elementsEqual(path.utf8) }
        if let folder { try requireRelocatedConflict(folder, at: root) }
        let replacesFolder = try conflictWorktreeType(path, root: root) == .directory
        if replacesFolder {
            guard stage == 3 else { throw ConflictFolderMustMove() }
            try requireIncomingConflictFolder(path, at: root)
        }
        let store = try storeOperation(at: root)
        if let folder {
            // One index transaction removes the children and auxiliary entry. All admission
            // checks precede it; abort recovery uses commits even if a later operation fails.
            if try fileService.entryExistsWithoutFollowingLinks(at: root + "/" + folder.auxiliary) {
                try fileService.deleteFile(at: root + "/" + folder.auxiliary)
            }
            try store.runOrThrow(["--literal-pathspecs", "update-index", "--force-remove", "--"]
                + folder.children + [folder.auxiliary])
        }
        if replacesFolder { try fileService.deleteDirectory(at: root + "/" + path) }
        try store.runOrThrow(["--literal-pathspecs", "update-index", "--add", "--cacheinfo",
                             entry.mode + "," + entry.objectID + "," + path])
        try store.runOrThrow(["-c", "core.symlinks=true", "--literal-pathspecs", "checkout-index", "--force", "--", path])
    }

    private func conflictWorktreeType(_ path: String, root: String) throws -> FileEntryType? {
        do {
            return try fileService.entryTypeWithoutFollowingLinks(at: root + "/" + path)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOTDIR) {
            // checkout-index --force handles a regular file occupying a parent component.
            return nil
        }
    }

    /// Resolve the logical index entry, keeping its worktree path and children. A verified
    /// relocation also removes Git's auxiliary worktree file beside that path.
    @_disfavoredOverload
    func removeConflictEntryFromIndex(_ path: String, at root: String) throws {
        if let folder = try relocatedFolderConflicts(at: root).first(where: { $0.path.utf8.elementsEqual(path.utf8) }) {
            try removeRelocatedConflict(folder, at: root)
        }
        try storeOperation(at: root).runOrThrow(["--literal-pathspecs", "update-index", "--force-remove", "--", path])
    }

    /// Retirement receipts travel in .pensieve-retired-paths. Current builds derive local metadata
    /// ignore rules from them; older builds preserve the receipts but do not enforce them.
    @_disfavoredOverload
    func retireConflictPath(_ path: String, at root: String) throws {
        var scoped = self
        scoped.storeState = StoreOperationState(root: root)
        let receipts = try StoreIgnoreRules.readReceipts(at: root, files: fileService)
        scoped.storeState?.receipts = try StoreIgnoreRules.publish(receipts, at: root, files: fileService, retiring: path)
        if storeState?.root == root { storeState?.receipts = scoped.storeState?.receipts }
        let store = try scoped.storeOperation(at: root)
        try store.runOrThrow(["--literal-pathspecs", "update-index", "--force-remove", "--", path])
        try store.stagePath(StoreIgnoreRules.receiptFile)
        try store.stagePath(".gitattributes")
        if try fileService.entryTypeWithoutFollowingLinks(at: root + "/.gitignore") == .regular {
            try store.stagePath(".gitignore")
        } else {
            try store.runOrThrow(["--literal-pathspecs", "update-index", "--force-remove", "--", ".gitignore"])
        }
    }

    /// True iff a rebase is mid-flight. Git owns `.git`; this structural probe stays inside GitService.
    func isRebaseInProgress(at path: String) -> Bool {
        let git = path + "/.git"
        return FileManager.default.fileExists(atPath: git + "/rebase-merge")
            || FileManager.default.fileExists(atPath: git + "/rebase-apply")
    }

    /// Continue a rebase, skipping only when the replay is structurally proven empty.
    @_disfavoredOverload
    func continueRebase(at path: String) throws -> PullResult {
        let store = try storeOperation(at: path)
        if storeState?.root == path { storeState?.folderConflicts = nil }
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
        throw commandError(r, args: args)
    }

    /// `git rebase --skip`. Exit 0 => .merged (or .upToDate if HEAD is unchanged); else throw.
    @_disfavoredOverload
    func skipRebase(at path: String) throws -> PullResult {
        try skipRebase(at: path, using: storeOperation(at: path))
    }

    private func skipRebase(at path: String, using store: StoreGitOperation) throws -> PullResult {
        let before = try headSHA(at: path)
        let args = ["-C", path, "rebase", "--skip"]
        let r = try store.run(Array(args.dropFirst(2)))
        guard r.exit == 0 else {
            throw commandError(r, args: args)
        }
        return before == (try headSHA(at: path)) ? .upToDate : .merged
    }

    /// `git add -- <path>` — stage a resolved path. The `--` guards a leading-dash path.
    @_disfavoredOverload
    func stagePath(_ path: String, at root: String) throws {
        if path == StoreIgnoreRules.receiptFile || path == ".gitattributes", storeState?.root == root {
            storeState?.receipts = nil
        }
        try storeOperation(at: root).stagePath(path)
    }

    /// Collapse unpushed divergence to one commit so the following rebase replays exactly one commit.
    @_disfavoredOverload
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                fetchedRevision: FetchedStoreRevision?) throws -> Bool {
        try ensureCommitIdentity(at: root)
        let state = storeState.flatMap { $0.root == root ? $0 : nil }
        if fetchedRevision == nil && state?.fetched == nil {
            let fetch = try run(["-C", root, "fetch", "origin", "main"], in: nil, credential: credential)
            if fetch.exit != 0 {
                let failure = commandError(fetch, args: ["-C", root, "fetch", "origin", "main"],
                                           authenticationRemote: authenticationRemoteLabel(at: root))
                if case .authenticationFailed = failure { throw failure }
                return try stageAllAndCommit(at: root, message: message)
            }
            if storeState?.root == root {
                let commit = try runOrThrow(["-C", root, "rev-parse", "--verify", "FETCH_HEAD^{commit}"], in: nil)
                    .stdout.trimmingCharacters(in: .newlines)
                storeState?.fetched = FetchedStoreRevision(commit: commit)
            }
        }
        let store = try storeOperation(at: root)
        try store.stage()
        let upstream = fetchedRevision?.commit ?? state?.fetched?.commit ?? "origin/main"
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
    @_disfavoredOverload
    func hasCommitsToPush(at path: String) throws -> Bool {
        guard let r = try runBestEffort(["-C", path, "rev-list", "--count", "origin/main..HEAD"], in: nil),
              r.exit == 0 else {
            return false
        }
        return (Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }
}

struct ConflictTreeEntry {
    let mode: String
    let object: String
}

extension GitService {
    /// During rebase HEAD is the incoming tree. Admit the entire folder before deleting any
    /// entry. Gitlinks, extra empty folders, changed modes/bytes and unreadable entries refuse.
    private func requireIncomingConflictFolder(_ path: String, at root: String) throws {
        let entries = try conflictTree(revision: "HEAD", root: root, path: path)
        guard entries[Data(path.utf8)]?.mode == "040000" else { throw ConflictFolderMustMove() }
        do {
            try requireMatchingConflictEntry(path, root: root, entries: entries)
        } catch let error as GitError {
            throw error
        } catch {
            throw ConflictFolderMustMove()
        }
    }

    private func requireMatchingConflictEntry(_ path: String, root: String,
                                              entries: [Data: ConflictTreeEntry]) throws {
        guard let entry = entries[Data(path.utf8)] else { throw ConflictFolderMustMove() }
        let full = root + "/" + path
        let type = try fileService.entryTypeWithoutFollowingLinks(at: full)
        if entry.mode == "040000" {
            guard type == .directory else { throw ConflictFolderMustMove() }
            for name in try fileService.listDirectory(at: full) {
                try requireMatchingConflictEntry(path + "/" + name, root: root, entries: entries)
            }
            return
        }
        guard ["100644", "100755", "120000"].contains(entry.mode) else { throw ConflictFolderMustMove() }
        let args = ["-C", root, "cat-file", "blob", entry.object]
        let blob = try runData(args, in: nil)
        guard blob.exit == 0 else { throw dataCommandError(blob, args: args) }
        let bytes: Data
        if entry.mode == "120000" {
            guard type == .symlink else { throw ConflictFolderMustMove() }
            // Compare the link itself; neither its contents nor deletion may follow its target.
            bytes = Data(try fileService.symlinkTarget(at: full).utf8)
        } else {
            guard type == .regular,
                  fileService.isUserExecutableFile(at: full) == (entry.mode == "100755") else {
                throw ConflictFolderMustMove()
            }
            bytes = try fileService.readRegularFileData(at: full, maximumBytes: blob.stdout.count, containedIn: root)
        }
        guard bytes == blob.stdout else { throw ConflictFolderMustMove() }
    }
}
