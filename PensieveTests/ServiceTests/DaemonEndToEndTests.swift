import SwiftData
import XCTest
@testable import Pensieve

private typealias PensieveCategory = Pensieve.Category

/// PLAN-12 / 12.11 — real end-to-end daemon proof over two clones of one bare remote.
/// The git remote is a local `file://` fixture for hermeticity; `remoteURL(at:)` reports an allowlisted
/// HTTPS URL so the daemon's policy gate is still exercised while the wrapped `GitService` performs the
/// real fetch/merge against the clone's actual origin.
final class DaemonEndToEndTests: XCTestCase {
    private var tempDir: String!
    private var remoteURL: String!
    private var cloneA: String!
    private var cloneB: String!
    private var appSupport: String!
    private var agentDir: String!
    private var cursorRulesDir: String!

    private let fileService = FileService()
    private let git = TestPaths.git
    private let manifest = ManifestService()
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveDaemonEndToEndTests-\(UUID().uuidString)"
        appSupport = tempDir + "/app-support"
        agentDir = tempDir + "/agents/claude/skills"
        cursorRulesDir = tempDir + "/cursor/rules"
        try fileService.createDirectory(at: appSupport)
        try fileService.createDirectory(at: agentDir)
        try fileService.createDirectory(at: cursorRulesDir)

        remoteURL = try seedRemote()
        cloneA = try clone(remoteURL, named: "machine-a")
        cloneB = try clone(remoteURL, named: "machine-b")
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    func testRecordGatedCursorReconcileEndToEnd() throws {
        try seedMachineBDeploys()
        let beforeHead = try XCTUnwrap(git.headSHA(at: cloneB))

        let gammaCursor = CursorAdapterConfig(
            description: "Use the synced cursor overlay",
            globs: ["*.swift", "docs/*.md"],
            alwaysApply: true
        )
        try mutateMachineA(cursor: gammaCursor)
        let upstreamHead = try XCTUnwrap(git.headSHA(at: cloneA))

        let daemon = SyncDaemon(
            root: cloneB,
            appSupport: appSupport,
            git: AllowlistedFastForwardGit(wrapping: git),
            hasLocalBranches: self.git.hasLocalBranches,
            credentials: NilCredentialStore(),
            reconciler: DeployReconciler(
                fileService: fileService,
                deployState: DeployStateStore(fileService: fileService, appSupportDir: appSupport),
                pensieveSkillsDir: cloneB + "/skills",
                agentSkillDirs: [.init(platform: .claudeCode, path: agentDir)],
                cursorRulesDir: cursorRulesDir,
                manifestService: manifest
            ),
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )

        XCTAssertEqual(daemon.runOnce(), .synced(changed: true))
        XCTAssertNotEqual(beforeHead, try git.headSHA(at: cloneB))
        XCTAssertEqual(try git.headSHA(at: cloneB), upstreamHead)

        try assertDaemonReconciledPull(cursor: gammaCursor)
        try assertLaunchRebuildIngestsPulledStore(cursor: gammaCursor)
    }

    private func assertDaemonReconciledPull(cursor gammaCursor: CursorAdapterConfig) throws {
        let alphaThroughLink = try fileService.readFile(at: agentDir + "/alpha/SKILL.md")
        XCTAssertTrue(alphaThroughLink.contains("Body from machine A"))
        XCTAssertFalse(fileService.isSymlink(at: agentDir + "/beta"))

        let gammaRaw = try fileService.readFile(at: cloneB + "/skills/gamma/SKILL.md")
        let expectedGammaMDC = CursorMDC.generate(
            directoryName: "gamma",
            description: "Gamma skill",
            cursorConfig: gammaCursor,
            body: SkillParser.stripFrontmatter(gammaRaw)
        )
        XCTAssertEqual(try fileService.readFile(at: cursorRulesDir + "/gamma.mdc"), expectedGammaMDC)
        XCTAssertEqual(try fileService.readFile(at: cursorRulesDir + "/alpha.mdc"), "personal collision\n")

        let state = try DeployStateStore(fileService: fileService, appSupportDir: appSupport).read()
        XCTAssertFalse(state.records.contains { $0.artifactPath == agentDir + "/beta" })
        XCTAssertTrue(state.records.contains { $0.artifactPath == cursorRulesDir + "/gamma.mdc" })
    }

    @MainActor
    private func assertLaunchRebuildIngestsPulledStore(cursor gammaCursor: CursorAdapterConfig) throws {
        let overlayBeforeLaunch = try fileService.readFile(at: cloneB + "/manifest/skills/gamma.yaml")
        let context = try makeContext()
        let launch = LaunchReconciler(
            rebuildService: StoreRebuildService(fileService: fileService, manifestService: manifest),
            migrationService: StoreMigrationService(
                fileService: fileService,
                manifestService: manifest,
                skillStore: SkillStore(fileService: fileService, baseDir: cloneB + "/skills", storeRoot: cloneB)
            ),
            fileService: fileService,
            manifestService: manifest,
            root: cloneB,
            lockPath: appSupport + "/sync.lock",
            git: TestPaths.git
        )

        let outcome = launch.reconcileOnLaunch(context: context, alreadyMigrated: false)

        XCTAssertGreaterThanOrEqual(outcome.rebuild.skillsInserted, 3)
        XCTAssertTrue(outcome.migrationRan)
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let delta = try XCTUnwrap(skills.first { $0.directoryName == "delta" })
        XCTAssertEqual(delta.name, "Delta")
        XCTAssertEqual(delta.skillDescription, "New from machine A")
        XCTAssertTrue(try fileService.readFile(at: cloneB + "/skills/delta/SKILL.md").contains("Delta body"))

        let gamma = try XCTUnwrap(skills.first { $0.directoryName == "gamma" })
        XCTAssertEqual(gamma.cursorConfig, gammaCursor)
        XCTAssertEqual(try fileService.readFile(at: cloneB + "/manifest/skills/gamma.yaml"), overlayBeforeLaunch)
    }

    // MARK: - Fixture setup

    private func seedRemote() throws -> String {
        let remotePath = tempDir + "/origin.git"
        XCTAssertEqual(try rawGit(["init", "--bare", remotePath]).code, 0)
        XCTAssertEqual(try rawGit(["--git-dir", remotePath, "symbolic-ref", "HEAD", "refs/heads/main"]).code, 0)

        let seed = tempDir + "/seed"
        try fileService.createDirectory(at: seed)
        try git.initRepository(at: seed)
        let remote = "file://" + remotePath
        try git.setRemote(remote, at: seed)

        try writeSkill(root: seed, slug: "alpha", name: "Alpha", description: "Alpha skill", body: "Original body")
        try writeSkill(root: seed, slug: "beta", name: "Beta", description: "Beta skill", body: "Deleted later")
        try writeSkill(root: seed, slug: "gamma", name: "Gamma", description: "Gamma skill", body: "Gamma body")
        try writeManifest(root: seed, overlays: [
            overlay("alpha"),
            overlay("beta"),
            overlay("gamma")
        ])

        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed canonical store"))
        try git.push(at: seed, credential: nil)
        return remote
    }

    private func seedMachineBDeploys() throws {
        try fileService.createSymlink(at: agentDir + "/alpha", pointingTo: cloneB + "/skills/alpha")
        try fileService.createSymlink(at: agentDir + "/beta", pointingTo: cloneB + "/skills/beta")
        try fileService.writeFile(at: cursorRulesDir + "/gamma.mdc",
                                  content: "---\n# pensieve: managed\n---\nstale cursor rule\n")
        try fileService.writeFile(at: cursorRulesDir + "/alpha.mdc", content: "personal collision\n")
        try DeployStateStore(fileService: fileService, appSupportDir: appSupport).replaceAll([
            deployStateRecord(slug: "alpha", platform: .claudeCode, artifactPath: agentDir + "/alpha"),
            deployStateRecord(slug: "beta", platform: .claudeCode, artifactPath: agentDir + "/beta"),
            deployStateRecord(slug: "gamma", platform: .cursor, artifactPath: cursorRulesDir + "/gamma.mdc")
        ])
    }

    private func mutateMachineA(cursor: CursorAdapterConfig) throws {
        try writeSkill(root: cloneA, slug: "alpha", name: "Alpha", description: "Alpha skill",
                       body: "Body from machine A")
        try fileService.deleteDirectory(at: cloneA + "/skills/beta")
        try writeSkill(root: cloneA, slug: "delta", name: "Delta", description: "New from machine A",
                       body: "Delta body")
        try writeManifest(root: cloneA, overlays: [
            overlay("alpha"),
            overlay("gamma", cursor: cursor, tags: ["synced"]),
            overlay("delta", tags: ["new"])
        ])
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "machine A updates store"))
        try git.push(at: cloneA, credential: nil)
    }

    private func clone(_ remote: String, named name: String) throws -> String {
        let path = tempDir + "/" + name
        try git.clone(remote: remote, into: path, credential: nil)
        return path
    }

    private func writeSkill(root: String, slug: String, name: String, description: String, body: String) throws {
        try fileService.writeFile(
            at: root + "/skills/\(slug)/SKILL.md",
            content: SkillSerializer.serialize(name: name, description: description, body: body)
        )
    }

    private func writeManifest(root: String, overlays: [SkillOverlay]) throws {
        try manifest.write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [],

                projects: [],
                skills: overlays,
                deployIntents: [DeployIntentRecord(
                    machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                    skillSlug: "gamma",
                    platformRaw: "cursor",
                    projectKey: "github.com/owner/project"
                )]
            ),
            toRoot: root
        )
    }

    private func overlay(_ slug: String,
                         cursor: CursorAdapterConfig? = nil,
                         tags: [String] = []) -> SkillOverlay {
        SkillOverlay(slug: slug, createdAt: fixedDate, scope: .user, tags: tags,
                     cursor: cursor, agents: [], origin: .authored)
    }

    private func deployStateRecord(
        slug: String,
        platform: PlatformTarget,
        artifactPath: String
    ) -> DeployStateRecord {
        DeployStateRecord(
            slug: slug,
            platform: platform.rawValue,
            scope: "user",
            projectIdentityKey: nil,
            artifactPath: artifactPath,
            recordedAt: "2026-07-17T00:00:00Z"
        )
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, PensieveCategory.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func rawGit(_ args: [String]) throws -> (out: String, code: Int32) {
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
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: outData, encoding: .utf8) ?? "", process.terminationStatus)
    }
}

final class AllowlistedFastForwardGit: FastForwardGitService {
    private let wrapped: GitService

    init(wrapping wrapped: GitService) {
        self.wrapped = wrapped
    }

    func remoteURL(at path: String) throws -> String? {
        try wrapped.remoteURL(at: path) == nil ? nil : "https://fixture.test/pensieve-skills.git"
    }

    func isWorktreeClean(at path: String) -> Bool {
        wrapped.isWorktreeClean(at: path)
    }

    func fetch(at path: String, credential: GitCredential?) throws {
        try wrapped.fetch(at: path, credential: credential)
    }

    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        try wrapped.fastForwardOnly(at: path, credential: credential)
    }
}

private final class NilCredentialStore: CredentialStoreProtocol {
    func store(token: String, username: String, forHost host: String) throws {}
    func credential(forHost host: String) -> GitCredential? { nil }
    func delete(forHost host: String) throws {}
}
