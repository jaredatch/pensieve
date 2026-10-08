import XCTest
import SwiftData
@testable import Pensieve
// Disambiguates the SwiftData `Category` model from Foundation for the in-memory container schema.
private typealias PensieveCategory = Pensieve.Category
/// Stand-in for a SwiftData fetch failure inside `ThrowingSnapshotManifest.snapshot`.
private struct SnapshotFetchBoom: Error {}
/// PLAN-08 / 08.4 — SyncEngine orchestration + union-merge over stubs and real `file://` clones.
final class SyncEngineTests: XCTestCase {
    var tempDir: String!; var lockPath: String { tempDir + "-sync.lock" }

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveSyncEngineTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    // MARK: - Stub git (records call order; scriptable pull; configurable remote)
    final class StubGit: GitServiceProtocol {
        private(set) var calls: [String] = []
        var remote: String? = "https://fixture.test/x.git"
        var pullResult: PullResult = .merged
        var pullError: Error?
        /// Simulates a pull mutating the working tree before rebuild sees it.
        var pullSideEffect: ((String) -> Void)?
        var hasLocalBranchesResult: Result<Bool, Error> = .success(true)

        func remoteURL(at path: String) -> String? { remote }
        func initRepository(at path: String) throws {}
        func setRemote(_ url: String, at path: String) throws {}
        func removeRemote(at path: String) throws {}
        func configuredRemoteURL(at path: String) throws -> String? { nil }
        func clone(remote: String, into path: String, credential: GitCredential?) throws {}
        func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { true }
        func hasLocalBranches(at path: String) throws -> Bool { try hasLocalBranchesResult.get() }
        @discardableResult
        func stageAllAndCommit(at path: String, message: String) throws -> Bool {
            calls.append("commit")
            return true
        }

        func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
        func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
            try pullRebase(at: path, credential: nil)
        }
        func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
            calls.append("pull")
            if let pullError { throw pullError }
            pullSideEffect?(path)
            return pullResult
        }

        func push(at path: String, credential: GitCredential?) throws { calls.append("push") }
        func abortRebase(at path: String) throws { calls.append("abort") }
        func conflictedFiles(at path: String) -> [String] { [] }
        func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
        func continueRebase(at path: String) throws -> PullResult { .upToDate }
        func skipRebase(at path: String) throws -> PullResult { .upToDate }
        func stagePath(_ path: String, at root: String) throws {}
        func hasCommitsToPush(at path: String) -> Bool { false }
        func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?) throws -> Bool { false }
    }

    /// ManifestService whose `snapshot` throws, proving sync aborts before any write/git op.
    private struct ThrowingSnapshotManifest: ManifestSnapshotting {
        func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {}
        func read(fromRoot root: String) throws -> ManifestSnapshot {
            ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: [])
        }
        func snapshot(from context: ModelContext) throws -> ManifestSnapshot { throw SnapshotFetchBoom() }
    }

    /// A SyncEngine wired to a stub git + REAL manifest/rebuild/file services over the temp root.
    func makeEngine(git: GitServiceProtocol) -> SyncEngine {
        SyncEngine(gitService: git, manifestService: ManifestService(),
                   storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
    }

    /// Seed a skill on disk only, so a rebuild's effect is observable in the context.
    func seedDiskOnlySkill(_ slug: String) throws {
        let dir = tempDir + "/skills/" + slug
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let markdown = "---\nname: \(slug)\ndescription: \(slug) description\n---\n\nBody\n"
        try markdown.write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    func slugs(in context: ModelContext) -> [String] {
        ((try? context.fetch(FetchDescriptor<Skill>())) ?? []).map { $0.directoryName }.sorted()
    }

    func testHappyPathOrderAndRebuild() throws {
        let git = StubGit()
        git.pullResult = .merged
        let context = try makeContext()
        try seedProjectIntent(in: context)
        try seedDiskOnlySkill("alpha")
        let outcome = try makeEngine(git: git).sync(root: tempDir, message: "m", credential: nil, context: context)
        XCTAssertEqual(git.calls, ["commit", "pull", "push"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/manifest/manifest.yaml"))
        XCTAssertTrue(slugs(in: context).contains("alpha"), "rebuild should import the on-disk skill")
        XCTAssertEqual(
            try ManifestService().read(fromRoot: tempDir).deployIntents.first?.projectKey,
            "github.com/owner/project"
        )
        XCTAssertEqual(outcome, .synced(pushed: true, warnings: []))
    }

    func testUpToDateStillRebuildsAndPushes() throws {
        let git = StubGit()
        git.pullResult = .upToDate
        let context = try makeContext()
        try seedDiskOnlySkill("beta")
        let outcome = try makeEngine(git: git).sync(root: tempDir, message: "m", credential: nil, context: context)
        XCTAssertTrue(git.calls.contains("push"))
        XCTAssertTrue(slugs(in: context).contains("beta"))
        guard case .synced = outcome else { return XCTFail("expected .synced, got \(outcome)") }
    }

    // MARK: - (c) conflict is safe: abort, no push, no rebuild

    func testConflictAbortsWithoutPushOrRebuild() throws {
        let git = StubGit()
        git.pullResult = .conflicted(["skills/x/SKILL.md"])
        let context = try makeContext()
        try seedDiskOnlySkill("gamma")
        let outcome = try makeEngine(git: git).sync(root: tempDir, message: "m", credential: nil, context: context)
        XCTAssertEqual(git.calls, ["commit", "pull", "abort"])
        XCTAssertFalse(git.calls.contains("push"), "must NOT push a conflicted pull")
        XCTAssertFalse(slugs(in: context).contains("gamma"), "must NOT rebuild on conflict")
        XCTAssertEqual(outcome, .conflicted(["skills/x/SKILL.md"]))
    }

    // MARK: - no remote → noRemote before any git op or write

    func testNoRemoteReturnsNoRemote() throws {
        let git = StubGit()
        git.remote = nil
        let context = try makeContext()
        let outcome = try makeEngine(git: git).sync(root: tempDir, message: "m", credential: nil, context: context)
        XCTAssertEqual(outcome, .noRemote)
        XCTAssertTrue(git.calls.isEmpty, "no git op before a remote is configured")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/manifest/manifest.yaml"))
    }

    func testSyncAbortsBeforeWriteWhenOnDiskManifestIsNewerSchema() throws {
        let git = StubGit()
        try FileManager.default.createDirectory(atPath: tempDir + "/manifest", withIntermediateDirectories: true)
        let manifestPath = tempDir + "/manifest/manifest.yaml"
        try "schema_version: 999\n".write(toFile: manifestPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try makeEngine(git: git).sync(root: tempDir, message: "m",
                                                           credential: nil, context: makeContext())) { error in
            guard case SyncError.storeUnreadable = error else { return XCTFail("expected storeUnreadable") }
        }
        XCTAssertTrue(git.calls.isEmpty, "must abort before commit/pull/push")
        XCTAssertTrue(try String(contentsOfFile: manifestPath, encoding: .utf8).contains("999"))
    }

    // MARK: - (d) gitattributes: union for lists, NOT for skill overlays

    func testGitAttributesUnionForListsNotSkills() throws {
        let git = StubGit()
        let context = try makeContext()
        _ = try makeEngine(git: git).sync(root: tempDir, message: "m", credential: nil, context: context)
        let attrs = try String(contentsOfFile: tempDir + "/.gitattributes", encoding: .utf8)
        XCTAssertTrue(attrs.contains("manifest/categories/*.yaml merge=union"))
        XCTAssertTrue(attrs.contains("manifest/projects.yaml merge=union"))
        XCTAssertFalse(attrs.contains("manifest/skills"), "skill overlays must NOT be union-merged")
        let ignore = try String(contentsOfFile: tempDir + "/.gitignore", encoding: .utf8)
        XCTAssertTrue(ignore.contains(".DS_Store"))
    }

    // MARK: - review: a snapshot (SwiftData fetch) failure aborts BEFORE any write/commit/push

    func testSnapshotFailureAbortsBeforeAnyGitOp() throws {
        let git = StubGit()
        let engine = SyncEngine(gitService: git, manifestService: ThrowingSnapshotManifest(),
                                storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
        let context = try makeContext()
        XCTAssertThrowsError(try engine.sync(root: tempDir, message: "m", credential: nil, context: context))
        XCTAssertTrue(git.calls.isEmpty, "a fetch failure must abort before commit/pull/push (no destructive write)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/manifest/manifest.yaml"))
    }

    // MARK: - review: a pulled unreadable (newer-schema) store does NOT push or report Synced

    func testUnreadablePulledStoreDoesNotPushOrReportSynced() throws {
        let git = StubGit()
        git.pullResult = .merged
        // Simulate the pull delivering a newer-schema manifest this build can't read.
        git.pullSideEffect = { root in
            try? "schema_version: 999\n".write(toFile: root + "/manifest/manifest.yaml",
                                               atomically: true, encoding: .utf8)
        }
        let context = try makeContext()
        XCTAssertThrowsError(try makeEngine(git: git).sync(root: tempDir, message: "m",
                                                           credential: nil, context: context)) { error in
            guard case SyncError.storeUnreadable = error else { return XCTFail("expected .storeUnreadable") }
        }
        XCTAssertFalse(git.calls.contains("push"), "must NOT push our older snapshot over an unreadable store")
    }
}

// MARK: - Real-git integration (union-merge over file:// clones)

extension SyncEngineTests {
    /// Bare-remote creation only (no commit → no identity needed). Production paths use GitService.
    @discardableResult
    private func rawGit(_ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        _ = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Seed the union attributes + ignore file exactly as `SyncEngine.ensureSyncAttributes` would.
    private func writeSyncControlFiles(at root: String) throws {
        let attrs = "manifest/categories/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"
        try attrs.write(toFile: root + "/.gitattributes", atomically: true, encoding: .utf8)
        try ".DS_Store\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
    }

    private func insertCategory(name: String, skillSlugs: [String], into context: ModelContext) throws {
        let category = PensieveCategory(name: name)
        category.skillSlugs = skillSlugs
        context.insert(category)
        try context.save()
    }

    // MARK: (e) two-clone category union: both skill slugs survive, deduped, both converge

    func testTwoCloneCategoryUnionMergeYieldsBothSlugs() throws {
        let git = TestPaths.git
        let manifest = ManifestService()
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), manifestService: manifest,
                                storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
        // Seed the remote with "Swift" (EMPTY slug list) + union attributes, so both clones share it as
        // the merge ANCESTOR (an add/add on a brand-new file conflicts; the seed makes the two additions
        // a modify/modify that unions).
        let remote = try seedRemote(git: git) { seed in
            let snapshot = ManifestSnapshot(schemaVersion: 1,
                                            categories: [CategoryRecord(name: "Swift", projectKeys: [], skillSlugs: [])],
                                            projects: [], skills: [])
            try manifest.write(snapshot, toRoot: seed)
        }
        let cloneA = tempDir + "/cloneA"
        let cloneB = tempDir + "/cloneB"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)

        let contextA = try makeContext()
        let contextB = try makeContext()
        try insertCategory(name: "Swift", skillSlugs: ["alpha"], into: contextA)
        try insertCategory(name: "Swift", skillSlugs: ["beta"], into: contextB)
        _ = try engine.sync(root: cloneA, message: "A", credential: nil, context: contextA)
        _ = try engine.sync(root: cloneB, message: "B", credential: nil, context: contextB)   // pull unions
        _ = try engine.sync(root: cloneA, message: "A2", credential: nil, context: contextA)   // A pulls union

        let readA = try manifest.read(fromRoot: cloneA).categories.first { $0.name == "Swift" }
        let readB = try manifest.read(fromRoot: cloneB).categories.first { $0.name == "Swift" }
        XCTAssertEqual(readA?.skillSlugs, ["alpha", "beta"], "clone A converges to both slugs deduped")
        XCTAssertEqual(readB?.skillSlugs, ["alpha", "beta"], "clone B converges to both slugs deduped")
    }

    // MARK: (f) two-clone project union: same identity_key, different names → deterministic winner

    func testTwoCloneProjectUnionConvergesToDeterministicWinner() throws {
        let git = TestPaths.git
        let manifest = ManifestService()
        let remote = try seedRemote(git: git) { seed in
            try manifest.write(ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: []),
                               toRoot: seed)
        }
        let cloneA = tempDir + "/pcloneA"
        let cloneB = tempDir + "/pcloneB"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)

        let key = "github.com/octocat/app"
        try writeProjects(manifest, root: cloneA,
                          [ProjectIdentityRecord(identityKey: key, identityKind: "remote", name: "App A")])
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "A registers"))
        try git.push(at: cloneA, credential: nil)

        try writeProjects(manifest, root: cloneB,
                          [ProjectIdentityRecord(identityKey: key, identityKind: "remote", name: "App B")])
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "B registers"))
        XCTAssertEqual(try git.pullRebase(at: cloneB, credential: nil), .merged)   // union
        try git.push(at: cloneB, credential: nil)
        XCTAssertEqual(try git.pullRebase(at: cloneA, credential: nil), .merged)   // A pulls union

        let winnerA = try manifest.read(fromRoot: cloneA).projects.filter { $0.identityKey == key }
        let winnerB = try manifest.read(fromRoot: cloneB).projects.filter { $0.identityKey == key }
        XCTAssertEqual(winnerA.count, 1, "the identity appears exactly ONCE after dedup")
        XCTAssertEqual(winnerB.count, 1)
        XCTAssertEqual(winnerA.first?.name, "App A", "winner = lexicographically-first (name, identity_kind)")
        XCTAssertEqual(winnerA, winnerB, "BOTH clones converge to the identical record")
    }

    private func writeProjects(_ manifest: ManifestService, root: String,
                               _ projects: [ProjectIdentityRecord]) throws {
        try manifest.write(ManifestSnapshot(schemaVersion: 1, categories: [], projects: projects, skills: []),
                           toRoot: root)
    }

    // MARK: (g) two-machine round-trip: a skill BODY + a category propagate A→B, an edit propagates B→A

    /// BETTER-1 payoff: real GitService/SyncEngine/StoreRebuildService over a bare `file://` remote.
    func testTwoMachineRoundTripSkillBodyAndCategoryPropagate() throws {
        let git = TestPaths.git
        let manifest = ManifestService()
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), manifestService: manifest,
                                storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
        let remote = try seedRemote(git: git) { seed in
            try manifest.write(ManifestSnapshot(schemaVersion: 1, categories: [], projects: [], skills: []),
                               toRoot: seed)
        }

        // A: fixed createdAt keeps overlays byte-identical; only SKILL.md body differs.
        let cloneA = tempDir + "/rtCloneA"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try writeSkillFile(root: cloneA, slug: "greeting", description: "greeting description", body: "Hello")
        let contextA = try makeContext()
        let skillA = Skill(name: "greeting", skillDescription: "greeting description", tags: [],
                           scope: .user, directoryName: "greeting", cursorConfig: nil, importedFrom: nil)
        skillA.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        skillA.updatedAt = skillA.createdAt
        contextA.insert(skillA)
        try insertCategory(name: "Comms", skillSlugs: ["greeting"], into: contextA)
        XCTAssertEqual(try engine.sync(root: cloneA, message: "A creates greeting + Comms",
                                       credential: nil, context: contextA), .synced(pushed: true, warnings: []))

        // B: clone + rebuild → the body file AND the category rule materialized.
        let cloneB = tempDir + "/rtCloneB"
        try git.clone(remote: remote, into: cloneB, credential: nil)
        let contextB = try makeContext()
        _ = StoreRebuildService().rebuild(fromRoot: cloneB, context: contextB)
        XCTAssertEqual(try String(contentsOfFile: cloneB + "/skills/greeting/SKILL.md", encoding: .utf8)
            .contains("Hello"), true, "B's clone has the synced SKILL.md body on disk")
        let bSkill = try XCTUnwrap(fetchSkill("greeting", in: contextB), "B rebuilt the skill row")
        XCTAssertEqual(bSkill.skillDescription, "greeting description")
        let bCat = try XCTUnwrap(fetchCategory("Comms", in: contextB), "B rebuilt the category rule")
        XCTAssertEqual(bCat.skillSlugs, ["greeting"], "the category→skill assignment propagated")

        // B: edit the skill body/description, then sync (push).
        try writeSkillFile(root: cloneB, slug: "greeting", description: "EDITED description", body: "Hi there")
        _ = StoreRebuildService().rebuild(fromRoot: cloneB, context: contextB)   // pick up the edit
        _ = try engine.sync(root: cloneB, message: "B edits greeting", credential: nil, context: contextB)

        // A: pull → the edit propagated to A's store AND A's disk.
        _ = try engine.sync(root: cloneA, message: "A pulls B's edit", credential: nil, context: contextA)
        XCTAssertTrue(try String(contentsOfFile: cloneA + "/skills/greeting/SKILL.md", encoding: .utf8)
            .contains("Hi there"), "B's body edit reached A's disk")
        let aSkill = try XCTUnwrap(fetchSkill("greeting", in: contextA))
        XCTAssertEqual(aSkill.skillDescription, "EDITED description", "B's edit propagated into A's store")
    }

    /// Write a self-describing `SKILL.md` (canonical frontmatter + body) under `root/skills/<slug>/`.
    private func writeSkillFile(root: String, slug: String, description: String, body: String) throws {
        let dir = root + "/skills/" + slug
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let markdown = "---\nname: \(slug)\ndescription: \(description)\n---\n\n\(body)\n"
        try markdown.write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
    }
    private func fetchSkill(_ slug: String, in context: ModelContext) -> Skill? {
        ((try? context.fetch(FetchDescriptor<Skill>())) ?? []).first { $0.directoryName == slug }
    }
    private func fetchCategory(_ name: String, in context: ModelContext) -> PensieveCategory? {
        ((try? context.fetch(FetchDescriptor<PensieveCategory>())) ?? []).first { $0.name == name }
    }

    /// Create a bare remote with an initial commit on `main`, so clones share a mergeable ancestor.
    private func seedRemote(git: GitService, writeSeed: (String) throws -> Void) throws -> String {
        let remotePath = tempDir + "/remote-\(UUID().uuidString).git"
        XCTAssertEqual(try rawGit(["init", "--bare", remotePath]), 0, "bare init failed")
        let remote = "file://" + remotePath
        let seed = tempDir + "/seed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try git.initRepository(at: seed)
        try git.setRemote(remote, at: seed)
        try writeSeed(seed)
        try writeSyncControlFiles(at: seed)
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        return remote
    }
}
