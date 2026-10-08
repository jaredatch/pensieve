import XCTest
import SwiftData
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

/// PLAN-09 / 09.2 — reproduce-on-demand conflict inspection/resolution over real file:// clones.
final class SyncConflictResolutionTests: XCTestCase {
    private var tempDir: String!; private var lockPath: String { tempDir + "-sync.lock" }

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveSyncConflictTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testInspectLabelsThisAndOtherAndRestoresCleanRestingState() throws {
        let fixture = try makeBodyConflict()
        let inspection = try fixture.engine.inspectConflicts(root: fixture.cloneB, credential: nil,
                                                             context: fixture.contextB)
        guard case let .conflicts(set) = inspection else { return XCTFail("expected conflicts") }
        let item = try XCTUnwrap(set.items.first)
        XCTAssertEqual(set.items.count, 1)
        XCTAssertEqual(item.kind, .body)
        XCTAssertEqual(item.path, Self.skillPath)
        XCTAssertEqual(item.thisMachine, fixture.thisText)
        XCTAssertEqual(item.otherMachine, fixture.otherText)
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.cloneB))
        XCTAssertEqual(try rawGit(["-C", fixture.cloneB, "status", "--porcelain"]), "")
    }

    func testResolveOtherMachineAppliesPropagatesAndReportsNoPush() throws {
        let fixture = try makeBodyConflict()
        let item = try inspectedItem(in: fixture)
        let outcome = try fixture.engine.resolveConflicts(
            root: fixture.cloneB,
            picks: [item.path: ResolutionPick(side: .otherMachine, expectedThis: item.thisMachine,
                                              expectedOther: item.otherMachine)],
            credential: nil,
            context: fixture.contextB
        )
        XCTAssertEqual(outcome, .synced(pushed: false, warnings: []))
        _ = try fixture.engine.sync(root: fixture.cloneA, message: "A pulls resolved other",
                                    credential: nil, context: fixture.contextA)
        XCTAssertEqual(try readSkill(root: fixture.cloneA), fixture.otherText)
        XCTAssertEqual(try readSkill(root: fixture.cloneB), fixture.otherText)
    }

    func testResolveThisMachineAppliesAndPropagatesOppositeChoice() throws {
        let fixture = try makeBodyConflict()
        let item = try inspectedItem(in: fixture)
        let outcome = try fixture.engine.resolveConflicts(
            root: fixture.cloneB,
            picks: [item.path: ResolutionPick(side: .thisMachine, expectedThis: item.thisMachine,
                                              expectedOther: item.otherMachine)],
            credential: nil,
            context: fixture.contextB
        )
        XCTAssertEqual(outcome, .synced(pushed: true, warnings: []))
        _ = try fixture.engine.sync(root: fixture.cloneA, message: "A pulls resolved this",
                                    credential: nil, context: fixture.contextA)
        XCTAssertEqual(try readSkill(root: fixture.cloneA), fixture.thisText)
        XCTAssertEqual(try readSkill(root: fixture.cloneB), fixture.thisText)
    }

    func testOmittedPathThrowsConflictsChangedAndLeavesRemoteHeadUnmoved() throws {
        let fixture = try makeBodyConflict()
        let before = try remoteHead(fixture.remotePath)
        XCTAssertThrowsError(try fixture.engine.resolveConflicts(root: fixture.cloneB, picks: [:],
                                                                 credential: nil,
                                                                 context: fixture.contextB)) { error in
            XCTAssertEqual(error as? SyncError, .conflictsChanged)
        }
        XCTAssertEqual(try remoteHead(fixture.remotePath), before)
    }

    func testContentDriftThrowsConflictsChangedAndLeavesRemoteHeadUnmoved() throws {
        let fixture = try makeBodyConflict()
        let stale = try inspectedItem(in: fixture)
        let driftText = try writeSkillFile(root: fixture.cloneA, body: "Remote drift")
        _ = try fixture.engine.sync(root: fixture.cloneA, message: "A drifts same path",
                                    credential: nil, context: fixture.contextA)
        let driftHead = try remoteHead(fixture.remotePath)
        XCTAssertEqual(try readSkill(root: fixture.cloneA), driftText)
        XCTAssertThrowsError(try fixture.engine.resolveConflicts(
            root: fixture.cloneB,
            picks: [stale.path: ResolutionPick(side: .thisMachine, expectedThis: stale.thisMachine,
                                               expectedOther: stale.otherMachine)],
            credential: nil,
            context: fixture.contextB
        )) { error in
            XCTAssertEqual(error as? SyncError, .conflictsChanged)
        }
        XCTAssertEqual(try remoteHead(fixture.remotePath), driftHead)
    }

    func testMultiCommitLocalDivergenceResolvesInOneRound() throws {
        let fixture = try makeBodyConflict(thisBody: "This body one")
        XCTAssertTrue(try fixture.git.stageAllAndCommit(at: fixture.cloneB, message: "B one"))
        let finalThis = try writeSkillFile(root: fixture.cloneB, body: "This body final")
        XCTAssertTrue(try fixture.git.stageAllAndCommit(at: fixture.cloneB, message: "B two"))
        let item = try inspectedItem(in: fixture)
        XCTAssertEqual(item.thisMachine, finalThis)
        let outcome = try fixture.engine.resolveConflicts(
            root: fixture.cloneB,
            picks: [item.path: ResolutionPick(side: .thisMachine, expectedThis: item.thisMachine,
                                              expectedOther: item.otherMachine)],
            credential: nil,
            context: fixture.contextB
        )
        XCTAssertEqual(outcome, .synced(pushed: true, warnings: []))
        _ = try fixture.engine.sync(root: fixture.cloneA, message: "A pulls collapsed resolution",
                                    credential: nil, context: fixture.contextA)
        XCTAssertEqual(try readSkill(root: fixture.cloneA), finalThis)
        XCTAssertEqual(try readSkill(root: fixture.cloneB), finalThis)
    }

    func testInspectClearedWhenLocalPatchAlreadyResolvedUpstream() throws {
        let fixture = try makeBodyConflict(thisBody: "Other machine body", otherBody: "Other machine body")
        let inspection = try fixture.engine.inspectConflicts(root: fixture.cloneB, credential: nil,
                                                             context: fixture.contextB)
        guard case let .cleared(outcome) = inspection else { return XCTFail("expected cleared") }
        XCTAssertEqual(outcome, .synced(pushed: false, warnings: []))
        XCTAssertEqual(try readSkill(root: fixture.cloneB), fixture.otherText)
    }

    func testPathSafetyRejectsSymlinkEscapesSiblingPrefixAndControlComponent() throws {
        let root = tempDir + "/safeRoot"
        let outside = tempDir + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/escape", withDestinationPath: outside)
        try assertUnsafePath("escape/out.txt", root: root, escapedPath: outside + "/out.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/leaf", withDestinationPath: outside + "/leaf.txt")
        try assertUnsafePath("leaf", root: root, escapedPath: outside + "/leaf.txt")
        let evil = root + "-evil"
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/decoy", withDestinationPath: evil)
        try assertUnsafePath("decoy/x", root: root, escapedPath: evil + "/x")
        // C7: an IN-ROOT symlinked slug DIRECTORY must also be rejected — validatedWorktreePath previously
        // allowed in-root symlinks, which would let the resolve write redirect through the link target
        // inside the store. Reject before any write.
        let inRootDecoy = root + "/skills-decoy"
        try FileManager.default.createDirectory(atPath: inRootDecoy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/skills/victim", withDestinationPath: inRootDecoy)
        try assertUnsafePath("skills/victim/SKILL.md", root: root, escapedPath: inRootDecoy + "/SKILL.md")
        try assertUnsafePath("skills/\u{85}/SKILL.md", root: root, escapedPath: nil)
        // Lexical guards (absolute / .. / . / empty component) — each must reject before any write.
        try assertUnsafePath("../outside/direct.txt", root: root, escapedPath: outside + "/direct.txt")
        try assertUnsafePath("/absolute.txt", root: root, escapedPath: nil)
        try assertUnsafePath("skills/./SKILL.md", root: root, escapedPath: root + "/skills/SKILL.md")
        try assertUnsafePath("skills//SKILL.md", root: root, escapedPath: root + "/skills/SKILL.md")
    }

    /// Inspection aborts a started rebase on either a git rejection or a local pipe failure.
    @MainActor
    func testInspectConflictsAbortsWhenPullRebaseThrows() async throws {
        let root = tempDir + "/inspectAbort"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let failures: [(GitError, String)] = [
            (.commandFailed(args: ["rebase"], exitCode: 1, stderr: "boom"), "git rebase failed (exit 1): boom"),
            (.outputReadFailed(detail: "Authentication failed; CONFLICT; Xcode license not accepted"),
             "Pensieve couldn’t read git’s output: Authentication failed; CONFLICT; Xcode license not accepted")
        ]
        for (failure, expectedMessage) in failures {
            let git = StubGit(conflictPath: "skills/x/SKILL.md", pullError: failure)
            let engine = SyncEngine(gitService: git, manifestService: ManifestService(),
                                    storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
            let model = ConflictResolutionModel(engine: engine, git: git, credentials: InMemoryCredentialStore(), root: root)
            await model.loadAndReport(context: try makeContext())
            guard case let .error(message) = model.phase else { return XCTFail("must report failure, never conflicts") }
            XCTAssertEqual(message, expectedMessage)
            XCTAssertEqual(git.abortsAfterPull, 1, "inspect must abort the rebase when pullRebase throws")
        }
    }
}
// MARK: - Conflict fixtures

extension SyncConflictResolutionTests {
    private static let slug = "conflict"
    private static let skillPath = "skills/conflict/SKILL.md"

    private struct BodyConflictFixture {
        let git: GitService
        let engine: SyncEngine
        let remotePath: String
        let cloneA: String
        let cloneB: String
        let contextA: ModelContext
        let contextB: ModelContext
        let thisText: String
        let otherText: String
    }

    private func makeBodyConflict(thisBody: String = "This machine body",
                                  otherBody: String = "Other machine body") throws -> BodyConflictFixture {
        let git = TestPaths.git
        let manifest = ManifestService()
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), manifestService: manifest,
                                storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
        let remotePath = try seedRemote(git: git, manifest: manifest)
        let remote = "file://" + remotePath
        let cloneA = tempDir + "/cloneA-\(UUID().uuidString)"
        let cloneB = tempDir + "/cloneB-\(UUID().uuidString)"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)
        let contextA = try makeContext()
        let contextB = try makeContext()
        try insertSkill(in: contextA)
        try insertSkill(in: contextB)
        let otherText = try writeSkillFile(root: cloneA, body: otherBody)
        XCTAssertEqual(try engine.sync(root: cloneA, message: "A edits", credential: nil, context: contextA),
                       .synced(pushed: true, warnings: []))
        let thisText = try writeSkillFile(root: cloneB, body: thisBody)
        return BodyConflictFixture(git: git, engine: engine, remotePath: remotePath,
                                   cloneA: cloneA, cloneB: cloneB, contextA: contextA, contextB: contextB,
                                   thisText: thisText, otherText: otherText)
    }

    private func inspectedItem(in fixture: BodyConflictFixture) throws -> ConflictItem {
        let inspection = try fixture.engine.inspectConflicts(root: fixture.cloneB, credential: nil,
                                                             context: fixture.contextB)
        guard case let .conflicts(set) = inspection else { throw TestFailure("expected conflicts") }
        return try XCTUnwrap(set.items.first)
    }

    private func seedRemote(git: GitService, manifest: ManifestService) throws -> String {
        let remotePath = tempDir + "/remote-\(UUID().uuidString).git"
        _ = try rawGit(["init", "--bare", remotePath])
        let seed = tempDir + "/seed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try git.initRepository(at: seed)
        try git.setRemote("file://" + remotePath, at: seed)
        _ = try writeSkillFile(root: seed, body: "Base body")
        try manifest.write(seedSnapshot(), toRoot: seed)
        try writeSyncControlFiles(at: seed)
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        return remotePath
    }

    private func seedSnapshot() -> ManifestSnapshot {
        ManifestSnapshot(
            schemaVersion: 1,
            categories: [],

            projects: [],
            skills: [Self.overlay()]
        )
    }

    private static func overlay() -> SkillOverlay {
        SkillOverlay(slug: slug, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                     scope: .user, tags: [], cursor: nil, agents: [], origin: .authored)
    }

    private func insertSkill(in context: ModelContext) throws {
        let skill = Skill(name: Self.slug, skillDescription: "Conflict description", tags: [],
                          scope: .user, directoryName: Self.slug, cursorConfig: nil, importedFrom: nil)
        skill.createdAt = Self.overlay().createdAt
        skill.updatedAt = skill.createdAt
        context.insert(skill)
        try context.save()
    }
}
// MARK: - Path-safety stubs
extension SyncConflictResolutionTests {
    private final class StubGit: GitServiceProtocol {
        let conflictPath: String
        let pullError: Error?
        private(set) var stagedPaths: [String] = []
        private(set) var pullAttempted = false
        private(set) var abortsAfterPull = 0

        init(conflictPath: String, pullError: Error? = nil) {
            self.conflictPath = conflictPath
            self.pullError = pullError
        }

        func remoteURL(at path: String) -> String? { "https://fixture.test/x.git" }
        func initRepository(at path: String) throws {}
        func setRemote(_ url: String, at path: String) throws {}
        func removeRemote(at path: String) throws {}
        func configuredRemoteURL(at path: String) throws -> String? { nil }
        func clone(remote: String, into path: String, credential: GitCredential?) throws {}
        func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { true }
        @discardableResult
        func stageAllAndCommit(at path: String, message: String) throws -> Bool { true }
        func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
            pullAttempted = true
            if let pullError { throw pullError }
            return .conflicted([conflictPath])
        }
        func push(at path: String, credential: GitCredential?) throws {}
        func abortRebase(at path: String) throws { if pullAttempted { abortsAfterPull += 1 } }
        func conflictedFiles(at path: String) -> [String] { [conflictPath] }
        func blob(atStage stage: Int, path: String, in workingDir: String) -> String? {
            stage == 3 ? "this" : "other"
        }
        func continueRebase(at path: String) throws -> PullResult { .merged }
        func skipRebase(at path: String) throws -> PullResult { .merged }
        func stagePath(_ path: String, at root: String) throws { stagedPaths.append(path) }
        func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?) throws -> Bool {
            true
        }
        func hasCommitsToPush(at path: String) -> Bool { false }
    }

    private func assertUnsafePath(_ path: String, root: String, escapedPath: String?,
                                  line: UInt = #line) throws {
        let git = StubGit(conflictPath: path)
        let engine = SyncEngine(gitService: git, manifestService: ManifestService(),
                                storeRebuildService: StoreRebuildService(), fileService: FileService(), lockPath: lockPath)
        let pick = ResolutionPick(side: .thisMachine, expectedThis: "this", expectedOther: "other")
        XCTAssertThrowsError(try engine.resolveConflicts(root: root, picks: [path: pick],
                                                         credential: nil, context: makeContext()),
                             line: line) { error in
            XCTAssertEqual(error as? SyncError, .conflictsChanged, line: line)
        }
        XCTAssertTrue(git.stagedPaths.isEmpty, "unsafe paths must fail before git add", line: line)
        if let escapedPath {
            XCTAssertFalse(FileManager.default.fileExists(atPath: escapedPath), line: line)
        }
    }
}

// MARK: - Shared helpers

extension SyncConflictResolutionTests {
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func rawGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(bytes: outData, encoding: .utf8) ?? ""
        let stderr = String(bytes: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TestFailure("git \(args.joined(separator: " ")) failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remoteHead(_ remotePath: String) throws -> String {
        try rawGit(["--git-dir", remotePath, "rev-parse", "refs/heads/main"])
    }

    @discardableResult
    private func writeSkillFile(root: String, body: String) throws -> String {
        let dir = root + "/skills/" + Self.slug
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: \(Self.slug)
        description: Conflict description
        ---

        \(body)
        """
        try (markdown + "\n").write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
        return markdown + "\n"
    }

    private func readSkill(root: String) throws -> String {
        try String(contentsOfFile: root + "/" + Self.skillPath, encoding: .utf8)
    }
}
