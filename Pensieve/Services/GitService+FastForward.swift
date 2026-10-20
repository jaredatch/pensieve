import Foundation

/// The outcome of a fast-forward-only sync (PLAN-12 / 12.4). SwiftData-free — the daemon (Stage 12.6)
/// consumes it. `.diverged` means `merge --ff-only` refused a non-fast-forward: HEAD and the worktree
/// are left exactly as before (the preceding fetch still advanced FETCH_HEAD/origin/main — harmless).
enum FastForwardResult: Equatable {
    case upToDate
    case fastForwarded(from: String, to: String)
    case diverged
}

/// Fast-forward primitives shared by the app's damaged-manifest recovery and the daemon.
extension GitService {
    /// Unlike staging, the damage check includes excluded and nested-repository additions under
    /// manifest/. A local .env.yaml can break a category read even though sync would not stage it.
    @_disfavoredOverload
    func manifestMatchesHead(at path: String) throws -> Bool {
        let store = try storeOperation(at: path)
        let args = ["diff", "--quiet", "HEAD", "--", ":(literal)manifest"]
        let difference = try store.run(args)
        if difference.exit == 1 { return false }
        guard difference.exit == 0 else { throw commandError(difference, args: ["-C", path] + args) }
        let listingArgs = ["ls-files", "--others", "--directory", "-z", "--", ":(literal)manifest"]
        let untracked = try store.runData(listingArgs)
        guard untracked.exit == 0 else { throw dataCommandError(untracked, args: ["-C", path] + listingArgs) }
        // Git can collapse untracked directories. Excluded leaves are checked as bytes;
        // visible containers match only when the reader permits them and no visible child remains.
        func matches(_ entry: Data.SubSequence) throws -> Bool {
            let entry = entry.last == 0x2F ? entry.dropLast() : entry
            let parts = entry.split(separator: 0x2F)
            guard parts.first?.elementsEqual("manifest".utf8) == true, let leaf = parts.last else { return false }
            let relative = entry.dropFirst("manifest/".utf8.count)
            if StoreExclusions.isExcludedFile(entry) || StoreExclusions.isExcludedDirectory(leaf),
               ManifestReaderPolicy.ignoresEntry(at: relative) { return true }
            guard ManifestReaderPolicy.ignoresEntry(at: relative, kind: .emptyDirectory),
                  let name = String(bytes: entry, encoding: .utf8),
                  try fileService.entryTypeWithoutFollowingLinks(at: path + "/" + name) == .directory else { return false }
            let prefix = entry.last == 0x2F ? Data(entry) : Data(entry) + Data([0x2F])
            return try fileService.listDirectory(at: path + "/" + name).allSatisfy {
                try matches(prefix + Data($0.utf8))
            }
        }
        return try untracked.stdout.split(separator: 0).allSatisfy(matches)
    }

    /// True iff the worktree has no uncommitted changes sync would stage. New nested repositories
    /// stay local; tracked files and ordinary untracked files (including skill-ignored ones) count.
    /// A failed/non-zero
    /// `status` (e.g. the path is not a repo) is treated as NOT clean — the conservative default that
    /// keeps a downstream puller from fast-forwarding over a worktree it could not inspect.
    @_disfavoredOverload
    func isWorktreeClean(at path: String) -> Bool {
        guard let store = try? storeOperation(at: path),
              let r = try? store.run(["status", "--porcelain", "--untracked-files=no"]), r.exit == 0,
              let ordinary = try? store.ordinaryUntrackedPaths(), ordinary.isEmpty else { return false }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fetch, guard protected local files, then merge the pinned fetched commit with `--ff-only`.
    /// Never creates a merge commit and never
    /// rebases: on a non-fast-forwardable divergence the merge exits non-zero, leaving HEAD AND the
    /// worktree exactly as before (the preceding fetch still advanced FETCH_HEAD/origin/main — expected,
    /// harmless) → `.diverged`. On a successful merge, classify by HEAD before/after:
    /// `.fastForwarded(from:to:)` when it moved, `.upToDate` when it did not. Auth failures propagate
    /// from `fetch` as `.authenticationFailed`. The local `merge` takes no credential (no network).
    @_disfavoredOverload
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        let store = try storeOperation(at: path)
        let before = try headSHA(at: path)
        let revision = try fetchStoreRevision(at: path, credential: credential)
        try store.requireNoExcludedCollision(with: revision.commit)
        let r = try store.run(["merge", "--ff-only", revision.commit])
        guard r.exit == 0 else { return .diverged }
        let after = try headSHA(at: path)
        if let before, let after, before != after {
            return .fastForwarded(from: before, to: after)
        }
        return .upToDate
    }
}

/// Owned by a single synchronous sync or retirement, never by the long-lived service.
final class StoreOperationState {
    let root: String
    var receipts: StoreIgnoreRules.Receipts?
    var infoDirectory: String?
    var fetched: FetchedStoreRevision?
    var folderConflicts: [RelocatedFolderConflict]?
    init(root: String) { self.root = root }
}

extension GitServiceProtocol {
    @_disfavoredOverload
    func abortRebase(at path: String, refusedFolder: String) throws { try abortRebase(at: path) }
    func scopedToStore(_ root: String) -> GitServiceProtocol { self }
    func prepareStoreRules(at root: String, files: FileServiceProtocol) throws {
        try StoreIgnoreRules.prepare(at: root, files: files)
    }
}
