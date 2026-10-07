import Foundation
import SwiftData

/// The outcome of the launch-time store reconcile: the rebuild result (disk + manifest → SwiftData) and
/// whether the one-time PLAN-07 migration ran this launch (so the caller flips its persisted marker only
/// when it actually ran).
struct LaunchReconcileOutcome: Equatable {
    var rebuild: RebuildResult
    var migrationRan: Bool
    var ingestedHeadStamp: String?
    var ingestionNeedsRetry: Bool
    var quarantined: Bool

    init(rebuild: RebuildResult, migrationRan: Bool, ingestedHeadStamp: String? = nil,
         ingestionNeedsRetry: Bool = false, quarantined: Bool = false) {
        self.rebuild = rebuild
        self.migrationRan = migrationRan
        self.ingestedHeadStamp = ingestedHeadStamp
        self.ingestionNeedsRetry = ingestionNeedsRetry
        self.quarantined = quarantined
    }
}

/// Runs at GUI launch (`ContentView.onAppear`) to make the app HONESTLY files-authoritative (PLAN-12 / 12.3):
/// rebuild SwiftData FROM DISK first, so a background daemon (or another machine) that advanced
/// `~/.pensieve` while the GUI was closed is reflected here — and never clobbered by a stale-SwiftData
/// manifest write. The one-time self-describing migration (PLAN-07 / 07.5) is then gated three ways:
///   1. a manifest with CONTENT must exist to rebuild from — an absent OR content-free `manifest/` tree
///      (a fresh/legacy pre-PLAN-07 store, or an empty tree left by a half-written manifest) is NOT an
///      authoritative empty state, so the rebuild is skipped rather than reconciling SwiftData to the empty
///      snapshot (which would delete every category + reset overlay-backed fields, and the migration would
///      then bake that loss into a new manifest — 12.3 review, P1 + Layer-2 empty-tree finding; see
///      `manifestHasContent`);
///   2. a PERSISTED `alreadyMigrated` marker (passed in from `@AppStorage`) so it runs genuinely
///      once-ever — the previous per-launch `@State` reran it every launch, and its manifest write from
///      stale SwiftData clobbered daemon pulls; and
///   3. `RebuildResult.storeUnreadable` — when the manifest is a NEWER/unsupported (or corrupt) schema the
///      rebuild bails mutating nothing, and the migration's manifest write is SKIPPED ENTIRELY so an older
///      app never downgrade-clobbers a newer store.
/// Non-throwing (both composed services are). Call BEFORE `library.startWatching()` so migration's
/// normalizing writes aren't observed as external edits.
struct LaunchReconciler {
    private struct FinalHeadValidation {
        var rebuild: RebuildResult
        var observedHead: String?
        var ingestedHeadStamp: String?
        var ingestionNeedsRetry: Bool
        var migrationRan = false
    }

    private let rebuildService: StoreRebuildServiceProtocol
    private let migrationService: StoreMigrationServiceProtocol
    private let fileService: FileServiceProtocol
    private let manifestService: ManifestReadWriting
    private let root: String
    private let lockPath: String
    private let gitHeadStamp: GitHeadStamp
    private let headStampOverride: (() -> String?)?
    private let git: GitServiceProtocol

    init(rebuildService: StoreRebuildServiceProtocol = StoreRebuildService(),
         migrationService: StoreMigrationServiceProtocol = StoreMigrationService(),
         fileService: FileServiceProtocol = FileService(),
         manifestService: ManifestReadWriting = ManifestService(),
         root: String = Constants.pensieveBaseDir,
         lockPath: String = PathConstants.pensieveAppSupportDir + "/sync.lock",
         git: GitServiceProtocol = GitService(),
         headStampOverride: (() -> String?)? = nil) {
        self.rebuildService = rebuildService
        self.migrationService = migrationService
        self.fileService = fileService
        self.manifestService = manifestService
        self.root = root
        self.lockPath = lockPath
        self.gitHeadStamp = GitHeadStamp(fileService: fileService)
        self.headStampOverride = headStampOverride
        self.git = git
    }

    @discardableResult
    // externallyHeldLock: the caller vouches it holds sync.lock for this entire call (AppRuntime's
    // launch path, PLAN-23/23.3 fix round). The final-head validation then must NOT acquire the
    // non-reentrant lock itself — doing so self-conflicts and permanently blocks launch ingestion.
    func reconcileOnLaunch(context: ModelContext, alreadyMigrated: Bool,
                           externallyHeldLock: Bool = false) -> LaunchReconcileOutcome {
        if fileService.directoryExists(at: root + "/.git") {
            do {
                let hasLocalBranches = try git.hasLocalBranches(at: root)
                if !hasLocalBranches, try git.hasRemoteOriginConfigured(at: root) {
                    return quarantinedOutcome()
                }
            } catch {
                return quarantinedOutcome()
            }
        }
        // App init makes the first best-effort sweep. Retry immediately before rebuild because a
        // daemon may have held sync.lock during init.
        SkillInstallService.cleanupVendorTemps(
            fileService: fileService,
            storeRoot: root,
            lockPath: lockPath
        )

        // Rebuild-from-disk only when there's an authoritative manifest to rebuild FROM (`shouldRebuildOnLaunch`):
        // a readable-and-COMPLETE manifest (a daemon pull / established store — ingest it), OR an
        // unreadable one (newer schema / corrupt / unlistable — rebuild so it bails `storeUnreadable`,
        // preserving it). An empty/absent or half-written manifest is NOT an authoritative empty state —
        // rebuilding off it would delete every category + reset overlay fields, and the migration below
        // would bake that loss in — so it is skipped. (PLAN-12 / 12.3 review + Layer-2 rounds.)
        var observedHead = headStamp()
        var ingestedHeadStamp: String? = observedHead
        var ingestionNeedsRetry = false
        var rebuild = RebuildResult()
        if shouldRebuildOnLaunch(root: root, context: context) {
            let before = observedHead
            rebuild = rebuildService.rebuild(fromRoot: root, context: context)
            observedHead = headStamp()
            if observedHead != before {
                // The daemon fast-forwarded mid-rebuild — this rebuild may have read a torn manifest.
                // One bounded retry converges on the post-pull state without coupling launch to the
                // sync lock (PLAN-12 Decision Log 12.6 residual; user-decided hardening, 12.10).
                let retryHead = observedHead
                rebuild = rebuildService.rebuild(fromRoot: root, context: context)
                observedHead = headStamp()
                if !rebuild.storeUnreadable, observedHead == retryHead {
                    ingestedHeadStamp = retryHead
                } else {
                    ingestedHeadStamp = nil
                    ingestionNeedsRetry = !rebuild.storeUnreadable
                }
            } else {
                ingestedHeadStamp = rebuild.storeUnreadable ? nil : before
            }
        }
        // One-time PLAN-07 migration: skipped ENTIRELY on an unreadable (newer/corrupt) store — never
        // downgrade-clobber it — and skipped once the persisted marker records the backfill already
        // happened. Report `migrationRan` only on an ALL-CLEAR backfill — the baseline manifest was
        // written AND no per-skill anomaly was warned. `migrateIfNeeded` can write the manifest yet still
        // return `warnings` (a per-skill normalization/read failure it logs and skips); persisting the
        // once-ever marker on that partial success would permanently strand the failed skill without its
        // frontmatter/backfill. Gating on `warnings.isEmpty` makes a partial (or fully failed) migration
        // retry next launch instead. (PLAN-12 / 12.3 review, P2)
        let validation = validateFinalHead(FinalHeadValidation(
            rebuild: rebuild,
            observedHead: observedHead,
            ingestedHeadStamp: ingestedHeadStamp,
            ingestionNeedsRetry: ingestionNeedsRetry
        ), alreadyMigrated: alreadyMigrated, externallyHeldLock: externallyHeldLock, context: context)
        return LaunchReconcileOutcome(
            rebuild: validation.rebuild,
            migrationRan: validation.migrationRan,
            ingestedHeadStamp: validation.ingestedHeadStamp,
            ingestionNeedsRetry: validation.ingestionNeedsRetry
        )
    }

    private func quarantinedOutcome() -> LaunchReconcileOutcome {
        LaunchReconcileOutcome(
            rebuild: RebuildResult(),
            migrationRan: false,
            ingestedHeadStamp: nil,
            ingestionNeedsRetry: false,
            quarantined: true
        )
    }

    private func validateFinalHead(
        _ initial: FinalHeadValidation,
        alreadyMigrated: Bool,
        externallyHeldLock: Bool,
        context: ModelContext
    ) -> FinalHeadValidation {
        var result = initial
        guard !result.rebuild.storeUnreadable else {
            result.ingestedHeadStamp = nil
            result.ingestionNeedsRetry = false
            return result
        }
        var ownedLock: SyncLock?
        if !externallyHeldLock {
            guard let lock = SyncLock.tryAcquire(at: lockPath) else {
                result.ingestedHeadStamp = nil
                result.ingestionNeedsRetry = true
                return result
            }
            ownedLock = lock
        }
        defer { ownedLock?.release() }
        guard headStamp() == result.observedHead else {
            result.ingestedHeadStamp = nil
            result.ingestionNeedsRetry = true
            return result
        }
        if !alreadyMigrated {
            let migration = migrationService.migrateIfNeeded(fromRoot: root, context: context)
            result.migrationRan = migration.manifestWritten && migration.warnings.isEmpty
        }
        return result
    }

    /// Whether the launch rebuild should run. Delegates the "is this manifest usable" question to the read
    /// the rebuild itself performs: attempt `ManifestService.read`, and
    ///   • if it THROWS — a NEWER/unsupported `schema_version` (an older client must not downgrade a newer
    ///     store), a corrupt manifest, or an overlay dir that can't be listed (transient I/O) — there IS a
    ///     manifest we must not silently discard: RUN the rebuild so it surfaces `storeUnreadable`, which
    ///     also SKIPS migration, PRESERVING the store — instead of skipping here and letting migration
    ///     overwrite/downgrade it. (PLAN-12 / 12.3 Layer-2: newer-schema-without-completion-marker + P2.)
    ///   • if it SUCCEEDS (a supported schema, or an absent manifest that reads as an empty snapshot) — rebuild
    ///     ONLY when the manifest is COMPLETE (`manifestHasContent`); a `manifest.yaml`-only partial reads as an
    ///     empty snapshot that would wrongly delete categories, so it must be skipped.
    private func shouldRebuildOnLaunch(root: String, context: ModelContext) -> Bool {
        if (try? manifestService.read(fromRoot: root)) == nil { return true }
        if manifestHasContent(root: root) { return true }
        return hasUnmanagedSkillOnDisk(root: root, context: context)
    }

    /// A files→manifest install crash can leave the first canonical skill in a store whose
    /// manifest is still absent. Rebuild only for a disk slug missing from SwiftData, preserving
    /// legacy/content-free-manifest cases whose existing rows must bootstrap migration.
    private func hasUnmanagedSkillOnDisk(root: String, context: ModelContext) -> Bool {
        let skillsRoot = root + "/skills"
        guard let rows = try? context.fetch(FetchDescriptor<Skill>()),
              let entries = try? fileService.listDirectory(at: skillsRoot) else {
            return false
        }
        let known = Set(rows.map(\.directoryName))
        return entries.contains { slug in
            !known.contains(slug)
                && SkillStore.isCanonicalSlug(slug)
                && SkillStore.safeSkillFile(
                    slug: slug,
                    base: skillsRoot,
                    fileService: fileService
                ) != nil
        }
    }

    private func headStamp() -> String? {
        if let headStampOverride { return headStampOverride() }
        return gitHeadStamp.read(root: root)
    }

    /// Whether a READABLE manifest is COMPLETE enough to rebuild from (called only when `read` succeeded, so
    /// the overlay dirs are listable). `projects.yaml` is written LAST by every complete `ManifestService.write`
    /// (the atomic writer and the legacy in-place one), so its presence is a reliable completion marker; a
    /// surviving overlay tree with the anchors gone is itself authoritative content (Layer-2 Finding A). A bare
    /// `manifest.yaml` with neither is a half-written partial — skipped, so it can't drive a category-deleting
    /// rebuild off an empty snapshot (Layer-2 P1: the pre-atomic-writer partial an upgrading user may carry).
    private func manifestHasContent(root: String) -> Bool {
        let manifestDir = root + "/manifest"
        if fileService.fileExists(at: manifestDir + "/projects.yaml") { return true }   // completion marker
        for sub in ["skills", "categories"] {
            if let entries = try? fileService.listDirectory(at: manifestDir + "/" + sub),
               entries.contains(where: { $0.hasSuffix(".yaml") }) {
                return true
            }
        }
        return false
    }
}
