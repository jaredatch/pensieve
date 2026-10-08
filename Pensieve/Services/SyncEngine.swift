import Foundation
import SwiftData

// MARK: - Outcome

/// The result of one `SyncEngine.sync`. `Equatable` so tests assert it directly and `SyncModel` maps it
/// to UI state. `.synced(pushed:)` reports whether this sync created a local commit to publish; the push
/// op runs regardless, so a merged history and the upstream ref are always published.
enum SyncOutcome: Equatable {
    case synced(pushed: Bool, warnings: [String], ingestedHeadStamp: String? = nil)
    case conflicted([String])
    case noRemote
    case branchless

    static func == (lhs: SyncOutcome, rhs: SyncOutcome) -> Bool {
        switch (lhs, rhs) {
        case let (.synced(leftPushed, leftWarnings, _), .synced(rightPushed, rightWarnings, _)):
            return leftPushed == rightPushed && leftWarnings == rightWarnings
        case let (.conflicted(left), .conflicted(right)):
            return left == right
        case (.noRemote, .noRemote), (.branchless, .branchless):
            return true
        default:
            return false
        }
    }
}

/// A sync-level failure distinct from a git command failure. `.storeUnreadable` means the pulled manifest
/// is a newer/unreadable schema this build could not ingest — we refuse to push our older snapshot over
/// it (a downgrade) and tell the user to update. (PLAN-08 / 08.4 review)
enum SyncError: LocalizedError, Equatable {
    case storeUnreadable([String])
    case conflictsChanged
    case conflictSideUnavailable(path: String)
    case rejectedRemote(String)
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case .storeUnreadable:
            return "Couldn't read the synced store — it may have been written by a newer version of "
                + "Pensieve. Update Pensieve, then sync again."
        case .conflictsChanged:
            return "The conflict changed while you were resolving it — reopen to see the latest."
        case let .conflictSideUnavailable(path):
            return "Pensieve can’t keep this version of \(path) as a file. Choose the other version."
        case .rejectedRemote:
            return "This store's git remote uses an unsupported form. Reconnect with an https:// URL "
                + "or an ssh remote (git@host:path)."
        case .syncInProgress:
            return "Sync is already running. Wait for it to finish, then try again."
        }
    }
}

// MARK: - Protocol

protocol SyncEngineProtocol {
    /// Serialize → commit → pull-rebase → rebuild → push. A body/overlay conflict aborts the rebase
    /// (restoring the exact pre-pull tree) and returns `.conflicted` WITHOUT rebuilding or pushing. When
    /// no remote is configured, returns `.noRemote` before touching git. `prepare` runs under `sync.lock`,
    /// after every pre-write guard and immediately before the snapshot. If it throws, sync performs no
    /// snapshot or git write; side effects already performed by the closure are intentionally not rolled back.
    func sync(root: String, message: String, credential: GitCredential?,
              context: ModelContext, prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome
    func inspectConflicts(root: String, credential: GitCredential?,
                          context: ModelContext) throws -> ConflictInspection
    func resolveConflicts(root: String, picks: [String: ResolutionPick],
                          credential: GitCredential?, context: ModelContext) throws -> SyncOutcome
}

extension SyncEngineProtocol {
    func sync(root: String, message: String, credential: GitCredential?,
              context: ModelContext) throws -> SyncOutcome {
        try sync(root: root, message: message, credential: credential, context: context, prepare: nil)
    }
}

// MARK: - Implementation

/// "Sync now" orchestration (PLAN-08 / 08.4). Ties the PLAN-07 store to `GitService`: it
/// projects SwiftData into the manifest, installs git's built-in `merge=union` driver for the manifest
/// LIST files so concurrent category/project set-edits auto-merge, pulls with rebase, rebuilds the local
/// index from the merged files, and pushes. A body/overlay conflict is reported as a structured
/// `.conflicted` result it does NOT resolve — the safe interim (§D); PLAN-09 adds the diff-and-pick sheet.
struct SyncEngine: SyncEngineProtocol {
    private let gitService: GitServiceProtocol
    private let manifestService: ManifestSnapshotting
    private let storeRebuildService: StoreRebuildServiceProtocol
    private let fileService: FileServiceProtocol
    private let lockPath: String
    private let lockProvider: (String) -> SyncLock?

    init(gitService: GitServiceProtocol,
         manifestService: ManifestSnapshotting = ManifestService(),
         storeRebuildService: StoreRebuildServiceProtocol = StoreRebuildService(),
         fileService: FileServiceProtocol = FileService(),
         lockPath: String,
         lockProvider: @escaping (String) -> SyncLock? = { SyncLock.tryAcquire(at: $0) }) {
        self.gitService = gitService
        self.manifestService = manifestService
        self.storeRebuildService = storeRebuildService
        self.fileService = fileService
        self.lockPath = lockPath
        self.lockProvider = lockProvider
    }

    func sync(root: String, message: String, credential: GitCredential?,
              context: ModelContext, prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        guard let lock = lockProvider(lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        try gitService.probeUsability().requireUsable()
        // Ask about the remote before any write, so an unconfigured store is never changed.
        guard try gitService.remoteURL(at: root) != nil else { return .noRemote }
        guard try gitService.hasLocalBranches(at: root) else { return .branchless }
        try requireAcceptableRemote(at: root)

        // Guard BEFORE any write: if the on-disk manifest is newer/unreadable (e.g. a clone of a remote
        // written by a newer Pensieve), refuse. The after-pull storeUnreadable guard CANNOT catch this —
        // step 1 below would already have clobbered the newer manifest with our snapshot, so we'd push a
        // downgrade. Reading it here (before the write) fails fast instead. (PLAN-08 review)
        do {
            _ = try manifestService.read(fromRoot: root)
        } catch {
            throw SyncError.storeUnreadable([])
        }

        let headStamp = GitHeadStamp(fileService: fileService)
        let incoming = try gitService.preflightStoreUpdate(at: root, credential: credential)
        try prepare?(context)

        // 1. SwiftData → manifest files (the portable, mergeable source of truth).
        try manifestService.write(manifestService.snapshot(from: context), toRoot: root)
        // 2. Install the union-merge driver + ignore rules (idempotent) so the pull below auto-merges
        //    concurrent list edits instead of emitting conflict markers.
        try ensureSyncAttributes(root: root)
        // 3. Commit (false when nothing changed locally).
        let committed = try gitService.stageAllAndCommit(at: root, message: message)

        // 4. Pull with rebase. A body/overlay conflict is NOT ours to resolve here: abort (restoring the
        //    exact pre-pull tree — nothing half-merged, nothing lost) and surface it. Do NOT rebuild, do
        //    NOT push, so the divergence is preserved for a later, resolvable sync (§D).
        switch try pullRebase(root: root, credential: credential, incoming: incoming) {
        case .upToDate, .merged:
            break
        case let .conflicted(paths):
            try gitService.abortRebase(at: root)
            return .conflicted(paths)
        }

        // 5. Rebuild the local index from the merged files.
        let rebuild = storeRebuildService.rebuild(fromRoot: root, context: context)
        // A fatal rebuild skip (the pulled manifest is a newer/unreadable schema) means we did NOT ingest
        // what we just pulled. Do NOT push our older snapshot over it (a downgrade) and do NOT report
        // success — surface it so the user updates Pensieve; the local commit stays unpushed for a retry.
        if rebuild.storeUnreadable {
            throw SyncError.storeUnreadable(rebuild.warnings)
        }
        // 6. Publish.
        let ingestedHeadStamp = headStamp.read(root: root)
        try gitService.push(at: root, credential: credential)
        return .synced(
            pushed: committed,
            warnings: rebuild.warnings,
            ingestedHeadStamp: ingestedHeadStamp
        )
    }

    func inspectConflicts(root: String, credential: GitCredential?,
                          context: ModelContext) throws -> ConflictInspection {
        guard let lock = lockProvider(lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        try gitService.probeUsability().requireUsable()
        guard try gitService.remoteURL(at: root) != nil else { return .conflicts(ConflictSet(items: [])) }
        guard try gitService.hasLocalBranches(at: root) else {
            return .conflicts(ConflictSet(items: []))
        }
        try requireAcceptableRemote(at: root)
        try GitError.preservingUnusability { try gitService.abortRebase(at: root) }
        do {
            _ = try manifestService.read(fromRoot: root)
        } catch {
            throw SyncError.storeUnreadable([])
        }
        let incoming = try gitService.preflightStoreUpdate(at: root, credential: credential)
        _ = try prepareLocalHead(root: root, credential: credential, context: context)
        // Once prepareLocalHead succeeds, pullRebase may START a rebase; if it (or finishSync) then
        // throws for a non-conflict reason, abort so inspect NEVER leaves a mid-rebase tree at rest
        // (the safe-resting-state invariant). Mirrors resolveConflicts' outer catch.
        do {
            switch try pullRebase(root: root, credential: credential, incoming: incoming) {
            case .upToDate, .merged:
                return .cleared(try finishSync(root: root, credential: credential, context: context))
            case let .conflicted(paths):
                let items = try paths.map { path in
                    let this = try ConflictVersion { try gitService.blob(atStage: 3, path: path, in: root) }
                    let other = try ConflictVersion { try gitService.blob(atStage: 2, path: path, in: root) }
                    return ConflictItem(path: path, kind: Self.kind(for: path),
                                        thisMachine: this.bytes, otherMachine: other.bytes,
                                        thisUnavailable: this.unavailable, otherUnavailable: other.unavailable)
                }
                try gitService.abortRebase(at: root)
                return .conflicts(ConflictSet(items: items))
            }
        } catch {
            try? gitService.abortRebase(at: root)
            throw error
        }
    }

    func resolveConflicts(root: String, picks: [String: ResolutionPick],
                          credential: GitCredential?, context: ModelContext) throws -> SyncOutcome {
        guard let lock = lockProvider(lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        try gitService.probeUsability().requireUsable()
        guard try gitService.remoteURL(at: root) != nil else { return .noRemote }
        guard try gitService.hasLocalBranches(at: root) else { return .branchless }
        try requireAcceptableRemote(at: root)
        try GitError.preservingUnusability { try gitService.abortRebase(at: root) }
        do {
            _ = try manifestService.read(fromRoot: root)
        } catch {
            throw SyncError.storeUnreadable([])
        }
        let incoming = try gitService.preflightStoreUpdate(at: root, credential: credential)
        _ = try prepareLocalHead(root: root, credential: credential, context: context)
        do {
            switch try pullRebase(root: root, credential: credential, incoming: incoming) {
            case .upToDate, .merged:
                return try finishSync(root: root, credential: credential, context: context)
            case let .conflicted(paths):
                try resolveConflictedPaths(paths, picks: picks, root: root)
                if case .conflicted = try gitService.continueRebase(at: root) {
                    throw SyncError.conflictsChanged
                }
                return try finishSync(root: root, credential: credential, context: context)
            }
        } catch {
            try? gitService.abortRebase(at: root)
            throw error
        }
    }

    /// Write `~/.pensieve/.gitattributes` (union-merge for the manifest LIST files ONLY) plus a minimal
    /// `.gitignore`, idempotently, through `FileService`. Category files and `projects.yaml` get
    /// `merge=union` — git's built-in driver keeps BOTH sides' lines on a conflicting hunk, which with the
    /// one-item-per-line list format and dedup-on-read yields set-union semantics with no custom merge
    /// driver. Skill overlays (`manifest/skills/*.yaml`) are deliberately NOT unioned: they are
    /// scalar-dominant, so a concurrent same-skill edit is a genuine conflict the safe `.conflicted`
    /// interim handles — unioning it would produce a duplicate-key YAML file Yams refuses to parse.
    private func ensureSyncAttributes(root: String) throws {
        let attributes = """
        manifest/categories/*.yaml merge=union
        manifest/scenarios/*.yaml merge=union
        manifest/projects.yaml merge=union
        """
        try fileService.writeFile(at: root + "/.gitattributes", content: attributes + "\n")
        try fileService.writeFile(at: root + "/.gitignore", content: ".DS_Store\n")
    }

    private static let resolveMessage = "Pensieve sync (resolve)"

    private func pullRebase(root: String, credential: GitCredential?, incoming: FetchedStoreRevision?) throws -> PullResult {
        if let incoming {
            return try gitService.pullRebase(at: root, fetchedRevision: incoming)
        }
        return try gitService.pullRebase(at: root, credential: credential)
    }

    /// Sync-time re-validation of the STORED remote against the FULL connect allowlist. A hand-edited
    /// `.git/config` that points `origin` at any connect-rejected form (ext::/fd::, http://, git://,
    /// file://, https-userinfo, dash-leading host, interior newline) is rejected before any network op,
    /// not silently executed (C1 defense in depth). nil origin is the caller's `.noRemote` case.
    private func requireAcceptableRemote(at root: String) throws {
        guard let origin = try gitService.remoteURL(at: root) else { return }
        if RemoteURLPolicy.parse(origin) == nil { throw SyncError.rejectedRemote(origin) }
    }

    @discardableResult
    private func prepareLocalHead(root: String, credential: GitCredential?,
                                  context: ModelContext) throws -> Bool {
        try manifestService.write(manifestService.snapshot(from: context), toRoot: root)
        try ensureSyncAttributes(root: root)
        return try gitService.collapseToSingleCommit(at: root, message: Self.resolveMessage,
                                                     credential: credential)
    }

    private func finishSync(root: String, credential: GitCredential?,
                            context: ModelContext) throws -> SyncOutcome {
        let pushed = try gitService.hasCommitsToPush(at: root)
        let rebuild = storeRebuildService.rebuild(fromRoot: root, context: context)
        if rebuild.storeUnreadable { throw SyncError.storeUnreadable(rebuild.warnings) }
        try gitService.push(at: root, credential: credential)
        let ingestedHeadStamp = GitHeadStamp(fileService: fileService).read(root: root)
        return .synced(
            pushed: pushed,
            warnings: rebuild.warnings,
            ingestedHeadStamp: ingestedHeadStamp
        )
    }

    private func resolveConflictedPaths(_ paths: [String], picks: [String: ResolutionPick],
                                        root: String) throws {
        guard Set(paths) == Set(picks.keys) else { throw SyncError.conflictsChanged }
        for path in paths {
            let this = try ConflictVersion { try gitService.blob(atStage: 3, path: path, in: root) }
            let other = try ConflictVersion { try gitService.blob(atStage: 2, path: path, in: root) }
            guard let pick = picks[path],
                  pick.expectedThis == this.bytes, pick.expectedOther == other.bytes,
                  pick.expectedThisUnavailable == this.unavailable,
                  pick.expectedOtherUnavailable == other.unavailable else {
                throw SyncError.conflictsChanged
            }
            guard let full = validatedWorktreePath(path, root: root) else {
                throw SyncError.conflictsChanged
            }
            let chosen = pick.side == .thisMachine ? this : other
            guard chosen.unavailable == nil else { throw SyncError.conflictSideUnavailable(path: path) }
            if let bytes = chosen.bytes {
                try fileService.writeData(at: full, data: bytes)
            } else {
                try fileService.deleteFile(at: full)
            }
            try gitService.stagePath(path, at: root)
        }
    }

    static func kind(for path: String) -> ConflictKind {
        if path.hasPrefix("skills/") && path.hasSuffix("/SKILL.md") { return .body }
        if path.hasPrefix("manifest/skills/") { return .overlay }
        if path.hasPrefix("manifest/categories/") { return .category }
        if path == "manifest/projects.yaml" { return .project }
        return .body
    }

    /// Validate a git-relative path before writing/deleting through it. Reject: empty/absolute paths;
    /// any `.`/`..`/empty/control-scalar component; any symlink at a directory/non-leaf component; and
    /// a symlinked leaf whose target resolves outside `root`. Containment is boundary-aware.
    private func validatedWorktreePath(_ path: String, root: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return nil }
            if component.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return nil
            }
        }
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var current = realRoot
        for (index, component) in components.enumerated() {
            current += "/" + component
            guard fileService.isSymlink(at: current) else { continue }
            // C7: never write/delete THROUGH a symlinked DIRECTORY component. A symlinked `skills/<slug>`
            // dir (even one whose target stays inside root) would redirect the atomic SKILL.md write into
            // the link target. Reject any non-leaf symlink outright; a symlinked leaf is safe because
            // `writeFile(atomically:)` replaces the link rather than following it (so keep the leaf's
            // escape-only check below).
            if index != components.count - 1 { return nil }
            guard let target = try? fileService.symlinkTarget(at: current) else { return nil }
            let base = target.hasPrefix("/")
                ? target
                : (current as NSString).deletingLastPathComponent + "/" + target
            let resolved = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
            if resolved != realRoot && !resolved.hasPrefix(realRoot + "/") { return nil }
        }
        return root + "/" + path
    }
}
