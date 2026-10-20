import Foundation
import SwiftData

/// A sync-level failure distinct from a git command failure. `.storeUnreadable` means the pulled manifest
/// is a newer/unreadable schema this build could not ingest — we refuse to push our older snapshot over
/// it (a downgrade) and tell the user to update. (PLAN-08 / 08.4 review)
enum SyncError: LocalizedError, Equatable {
    case storeUnreadable([String])
    case ingestIncomplete
    case conflictsChanged
    case conflictSideUnavailable(path: String)
    case conflictRequiresGitResolution(path: String)
    case protectedGitlinkUnavailable(path: String)
    case conflictFolderMustMove(path: String)
    case localConflictFolderMustMove(path: String)
    case incompatibleConflictPicks(path: String)
    case returnToRestFailed(reason: String, detail: String)
    case rejectedRemote(String)
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case .storeUnreadable:
            return "Couldn't read the synced store — it may have been written by a newer version of "
                + "Pensieve. Update Pensieve, then sync again."
        case .ingestIncomplete:
            return "The store changed while Pensieve was rebuilding this Mac's library. "
                + "Wait for the other git operation to finish, then try again."
        case .conflictsChanged:
            return "The conflict changed while you were resolving it — reopen to see the latest."
        case let .conflictSideUnavailable(path):
            return "Pensieve can’t keep this version of \(path) as a file. Choose the other version."
        case let .conflictRequiresGitResolution(path):
            return "Pensieve can’t resolve this conflict. Resolve it in git: \(path)"
        case let .protectedGitlinkUnavailable(path):
            return "Pensieve can’t sync the nested repository at \(path). Choose the other version."
        case let .conflictFolderMustMove(path):
            return "Pensieve can’t replace the folder at \(path). Choose the other version to finish syncing."
        case let .localConflictFolderMustMove(path):
            return "Move the folder at \(path), then choose Other Mac again. You can also keep This Mac."
        case let .incompatibleConflictPicks(path):
            return "These picks don’t fit together. Choose the same Mac for \(path) and its contents."
        case let .returnToRestFailed(reason, detail):
            return reason + " Pensieve couldn’t return the store to rest. Resolve this problem, then sync again: " + detail
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

    private func scoped(to root: String) -> SyncEngine {
        SyncEngine(gitService: gitService.scopedToStore(root), manifestService: manifestService,
            storeRebuildService: storeRebuildService, fileService: fileService,
            lockPath: lockPath, lockProvider: lockProvider)
    }

    private var conflictOperation: SyncConflictOperation {
        SyncConflictOperation(gitService: gitService, fileService: fileService)
    }

    func sync(root: String, message: String, credential: GitCredential?,
              context: ModelContext, prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        let operation = scoped(to: root)
        return try operation.performSync(root: root, message: message, credential: credential, context: context, prepare: prepare)
    }

    private func performSync(root: String, message: String, credential: GitCredential?,
                             context: ModelContext, prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome {
        guard let lock = lockProvider(lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        try gitService.probeUsability().requireUsable()
        // Ask about the remote before store writes. Reclaim only abandoned intermediates before returning.
        let remote = try gitService.remoteURL(at: root)
        guard remote != nil else {
            try? fileService.cleanStoreIntermediates(at: root)
            // Repair only this Mac's index. An unconfigured store still gets no writes or sync error.
            try? StoreIngestState.rebuildIfNeeded(using: storeRebuildService, root: root, context: context, files: fileService)
            return .noRemote
        }
        guard try gitService.hasLocalBranches(at: root) else { return .branchless }
        try requireAcceptableRemote(at: root)
        try gitService.abortRebase(at: root)

        // Guard BEFORE any write: if the on-disk manifest is newer/unreadable (e.g. a clone of a remote
        // written by a newer Pensieve), refuse. The after-pull storeUnreadable guard CANNOT catch this —
        // step 1 below would already have clobbered the newer manifest with our snapshot, so we'd push a
        // downgrade. Reading it here (before the write) fails fast instead. (PLAN-08 review)
        try requireReadableManifest(root: root)

        let headStamp = GitHeadStamp(fileService: fileService)
        let incoming = try gitService.preflightStoreUpdate(at: root, credential: credential)
        try prepare?(context)
        try StoreIngestState.rebuildIfNeeded(using: storeRebuildService, root: root, context: context, files: fileService)

        let admittedParent = headStamp.read(root: root)
        // 1. SwiftData → manifest files (the portable, mergeable source of truth).
        try manifestService.write(manifestService.snapshot(from: context), toRoot: root)
        // 2. Install the union-merge driver + ignore rules (idempotent) so the pull below auto-merges
        //    concurrent list edits instead of emitting conflict markers.
        try ensureSyncAttributes(root: root)
        let localCommit = try? SyncLocalCommit(root: root, files: fileService,
                                                capture: gitService.hasUncommittedChanges(at: root))
        // 3. Commit (false when nothing changed locally).
        let committed = try gitService.stageAllAndCommit(at: root, message: message)
        localCommit?.record(from: admittedParent, to: headStamp.read(root: root), root: root,
                            git: gitService, state: StoreIngestState.shared(for: context.container))

        // 4. Pull with rebase. A body/overlay conflict is NOT ours to resolve here: abort (restoring the
        //    exact pre-pull tree — nothing half-merged, nothing lost) and surface it. Do NOT rebuild, do
        //    NOT push, so the divergence is preserved for a later, resolvable sync (§D).
        let pulled: Bool
        let result: PullResult
        do { result = try pullRebase(root: root, credential: credential, incoming: incoming) } catch {
            try conflictOperation.abortResolution(after: error, root: root)
            throw error
        }
        switch result {
        case .upToDate: pulled = false
        case .merged: pulled = true
        case let .conflicted(paths):
            try gitService.abortRebase(at: root)
            return .conflicted(paths)
        }

        // 5. Rebuild the local index from the merged files.
        let rebuild = try StoreIngestState.rebuild(using: storeRebuildService, root: root, context: context, files: fileService)
        // 6. Publish.
        let ingestedHeadStamp = headStamp.read(root: root)
        try gitService.push(at: root, credential: credential)
        return .synced(
            pushed: committed,
            warnings: rebuild.warnings,
            ingestedHeadStamp: ingestedHeadStamp, pulled: pulled
        )
    }

    func inspectConflicts(root: String, credential: GitCredential?,
                          context: ModelContext) throws -> ConflictInspection {
        let operation = scoped(to: root)
        return try operation.performInspectConflicts(root: root, credential: credential, context: context)
    }

    private func performInspectConflicts(root: String, credential: GitCredential?,
                                         context: ModelContext) throws -> ConflictInspection {
        guard let lock = lockProvider(lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        try gitService.probeUsability().requireUsable()
        guard try gitService.remoteURL(at: root) != nil else { return .conflicts(ConflictSet(items: [])) }
        guard try gitService.hasLocalBranches(at: root) else {
            return .conflicts(ConflictSet(items: []))
        }
        try requireAcceptableRemote(at: root)
        try gitService.abortRebase(at: root)
        try requireReadableManifest(root: root)
        let incoming = try gitService.preflightStoreUpdate(at: root, credential: credential)
        _ = try prepareLocalHead(root: root, credential: credential, context: context, incoming: incoming)
        // Once prepareLocalHead succeeds, pullRebase may START a rebase; if it (or finishSync) then
        // throws for a non-conflict reason, attempt abort and report any obstruction to returning
        // to rest. An abort failure itself must propagate without another attempt.
        let conflicts: ConflictSet
        do {
            switch try pullRebase(root: root, credential: credential, incoming: incoming) {
            case .upToDate:
                return .cleared(try finishSync(root: root, credential: credential, context: context, pulled: false))
            case .merged:
                return .cleared(try finishSync(root: root, credential: credential, context: context, pulled: true))
            case let .conflicted(paths):
                let items = try paths.map { path in
                    let this = try ConflictVersion { try gitService.conflictEntry(atStage: 3, path: path, in: root) }
                    let other = try ConflictVersion { try gitService.conflictEntry(atStage: 2, path: path, in: root) }
                    return ConflictItem(path: path, kind: Self.kind(for: path),
                                        thisMachine: this.bytes, otherMachine: other.bytes,
                                        thisUnavailable: this.unavailable, otherUnavailable: other.unavailable,
                                        thisMode: this.mode, otherMode: other.mode)
                }
                conflicts = ConflictSet(items: items)
            }
        } catch {
            try conflictOperation.abortResolution(after: error, root: root)
            throw error
        }
        do { try gitService.abortRebase(at: root) } catch {
            throw SyncError.returnToRestFailed(reason: "Pensieve couldn't finish inspecting conflicts.",
                                              detail: error.localizedDescription)
        }
        return .conflicts(conflicts)
    }

    func resolveConflicts(root: String, picks: [String: ResolutionPick],
                          credential: GitCredential?, context: ModelContext) throws -> SyncOutcome {
        let operation = scoped(to: root)
        return try operation.performResolveConflicts(root: root, picks: picks, credential: credential, context: context)
    }

    private func performResolveConflicts(root: String, picks: [String: ResolutionPick],
                                         credential: GitCredential?, context: ModelContext) throws -> SyncOutcome {
        guard let lock = lockProvider(lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        try gitService.probeUsability().requireUsable()
        guard try gitService.remoteURL(at: root) != nil else { return .noRemote }
        guard try gitService.hasLocalBranches(at: root) else { return .branchless }
        try requireAcceptableRemote(at: root)
        try gitService.abortRebase(at: root)
        try requireReadableManifest(root: root)
        let incoming = try gitService.preflightStoreUpdate(at: root, credential: credential)
        _ = try prepareLocalHead(root: root, credential: credential, context: context, incoming: incoming)
        do {
            switch try pullRebase(root: root, credential: credential, incoming: incoming) {
            case .upToDate:
                return try finishSync(root: root, credential: credential, context: context, pulled: false)
            case .merged:
                return try finishSync(root: root, credential: credential, context: context, pulled: true)
            case let .conflicted(paths):
                try conflictOperation.resolveConflictedPaths(paths, picks: picks, root: root)
                if case .conflicted = try gitService.continueRebase(at: root) {
                    throw SyncError.conflictsChanged
                }
                return try finishSync(root: root, credential: credential, context: context, pulled: true)
            }
        } catch {
            let refusedFolder: String?
            if case let SyncError.conflictFolderMustMove(path) = error {
                refusedFolder = path
            } else {
                refusedFolder = nil
            }
            try conflictOperation.abortResolution(after: error, root: root, refusedFolder: refusedFolder)
            throw error
        }
    }

    private func requireReadableManifest(root: String) throws {
        do {
            _ = try ManifestService.classifiedRead(using: manifestService, root: root, files: fileService)
        } catch {
            if case ManifestError.unsupportedSchema = error { throw SyncError.storeUnreadable([]) }
            throw error
        }
    }

    /// Install union merge for list-shaped category/project manifests plus ignore rules.
    /// Skill overlays contain scalars: union would produce duplicate keys and corrupt YAML.
    private func ensureSyncAttributes(root: String) throws {
        try gitService.prepareStoreRules(at: root, files: fileService)
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
                                  context: ModelContext, incoming: FetchedStoreRevision?) throws -> Bool {
        // A failed finish requires ingestion in the retry's fresh context. Healthy conflict
        // preparation still publishes saved window edits that have not reached the manifest.
        try StoreIngestState.rebuildIfNeeded(using: storeRebuildService, root: root, context: context, files: fileService)
        let stamp = GitHeadStamp(fileService: fileService)
        let admittedParent = stamp.read(root: root)
        try manifestService.write(manifestService.snapshot(from: context), toRoot: root)
        try ensureSyncAttributes(root: root)
        let localCommit = try? SyncLocalCommit(root: root, files: fileService,
                                                capture: gitService.hasUncommittedChanges(at: root))
        let committed = try gitService.collapseToSingleCommit(at: root, message: Self.resolveMessage,
                                                             credential: credential, fetchedRevision: incoming)
        localCommit?.record(from: admittedParent, to: stamp.read(root: root), root: root,
                            git: gitService, state: StoreIngestState.shared(for: context.container))
        return committed
    }

    private func finishSync(root: String, credential: GitCredential?,
                            context: ModelContext, pulled: Bool) throws -> SyncOutcome {
        let pushed = try gitService.hasCommitsToPush(at: root)
        let rebuild = try StoreIngestState.rebuild(using: storeRebuildService, root: root, context: context, files: fileService)
        try gitService.push(at: root, credential: credential)
        let ingestedHeadStamp = GitHeadStamp(fileService: fileService).read(root: root)
        return .synced(
            pushed: pushed,
            warnings: rebuild.warnings,
            ingestedHeadStamp: ingestedHeadStamp, pulled: pulled
        )
    }

}
