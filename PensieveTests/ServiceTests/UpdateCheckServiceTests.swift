import SwiftData
import XCTest
@testable import Pensieve
@MainActor
final class UpdateCheckServiceTests: XCTestCase {
    var tempDir: String!
    var fileService: FileService!
    var git: RecordingUpdateGitService!
    var container: ModelContainer!
    var context: ModelContext!
    let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveUpdateCheckServiceTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        git = RecordingUpdateGitService()
        container = try ModelContainer(
            for: Skill.self, RepoUpdateCursor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testBatchesByRepo() throws {
        for repoIndex in 1 ... 3 {
            let repo = "fixture://repo-\(repoIndex)"
            git.heads[repo] = "head-\(repoIndex)"
            for skillIndex in 1 ... 4 {
                let path = "skills/r\(repoIndex)-s\(skillIndex)"
                git.trees[path] = "tree-\(path)"
                insertSkill(
                    slug: "r\(repoIndex)-s\(skillIndex)",
                    repo: repo,
                    path: path,
                    installedTree: "old-tree"
                )
            }
        }
        try context.save()

        try makeService().checkAll(context: context)

        XCTAssertEqual(git.remoteHeadCalls.count, 3)
        XCTAssertEqual(git.cloneCalls.count, 3)
        XCTAssertEqual(git.treeHashCalls.count, 12)
    }

    func testUnmovedHeadShortCircuitsPerSkill() throws {
        let skill = insertSkill(slug: "one", repo: "fixture://repo", path: "skills/one")
        skill.lastCheckedHead = "same-head"
        skill.updateAvailable = true
        skill.upstreamCommit = "same-head"
        git.heads["fixture://repo"] = "same-head"
        try context.save()

        try makeService().checkAll(context: context)

        let persisted = try persistedSkill(id: skill.id)
        XCTAssertEqual(git.remoteHeadCalls.count, 1)
        XCTAssertTrue(git.cloneCalls.isEmpty)
        XCTAssertTrue(persisted.updateAvailable)
        XCTAssertEqual(persisted.upstreamCommit, "same-head")
        XCTAssertEqual(persisted.lastCheckedAt, checkedAt)
        XCTAssertNil(persisted.checkError)
    }

    func testMovedHeadSetsChangedTreeAndPinsCommitButClearsUnchangedTree() throws {
        let changed = insertSkill(
            slug: "changed",
            repo: "fixture://repo",
            path: "skills/changed",
            installedTree: "installed-changed"
        )
        let unchanged = insertSkill(
            slug: "unchanged",
            repo: "fixture://repo",
            path: "skills/unchanged",
            installedTree: "same-tree"
        )
        git.heads["fixture://repo"] = "fresh-head"
        git.trees["skills/changed"] = "fresh-tree"
        git.trees["skills/unchanged"] = "same-tree"
        try context.save()

        try makeService().checkAll(context: context)

        let persistedChanged = try persistedSkill(id: changed.id)
        let persistedUnchanged = try persistedSkill(id: unchanged.id)
        XCTAssertTrue(persistedChanged.updateAvailable)
        XCTAssertEqual(persistedChanged.upstreamTree, "fresh-tree")
        XCTAssertEqual(persistedChanged.upstreamCommit, "fresh-head")
        XCTAssertEqual(persistedChanged.upstreamCommitDate, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertFalse(persistedUnchanged.updateAvailable)
        XCTAssertEqual(persistedUnchanged.upstreamTree, "same-tree")
        XCTAssertNil(persistedUnchanged.upstreamCommit)
        XCTAssertNil(persistedUnchanged.upstreamCommitDate)
    }

    func testCursorCurrentStillEvaluatesNewlyAdoptedSkillFromSameRepo() throws {
        context.insert(RepoUpdateCursor(
            repo: "fixture://repo",
            ref: "main",
            lastSeenHead: "fresh-head",
            lastCheckedAt: checkedAt.addingTimeInterval(-60)
        ))
        let adopted = insertSkill(
            slug: "adopted",
            repo: "fixture://repo",
            path: "skills/adopted",
            installedTree: "stale-tree"
        )
        git.heads["fixture://repo"] = "fresh-head"
        git.trees["skills/adopted"] = "new-tree"
        try context.save()

        try makeService().checkAll(context: context)

        let persisted = try persistedSkill(id: adopted.id)
        XCTAssertEqual(git.cloneCalls.count, 1)
        XCTAssertEqual(persisted.lastCheckedHead, "fresh-head")
        XCTAssertTrue(persisted.updateAvailable)
    }

    func testDeadRemoteRecordsPerSkillErrorWithoutResettingFlags() throws {
        let skill = insertSkill(slug: "dead", repo: "fixture://dead", path: "skills/dead")
        skill.updateAvailable = true
        skill.upstreamCommit = "previous-pin"
        git.failingRemotes.insert("fixture://dead")
        try context.save()

        try makeService().checkAll(context: context)

        let persisted = try persistedSkill(id: skill.id)
        XCTAssertNotNil(persisted.checkError)
        XCTAssertTrue(persisted.updateAvailable)
        XCTAssertEqual(persisted.upstreamCommit, "previous-pin")
        XCTAssertNil(persisted.lastCheckedHead)
    }

    func testStaleResultDiscardedWhenSkillChangedMidCheck() throws {
        let skill = insertSkill(
            slug: "stale",
            repo: "fixture://repo",
            path: "skills/stale",
            installedTree: "old-tree"
        )
        git.heads["fixture://repo"] = "fresh-head"
        git.trees["skills/stale"] = "fresh-tree"
        let skillID = skill.id
        git.onTreeHash = { [container] _ in
            let syncContext = ModelContext(try XCTUnwrap(container))
            let syncSkill = try XCTUnwrap(
                try syncContext.fetch(FetchDescriptor<Skill>()).first { $0.id == skillID }
            )
            var replacement = try XCTUnwrap(syncSkill.installedOrigin)
            replacement.installedTree = "sync-replaced-tree"
            syncSkill.installedOrigin = replacement
            try syncContext.save()
        }
        try context.save()

        try makeService().checkAll(context: context)

        let persisted = try persistedSkill(id: skill.id)
        XCTAssertEqual(persisted.installedOrigin?.installedTree, "sync-replaced-tree")
        XCTAssertFalse(persisted.updateAvailable)
        XCTAssertNil(persisted.lastCheckedHead)
        XCTAssertNil(persisted.upstreamCommit)
        XCTAssertNil(persisted.checkError)
    }

    func testDeletedSkillDiscardsResult() throws {
        let skill = insertSkill(slug: "deleted", repo: "fixture://repo", path: "skills/deleted")
        git.heads["fixture://repo"] = "fresh-head"
        git.trees["skills/deleted"] = "fresh-tree"
        git.onTreeHash = { [context] _ in
            context?.delete(skill)
            try context?.save()
        }
        try context.save()

        try makeService().checkAll(context: context)

        let verificationContext = ModelContext(container)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<Skill>()).isEmpty)
    }

    func testEmptyOriginSkillIsSkippedByCheckAndDrift() throws {
        let skill = insertSkill(slug: "empty", repo: "fixture://repo", path: "skills/empty")
        skill.installedOrigin = .empty
        try context.save()
        let service = makeService()

        try service.checkAll(context: context)

        let persisted = try persistedSkill(id: skill.id)
        XCTAssertNil(persisted.checkError)
        XCTAssertNil(persisted.lastCheckedAt)
        XCTAssertNil(persisted.lastCheckedHead)
        XCTAssertTrue(git.remoteHeadCalls.isEmpty)
        XCTAssertTrue(git.cloneCalls.isEmpty)
        XCTAssertTrue(git.treeHashCalls.isEmpty)
        XCTAssertFalse(try service.driftedLocally(skill: persisted))
    }

    func testStoredUnsafeRemotesAreRefusedBeforeGitWithDefaultPolicy() throws {
        let helper = insertSkill(slug: "helper", repo: "ext::sh -c touch /tmp/pwned", path: "")
        let attacker = insertSkill(
            slug: "attacker",
            repo: "https://attacker.example/owner/repo",
            path: "skills/attacker"
        )
        try context.save()
        let service = UpdateCheckService(
            gitService: git,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: tempDir + "/scratch",
            storeRoot: tempDir + "/store",
            now: { self.checkedAt }
        )

        try service.checkAll(context: context)

        XCTAssertTrue(git.remoteHeadCalls.isEmpty)
        XCTAssertTrue(git.cloneCalls.isEmpty)
        XCTAssertNotNil(try persistedSkill(id: helper.id).checkError)
        XCTAssertNotNil(try persistedSkill(id: attacker.id).checkError)
    }

    func testRepositoryFailuresUseInstallFacingErrorMessages() throws {
        let auth = insertSkill(slug: "auth", repo: "fixture://auth", path: "skills/auth")
        let missing = insertSkill(slug: "missing", repo: "fixture://missing", path: "skills/missing")
        git.remoteHeadErrors["fixture://auth"] = .authenticationFailed(
            remote: "fixture://auth",
            detail: "HTTP 403"
        )
        git.remoteHeadErrors["fixture://missing"] = .commandFailed(
            args: ["ls-remote"],
            exitCode: 128,
            stderr: "remote: Repository not found. error: 404"
        )
        try context.save()

        try makeService().checkAll(context: context)

        XCTAssertEqual(
            try persistedSkill(id: auth.id).checkError,
            SkillInstallError.authenticationFailed.localizedDescription
        )
        XCTAssertEqual(
            try persistedSkill(id: missing.id).checkError,
            SkillInstallError.repositoryNotFound.localizedDescription
        )
    }

    func testRemoteHeadUsesCredentialIsolationArguments() throws {
        let productionGit = GitService(fileService: fileService)
        XCTAssertThrowsError(
            try productionGit.remoteHead(
                remote: "file:///definitely-missing-pensieve-update-repository",
                ref: "main",
                credential: nil
            )
        ) { error in
            guard case let GitError.commandFailed(args, _, _, _) = error else {
                return XCTFail("expected command failure, got \(error)")
            }
            XCTAssertEqual(
                Array(args.prefix(5)),
                ["-c", "credential.helper=", "ls-remote", "--",
                 "file:///definitely-missing-pensieve-update-repository"]
            )
        }
    }
}

extension UpdateCheckServiceTests {
    func testAnUnreachableRemoteReadsAsNetworkUnavailable() throws {
        let offline = insertSkill(slug: "offline", repo: "fixture://offline", path: "skills/offline")
        let nodns = insertSkill(slug: "nodns", repo: "fixture://nodns", path: "skills/nodns")
        let connect = "fatal: unable to access 'https://github.com/o/r.git/': Failed to connect to github.com "
            + "port 443 after 34 ms: Couldn't connect to server"
        let dns = "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com"
        git.remoteHeadErrors["fixture://offline"] = .commandFailed(args: ["ls-remote"], exitCode: 128, stderr: connect)
        git.remoteHeadErrors["fixture://nodns"] = .commandFailed(args: ["ls-remote"], exitCode: 128, stderr: dns)
        try context.save()
        let report = try makeService().checkAll(context: context)
        XCTAssertFalse(report.reachedRemote)
        XCTAssertEqual(report.environmentError?.localizedDescription, SkillInstallError.networkUnavailable.localizedDescription)
        XCTAssertNil(try persistedSkill(id: offline.id).checkError)
        XCTAssertNil(try persistedSkill(id: nodns.id).checkError)
        XCTAssertNil(try persistedSkill(id: offline.id).lastCheckedAt)
        XCTAssertNil(try persistedSkill(id: nodns.id).lastCheckedAt)
    }

    @discardableResult
    func insertSkill(slug: String, repo: String, path: String,
                     installedTree: String = "installed-tree") -> Skill {
        let skill = Skill(name: slug, skillDescription: slug, directoryName: slug)
        skill.installedOrigin = InstalledOrigin(
            repo: repo,
            path: path,
            ref: "main",
            installedCommit: "installed-head",
            installedTree: installedTree,
            contentHash: "sha256:installed",
            installedAt: checkedAt.addingTimeInterval(-1_000),
            updatedAt: checkedAt.addingTimeInterval(-1_000)
        )
        context.insert(skill)
        return skill
    }

    func makeService(credentials: CredentialStoreProtocol = InMemoryCredentialStore())
        -> UpdateCheckService {
        UpdateCheckService(
            gitService: git,
            credentialStore: credentials,
            fileService: fileService,
            scratchRoot: tempDir + "/scratch",
            storeRoot: tempDir + "/store",
            now: { self.checkedAt },
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
    }

    var fixtureRemoteValidator: InstallRemotePolicy.Validator {
        { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
    }

    func persistedSkill(id: UUID) throws -> Skill {
        let verificationContext = ModelContext(container)
        return try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Skill>()).first { $0.id == id }
        )
    }
}
