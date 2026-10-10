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
        try NativeTestWork.run { [self] in
            tempDir = TestTemporaryDirectory.path + "PensieveSyncEngineTests-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws {
        try NativeTestWork.run { [self] in
            if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
                try FileManager.default.removeItem(atPath: tempDir)
            }
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

        func performRemoteURL(at path: String) -> String? { remote }
        func performInitRepository(at path: String) throws {}
        func performSetRemote(_ url: String, at path: String) throws {}
        func performRemoveRemote(at path: String) throws {}
        func performConfiguredRemoteURL(at path: String) throws -> String? { nil }
        func performClone(remote: String, into path: String, credential: GitCredential?) throws {}
        func performRemoteHasCommits(remote: String, credential: GitCredential?) -> Bool { true }
        func performHasLocalBranches(at path: String) throws -> Bool { try hasLocalBranchesResult.get() }
        @discardableResult
        func performStageAllAndCommit(at path: String, message: String) throws -> Bool {
            calls.append("commit")
            return true
        }

        func performPreflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
        func performPullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
            try pullRebase(at: path, credential: nil)
        }
        func performPullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
            calls.append("pull")
            if let pullError { throw pullError }
            pullSideEffect?(path)
            return pullResult
        }

        func performPush(at path: String, credential: GitCredential?) throws { calls.append("push") }
        func performAbortRebase(at path: String) throws { calls.append("abort") }
        func performConflictedFiles(at path: String) -> [String] { [] }
        func performBlob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
        func performContinueRebase(at path: String) throws -> PullResult { .upToDate }
        func performSkipRebase(at path: String) throws -> PullResult { .upToDate }
        func performStagePath(_ path: String, at root: String) throws {}
        func performHasCommitsToPush(at path: String) -> Bool { false }
        func performCollapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                           fetchedRevision: FetchedStoreRevision?) throws -> Bool { false }
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
        try NativeTestWork.run { [self] in
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
    }

    func testUpToDateStillRebuildsAndPushes() throws {
        try NativeTestWork.run { [self] in
            let git = StubGit()
            git.pullResult = .upToDate
            let context = try makeContext()
            try seedDiskOnlySkill("beta")
            let outcome = try makeEngine(git: git).sync(root: tempDir, message: "m", credential: nil, context: context)
            XCTAssertTrue(git.calls.contains("push"))
            XCTAssertTrue(slugs(in: context).contains("beta"))
            guard case .synced = outcome else { return XCTFail("expected .synced, got \(outcome)") }
        }
    }

    // MARK: - (c) conflict is safe: abort, no push, no rebuild

    func testConflictAbortsWithoutPushOrRebuild() throws {
        try NativeTestWork.run { [self] in
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
    }

    // MARK: - no remote → noRemote before any git op or write

    func testNoRemoteReturnsNoRemote() throws {
        try NativeTestWork.run { [self] in
            let git = StubGit()
            git.remote = nil
            let context = try makeContext()
            let outcome = try makeEngine(git: git).sync(root: tempDir, message: "m", credential: nil, context: context)
            XCTAssertEqual(outcome, .noRemote)
            XCTAssertTrue(git.calls.isEmpty, "no git op before a remote is configured")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/manifest/manifest.yaml"))
        }
    }

    func testSyncAbortsBeforeWriteWhenOnDiskManifestIsNewerSchema() throws {
        try NativeTestWork.run { [self] in
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
    }

    // MARK: - (d) gitattributes: union for lists, NOT for skill overlays

    func testGitAttributesUnionForListsNotSkills() throws {
        try NativeTestWork.run { [self] in
            let git = StubGit()
            let context = try makeContext()
            _ = try makeEngine(git: git).sync(root: tempDir, message: "m", credential: nil, context: context)
            let attrs = try String(contentsOfFile: tempDir + "/.gitattributes", encoding: .utf8)
            XCTAssertTrue(attrs.contains("manifest/categories/*.yaml merge=union"))
            XCTAssertTrue(attrs.contains("manifest/projects.yaml merge=union"))
            XCTAssertFalse(attrs.contains("manifest/scenarios/"))
            XCTAssertFalse(attrs.contains("manifest/skills"), "skill overlays must NOT be union-merged")
            let ignore = try String(contentsOfFile: tempDir + "/.gitignore", encoding: .utf8)
            XCTAssertTrue(ignore.contains(".DS_Store"))
        }
    }

    // MARK: - review: a snapshot (SwiftData fetch) failure aborts BEFORE any write/commit/push

    func testSnapshotFailureAbortsBeforeAnyGitOp() throws {
        try NativeTestWork.run { [self] in
            let git = StubGit()
            let engine = SyncEngine(gitService: git, manifestService: ThrowingSnapshotManifest(),
                                    storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
            let context = try makeContext()
            XCTAssertThrowsError(try engine.sync(root: tempDir, message: "m", credential: nil, context: context))
            XCTAssertTrue(git.calls.isEmpty, "a fetch failure must abort before commit/pull/push (no destructive write)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir + "/manifest/manifest.yaml"))
        }
    }

    // MARK: - review: a pulled unreadable (newer-schema) store does NOT push or report Synced

    func testUnreadablePulledStoreDoesNotPushOrReportSynced() throws {
        try NativeTestWork.run { [self] in
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
}
