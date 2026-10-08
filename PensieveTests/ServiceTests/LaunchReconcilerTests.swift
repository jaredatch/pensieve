import SwiftData
import XCTest
@testable import Pensieve

// Frozen PLAN-24 extends this existing launch-reconcile fixture file.
// swiftlint:disable file_length

private typealias PensieveCategory = Pensieve.Category

private final class Plan24RecordingRebuild: StoreRebuildServiceProtocol {
    private(set) var calls = 0
    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
        calls += 1
        return RebuildResult()
    }
}

private struct Plan24NoopMigration: StoreMigrationServiceProtocol {
    func migrateIfNeeded(fromRoot root: String, context: ModelContext) -> MigrationResult { MigrationResult() }
}

private struct Plan24LaunchProbeCase {
    var branches: Result<Bool, Error>
    var origin: Result<Bool, Error>
    var expectedOriginCalls: Int
}

private final class Plan24GitState: GitServiceProtocol {
    var remote: String?
    var branches: Result<Bool, Error> = .success(true)
    var origin: Result<Bool, Error> = .success(true)
    private(set) var branchProbeCalls = 0
    private(set) var originProbeCalls = 0
    func remoteURL(at path: String) -> String? { remote }
    func hasLocalBranches(at path: String) throws -> Bool {
        branchProbeCalls += 1
        return try branches.get()
    }
    func hasRemoteOriginConfigured(at path: String) throws -> Bool {
        originProbeCalls += 1
        return try origin.get()
    }
    func initRepository(at path: String) throws {}
    func setRemote(_ url: String, at path: String) throws {}
    func removeRemote(at path: String) throws {}
    func configuredRemoteURL(at path: String) throws -> String? { nil }
    func clone(remote: String, into path: String, credential: GitCredential?) throws {}
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { true }
    func stageAllAndCommit(at path: String, message: String) throws -> Bool { false }
    func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        try pullRebase(at: path, credential: nil)
    }
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult { .upToDate }
    func push(at path: String, credential: GitCredential?) throws {}
    func abortRebase(at path: String) throws {}
    func conflictedFiles(at path: String) -> [String] { [] }
    func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
    func continueRebase(at path: String) throws -> PullResult { .upToDate }
    func skipRebase(at path: String) throws -> PullResult { .upToDate }
    func stagePath(_ path: String, at root: String) throws {}
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?) throws -> Bool { false }
    func hasCommitsToPush(at path: String) -> Bool { false }
}

/// Delegates to a real `FileService` but reports a chosen directory as EXISTING while making its listing
/// throw — to exercise the launch gate's fail-safe: an overlay dir that exists but can't be listed (a
/// transient I/O error) must be treated as content-present, so the rebuild runs and surfaces the store as
/// unreadable rather than skipping and letting migration overwrite it (PLAN-12 / 12.3 Layer-2, P2).
private final class UnlistableDirFileService: FileServiceProtocol {
    struct ListBoom: Error {}
    private let real: FileService
    private let unlistableSuffix: String
    init(real: FileService, unlistableSuffix: String) {
        self.real = real
        self.unlistableSuffix = unlistableSuffix
    }
    func directoryExists(at path: String) -> Bool {
        path.hasSuffix(unlistableSuffix) ? true : real.directoryExists(at: path)
    }
    func listDirectory(at path: String) throws -> [String] {
        if path.hasSuffix(unlistableSuffix) { throw ListBoom() }
        return try real.listDirectory(at: path)
    }
    func readFile(at path: String) throws -> String { try real.readFile(at: path) }
    func writeFile(at path: String, content: String) throws { try real.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try real.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { real.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { real.isExecutableFile(at: path) }
    func createDirectory(at path: String) throws { try real.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try real.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try real.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try real.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { real.isSymlink(at: path) }
    func contentsHash(at path: String) throws -> String { try real.contentsHash(at: path) }
}

/// PLAN-12 / 12.3 — the launch-time rebuild-from-disk + gated one-time migration. Proves the GUI is
/// honestly files-authoritative: a daemon-advanced store is ingested and never clobbered, a newer-schema
/// store is not downgraded, and the one-time migration runs once, not per launch.
final class LaunchReconcilerTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var manifest: ManifestService!
    private var skillStore: SkillStore!
    private var rebuildService: StoreRebuildService!
    private var migrationService: StoreMigrationService!
    private var reconciler: LaunchReconciler!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveLaunchReconcilerTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        manifest = ManifestService(fileService: fileService)
        skillStore = SkillStore(fileService: fileService, baseDir: tempDir + "/skills", storeRoot: tempDir)
        rebuildService = StoreRebuildService(fileService: fileService, manifestService: manifest)
        migrationService = StoreMigrationService(fileService: fileService, manifestService: manifest,
                                                 skillStore: skillStore)
        reconciler = LaunchReconciler(
            rebuildService: rebuildService,
            migrationService: migrationService,
            manifestService: manifest,
            root: tempDir,
            lockPath: tempDir + "/sync.lock",
            git: TestPaths.git
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    @discardableResult
    private func seedSkill(_ context: ModelContext, name: String, description: String, dir: String,
                           tags: [String] = []) -> Skill {
        let skill = Skill(name: name, skillDescription: description, tags: tags, scope: .user,
                          directoryName: dir, cursorConfig: nil, importedFrom: nil)
        context.insert(skill)
        return skill
    }

    private func writeSkillFile(dir: String, name: String, description: String, body: String) throws {
        try fileService.writeFile(at: tempDir + "/skills/\(dir)/SKILL.md",
                                  content: SkillSerializer.serialize(name: name, description: description, body: body))
    }
}

extension LaunchReconcilerTests {
    @MainActor
    // The frozen method intentionally pins every quarantine and normal-ingestion probe combination.
    // swiftlint:disable:next function_body_length
    func testBranchlessOrUnknownConfiguredStoreSkipsIngestion() throws {
        struct SignalBoom: Error {}
        struct OriginBoom: Error {}
        try manifest.write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [], projects: [], skills: []
            ),
            toRoot: tempDir
        )
        try fileService.createDirectory(at: tempDir + "/.git")
        let quarantineCases = [
            Plan24LaunchProbeCase(branches: .success(false), origin: .success(true), expectedOriginCalls: 1),
            Plan24LaunchProbeCase(branches: .failure(SignalBoom()), origin: .success(true), expectedOriginCalls: 0),
            Plan24LaunchProbeCase(branches: .success(false), origin: .failure(OriginBoom()), expectedOriginCalls: 1)
        ]
        for fixture in quarantineCases {
            let rebuild = Plan24RecordingRebuild()
            let git = Plan24GitState(); git.branches = fixture.branches; git.origin = fixture.origin
            let subject = LaunchReconciler(
                rebuildService: rebuild,
                migrationService: Plan24NoopMigration(),
                fileService: fileService,
                manifestService: manifest,
                root: tempDir,
                lockPath: tempDir + "/plan24.lock",
                git: git
            )
            let outcome = subject.reconcileOnLaunch(context: try makeContext(), alreadyMigrated: true)
            XCTAssertEqual(
                outcome,
                LaunchReconcileOutcome(
                    rebuild: RebuildResult(), migrationRan: false, ingestedHeadStamp: nil,
                    ingestionNeedsRetry: false, quarantined: true
                )
            )
            XCTAssertEqual(rebuild.calls, 0)
            XCTAssertEqual(git.branchProbeCalls, 1)
            XCTAssertEqual(git.originProbeCalls, fixture.expectedOriginCalls)
        }

        let normalCases = [
            Plan24LaunchProbeCase(branches: .success(false), origin: .success(false), expectedOriginCalls: 1),
            Plan24LaunchProbeCase(branches: .success(true), origin: .success(true), expectedOriginCalls: 0)
        ]
        for fixture in normalCases {
            let rebuild = Plan24RecordingRebuild()
            let git = Plan24GitState(); git.branches = fixture.branches; git.origin = fixture.origin
            let subject = LaunchReconciler(
                rebuildService: rebuild, migrationService: Plan24NoopMigration(),
                fileService: fileService, manifestService: manifest, root: tempDir,
                lockPath: tempDir + "/plan24-normal.lock", git: git
            )
            let outcome = subject.reconcileOnLaunch(context: try makeContext(), alreadyMigrated: true)
            XCTAssertFalse(outcome.quarantined)
            XCTAssertEqual(rebuild.calls, 1)
            XCTAssertEqual(git.branchProbeCalls, 1)
            XCTAssertEqual(git.originProbeCalls, fixture.expectedOriginCalls)
        }

        try fileService.deleteDirectory(at: tempDir + "/.git")
        let rebuild = Plan24RecordingRebuild()
        let git = Plan24GitState(); git.branches = .failure(SignalBoom()); git.origin = .failure(OriginBoom())
        let subject = LaunchReconciler(
            rebuildService: rebuild, migrationService: Plan24NoopMigration(),
            fileService: fileService, manifestService: manifest, root: tempDir,
            lockPath: tempDir + "/plan24-no-git.lock", git: git
        )
        let outcome = subject.reconcileOnLaunch(context: try makeContext(), alreadyMigrated: true)
        XCTAssertFalse(outcome.quarantined)
        XCTAssertEqual(rebuild.calls, 1)
        XCTAssertEqual(git.branchProbeCalls, 0)
        XCTAssertEqual(git.originProbeCalls, 0)
    }
}

extension LaunchReconcilerTests {
    // 1. Daemon-pulled skill: on disk + in the manifest overlay, absent from SwiftData. Launch rebuilds it
    //    into SwiftData; because the migration is already done, the overlay is byte-for-byte unchanged.
    @MainActor
    func testDaemonPulledSkillIsIngestedAndOverlayUnchanged() throws {
        // Produce a canonical store (SKILL.md + manifest overlay) the way the app/daemon would.
        let seed = try makeContext()
        seedSkill(seed, name: "Alpha", description: "a desc", dir: "alpha", tags: ["x"])
        try writeSkillFile(dir: "alpha", name: "Alpha", description: "a desc", body: "# A")
        migrationService.migrateIfNeeded(fromRoot: tempDir, context: seed)
        let overlayPath = tempDir + "/manifest/skills/alpha.yaml"
        let overlayBefore = try fileService.readFile(at: overlayPath)

        // A DIFFERENT, empty SwiftData store (GUI restart) — Alpha is "absent" from the DB.
        let fresh = try makeContext()
        let outcome = reconciler.reconcileOnLaunch(context: fresh, alreadyMigrated: true)

        XCTAssertEqual(outcome.rebuild.skillsInserted, 1)
        XCTAssertFalse(outcome.migrationRan)
        let rebuilt = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(rebuilt.directoryName, "alpha")
        XCTAssertEqual(rebuilt.skillDescription, "a desc")
        XCTAssertEqual(try fileService.readFile(at: overlayPath), overlayBefore)   // overlay NOT clobbered
    }

    // 2. Upstream-deleted skill: its SKILL.md + overlay are gone from disk; launch removes the SwiftData
    //    row and (already migrated) does not re-add an overlay.
    @MainActor
    func testUpstreamDeletedSkillIsRemovedAndOverlayNotReadded() throws {
        let ctx = try makeContext()
        seedSkill(ctx, name: "Beta", description: "b", dir: "beta")
        try writeSkillFile(dir: "beta", name: "Beta", description: "b", body: "# B")
        migrationService.migrateIfNeeded(fromRoot: tempDir, context: ctx)

        // Upstream deletion (a daemon prune / another machine): remove the skill dir AND its overlay.
        try FileManager.default.removeItem(atPath: tempDir + "/skills/beta")
        try fileService.deleteFile(at: tempDir + "/manifest/skills/beta.yaml")

        let outcome = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: true)

        XCTAssertEqual(outcome.rebuild.skillsRemoved, 1)
        XCTAssertFalse(outcome.migrationRan)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Skill>()).isEmpty)
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/manifest/skills/beta.yaml"))
    }

    // 3. Newer-schema store: rebuild bails (storeUnreadable), migration is skipped ENTIRELY, and the newer
    //    manifest is byte-for-byte unchanged — never downgrade-clobbered to the current schema. THE downgrade guard.
    @MainActor
    func testNewerSchemaManifestSkipsMigrationAndIsNotDowngraded() throws {
        let ctx = try makeContext()
        // A skill in SwiftData so migration WOULD write a current-schema manifest if it (wrongly) ran.
        seedSkill(ctx, name: "Newer", description: "n", dir: "newer")
        try writeSkillFile(dir: "newer", name: "Newer", description: "n", body: "# N")
        // A NEWER-schema manifest on disk (a future Pensieve / another machine wrote it). A real newer store
        // is a COMPLETE manifest — it carries the `projects.yaml` completion marker — so the launch gate runs
        // the rebuild, which then reads the unsupported schema and bails (`storeUnreadable`).
        let newerManifest = "schema_version: 6\n"
        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: newerManifest)
        try fileService.writeFile(at: tempDir + "/manifest/projects.yaml", content: "projects: []\n")

        let outcome = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: false)

        XCTAssertTrue(outcome.rebuild.storeUnreadable)
        XCTAssertFalse(outcome.migrationRan)
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/manifest.yaml"), newerManifest)
    }

    // 4. Migration-once: it runs (writing the baseline overlay) on a fresh store's first launch, and does
    //    NOT run on the second launch once the marker is set (so a deleted overlay is not recreated).
    @MainActor
    func testMigrationRunsOnFirstLaunchNotSecond() throws {
        let ctx = try makeContext()
        seedSkill(ctx, name: "Gamma", description: "g", dir: "gamma")
        try fileService.writeFile(at: tempDir + "/skills/gamma/SKILL.md", content: "# body only")

        let first = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: false)
        XCTAssertTrue(first.migrationRan)
        XCTAssertFalse(first.rebuild.storeUnreadable)
        XCTAssertTrue(fileService.fileExists(at: tempDir + "/manifest/skills/gamma.yaml"))   // migration wrote it

        // Delete the overlay so a second migration write would be detectable.
        try fileService.deleteFile(at: tempDir + "/manifest/skills/gamma.yaml")

        let second = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: true)
        XCTAssertFalse(second.migrationRan)
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/manifest/skills/gamma.yaml"))   // write skipped
    }

    // 5. Legacy first launch (12.3 review, P1 regression): a pre-PLAN-07 store has a category in SwiftData
    //    but NO manifest on disk. Launch must NOT rebuild off the absent (empty) manifest — that would
    //    delete the category, and the migration would then bake the loss into the bootstrapped manifest.
    //    Instead the rebuild is skipped and migration bootstraps the manifest FROM SwiftData, preserving it.
    @MainActor
    func testLegacyStoreWithoutManifestPreservesCategories() throws {
        let ctx = try makeContext()
        let category = PensieveCategory(name: "Favorites")
        category.skillSlugs = ["delta"]
        ctx.insert(category)
        seedSkill(ctx, name: "Delta", description: "d", dir: "delta", tags: ["keep"])
        try fileService.writeFile(at: tempDir + "/skills/delta/SKILL.md", content: "# body only, no frontmatter")
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/manifest/manifest.yaml"))   // legacy: no manifest yet

        let outcome = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: false)

        XCTAssertTrue(outcome.migrationRan)                                            // migration bootstrapped it
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PensieveCategory>()).count, 1)    // category SURVIVED
        let cat = try XCTUnwrap(try manifest.read(fromRoot: tempDir).categories.first) // and is in the manifest
        XCTAssertEqual(cat.name, "Favorites")
        XCTAssertEqual(cat.skillSlugs, ["delta"])
    }

    // 6. Partial manifest tree (12.3 Layer-2, Finding A): the `manifest.yaml` schema anchor is gone but the
    //    skill overlays + SKILL.md files remain (a partially-clobbered store). `ManifestService.read` still
    //    reads those overlays, so launch must REBUILD (ingesting them) rather than skip on the missing
    //    schema file — skipping would let a subsequent migration prune the overlays. The gate is the
    //    `manifest/` DIRECTORY, not `manifest.yaml`.
    @MainActor
    func testPartialManifestTreeWithoutSchemaFileStillRebuilds() throws {
        let seed = try makeContext()
        seedSkill(seed, name: "Epsilon", description: "e desc", dir: "epsilon", tags: ["t"])
        try writeSkillFile(dir: "epsilon", name: "Epsilon", description: "e desc", body: "# E")
        migrationService.migrateIfNeeded(fromRoot: tempDir, context: seed)   // writes manifest.yaml + epsilon.yaml
        // Delete ONLY the schema anchor; keep the overlay tree + SKILL.md (a partial/corrupt store).
        try fileService.deleteFile(at: tempDir + "/manifest/manifest.yaml")
        XCTAssertTrue(fileService.fileExists(at: tempDir + "/manifest/skills/epsilon.yaml"))

        let fresh = try makeContext()   // empty SwiftData
        let outcome = reconciler.reconcileOnLaunch(context: fresh, alreadyMigrated: true)

        XCTAssertEqual(outcome.rebuild.skillsInserted, 1)   // rebuilt from the overlay tree, not skipped
        let rebuilt = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(rebuilt.directoryName, "epsilon")
        XCTAssertEqual(rebuilt.tags, ["t"])                 // overlay metadata ingested, not defaulted
    }

    // 7. Content-free manifest tree (12.3 Layer-2, the empty-tree finding): `ManifestService.write` creates
    //    `manifest/` + `skills/` + `categories/` BEFORE writing any file, so a write that fails at that point
    //    leaves an EMPTY tree while the real state still lives only in SwiftData. Launch must NOT treat that
    //    empty tree as authoritative — rebuilding off it reads an empty-but-current snapshot (absent
    //    `manifest.yaml` = "fresh store", not `storeUnreadable`), which would delete categories + reset
    //    overlay fields, and the migration retry would bake in the loss. The gate is authoritative manifest
    //    CONTENT, not the bare directory (which the earlier Finding-A fix keyed on).
    @MainActor
    func testEmptyManifestTreePreservesCategoriesAndOverlayFields() throws {
        let ctx = try makeContext()
        let category = PensieveCategory(name: "Keeper")
        category.skillSlugs = ["zeta"]
        ctx.insert(category)
        let skill = Skill(name: "Zeta", skillDescription: "z desc", tags: ["important"], scope: .project,
                          directoryName: "zeta",
                          cursorConfig: CursorAdapterConfig(description: "cfg", globs: nil, alwaysApply: false),
                          importedFrom: "claude")
        ctx.insert(skill)
        try writeSkillFile(dir: "zeta", name: "Zeta", description: "z desc", body: "# Z")
        // A content-free manifest tree: the dirs exist (a half-written manifest), but NO files.
        try fileService.createDirectory(at: tempDir + "/manifest/skills")
        try fileService.createDirectory(at: tempDir + "/manifest/categories")
        XCTAssertTrue(fileService.directoryExists(at: tempDir + "/manifest"))
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/manifest/manifest.yaml"))

        let outcome = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: true)

        // Rebuild SKIPPED (an empty tree is not authoritative), so nothing was clobbered.
        XCTAssertEqual(outcome.rebuild.skillsInserted, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PensieveCategory>()).count, 1)   // category SURVIVED
        let kept = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(kept.tags, ["important"])                                      // overlay fields NOT reset
        XCTAssertEqual(kept.importedFrom, "claude")
        XCTAssertNotNil(kept.cursorConfig)
    }

    // 8. Deferred import on upgrade (12.3 P1): a skill imported on a pre-overlay build has SKILL.md
    //    + a SwiftData row with cursor/importedFrom/tags but NO manifest overlay yet. A
    //    manifest WITH content exists (its other skills have overlays), so the rebuild runs — but it lacks
    //    THIS skill's overlay. The rebuild must PRESERVE the row's overlay-backed fields (the manifest is
    //    silent about them, not authoritative-empty) rather than reset to defaults, which the migration
    //    retry would then bake in. This is the root fix Option A alone did not cover.
    @MainActor
    func testDeferredImportWithoutOverlayIsPreservedOnRebuild() throws {
        let ctx = try makeContext()
        let cursor = CursorAdapterConfig(description: "c", globs: ["*.md"], alwaysApply: false)
        let skill = Skill(name: "Iota", skillDescription: "i desc", tags: ["keep"], scope: .project,
                          directoryName: "iota", cursorConfig: cursor, importedFrom: "cursor")
        ctx.insert(skill)
        try writeSkillFile(dir: "iota", name: "Iota", description: "i desc", body: "# I")
        // A COMPLETE manifest (has `projects.yaml` → `manifestHasContent` is true → rebuild runs) that lacks
        // an overlay for iota (its overlay was deferred). An empty snapshot writes manifest.yaml + projects.yaml.
        try manifest.write(
            ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: []),
            toRoot: tempDir
        )

        _ = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: true)   // isolate the rebuild path

        let kept = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "iota" })
        XCTAssertEqual(kept.tags, ["keep"])          // overlay-backed fields PRESERVED, not reset to defaults
        XCTAssertEqual(kept.scope, .project)
        XCTAssertEqual(kept.importedFrom, "cursor")
        XCTAssertNotNil(kept.cursorConfig)
    }

    // 9. Partial-failure migration must retry (12.3 P2): when migration writes the baseline manifest but a
    //    per-skill anomaly is WARNED (here: a SwiftData row whose SKILL.md is missing), the once-ever marker
    //    must NOT be set — else the failed skill is stranded without frontmatter/backfill forever. The
    //    caller persists `didRunStoreMigration` only when `migrationRan` is true.
    @MainActor
    func testPartialFailureMigrationDoesNotSetMigrationRan() throws {
        let ctx = try makeContext()
        seedSkill(ctx, name: "Mu", description: "m", dir: "mu")   // a row but NO SKILL.md on disk → migration warns
        XCTAssertFalse(fileService.directoryExists(at: tempDir + "/manifest"))   // no manifest → rebuild skipped

        let outcome = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: false)

        XCTAssertFalse(outcome.migrationRan)   // manifest written but WITH a warning → not once-ever; retry next launch
        XCTAssertTrue(fileService.fileExists(at: tempDir + "/manifest/manifest.yaml"))   // the manifest WAS written
    }

    // 10. Pre-existing schema-only manifest (12.3 Layer-2, P1): a partial manifest left by the OLD in-place
    //     writer — `manifest.yaml` present but the overlays + `projects.yaml` never written — must NOT be
    //     treated as authoritative on the next launch. The gate keys on `projects.yaml` (written LAST → a
    //     completion marker), so a schema-only tree is skipped and the SwiftData categories survive. The
    //     atomic writer prevents FUTURE partials, but not one already on an upgrading user's disk.
    @MainActor
    func testSchemaOnlyManifestIsNotRebuiltFromAndPreservesCategories() throws {
        let ctx = try makeContext()
        let category = PensieveCategory(name: "Survivor")
        category.skillSlugs = []
        ctx.insert(category)
        // A pre-atomic-writer partial: `manifest.yaml` only — no overlays, no `projects.yaml` completion marker.
        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: 1\n")
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/manifest/projects.yaml"))

        let outcome = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: true)

        XCTAssertEqual(outcome.rebuild.categoriesRemoved, 0)                          // rebuild did not run
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PensieveCategory>()).count, 1)   // category SURVIVED
    }

    // 11. Unlistable overlay dir (12.3 Layer-2, P2): when `manifest.yaml`/`projects.yaml` are absent but
    //     `manifest/skills` EXISTS and can't be listed (a transient I/O error), the gate treats it as
    //     content-present (fail-safe) so the rebuild runs; `ManifestService.read` then surfaces the store as
    //     unreadable (`storeUnreadable`) and bails, PRESERVING it — rather than the gate skipping the rebuild
    //     and letting migration overwrite the manifest from SwiftData.
    @MainActor
    func testUnlistableOverlayDirSurfacesUnreadableInsteadOfSkipping() throws {
        let ctx = try makeContext()
        let faulty = UnlistableDirFileService(real: fileService, unlistableSuffix: "/manifest/skills")
        let rebuild = StoreRebuildService(fileService: faulty, manifestService: ManifestService(fileService: faulty))
        let migration = StoreMigrationService(fileService: faulty, manifestService: ManifestService(fileService: faulty),
                                              skillStore: SkillStore(fileService: faulty, baseDir: tempDir + "/skills",
                                                  storeRoot: tempDir))
        let rec = LaunchReconciler(
            rebuildService: rebuild,
            migrationService: migration,
            fileService: faulty,
            manifestService: ManifestService(fileService: faulty),
            root: tempDir,
            lockPath: tempDir + "/sync.lock",
            git: TestPaths.git
        )

        let outcome = rec.reconcileOnLaunch(context: ctx, alreadyMigrated: true)

        XCTAssertTrue(outcome.rebuild.storeUnreadable)   // gate → rebuild ran → read threw on the unlistable dir → preserve
    }

    // 12. Newer-schema manifest WITHOUT the completion marker (12.3 Layer-2): an older client opening a
    //     newer/changed-layout store — `manifest.yaml` carries an unsupported `schema_version` but there is
    //     no `projects.yaml`/overlays. The gate must NOT skip on the missing marker: it attempts the read,
    //     which throws `unsupportedSchema`, so the rebuild runs and bails `storeUnreadable`, and migration is
    //     skipped — PRESERVING the newer store instead of downgrading it to the current schema.
    @MainActor
    func testNewerSchemaWithoutCompletionMarkerIsNotDowngraded() throws {
        let ctx = try makeContext()
        // A skill in SwiftData so migration WOULD write a current-schema manifest if it (wrongly) ran.
        seedSkill(ctx, name: "Future", description: "f", dir: "future")
        try writeSkillFile(dir: "future", name: "Future", description: "f", body: "# F")
        // Newer schema, NO projects.yaml / overlays (a future layout this client doesn't recognize).
        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: 6\n")
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/manifest/projects.yaml"))

        let outcome = reconciler.reconcileOnLaunch(context: ctx, alreadyMigrated: false)

        XCTAssertTrue(outcome.rebuild.storeUnreadable)   // read threw unsupportedSchema → rebuild bailed
        XCTAssertFalse(outcome.migrationRan)             // migration skipped → not downgraded
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/manifest.yaml"), "schema_version: 6\n")
    }

}
