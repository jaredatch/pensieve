import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class GitCredentialIsolationTests: XCTestCase {
    func testConnectSyncConflictAndDaemonUseOnlyPensieveToken() async throws {
        let fixture = try NativeTestWork.run { try GitCredentialFixture() }
        defer { try? fixture.remove() }
        // The configured helper really answers, and supports the store/erase operations we forbid.
        XCTAssertTrue(try fixture.lookup().contains("password=wrong-token"))
        XCTAssertTrue(try fixture.files.readFile(at: fixture.foreignTrace).contains("helper get"))
        try fixture.clearTraces()
        try await exerciseSyncLifecycle(fixture)
    }

    func testSSHConnectSyncAndConflictKeepAgentAuthenticationWithoutPrompts() async throws {
        let agent = try NativeTestWork.run { try GitAgentFixture() }
        defer { try? agent.remove() }
        let previous = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", agent.socket, 1)
        defer {
            if let previous { setenv("SSH_AUTH_SOCK", previous, 1) } else { unsetenv("SSH_AUTH_SOCK") }
        }
        try agent.fixture.clearTraces()
        try await exerciseSyncLifecycle(agent.fixture)
        XCTAssertFalse(try agent.fixture.files.readFile(at: agent.fixture.base + "/agent-calls").isEmpty)
    }

    private func exerciseSyncLifecycle(_ fixture: GitCredentialFixture) async throws {
        let credentials = InMemoryCredentialStore()
        let first = fixture.base + "/first"
        let second = fixture.base + "/second"
        let downstream = fixture.base + "/downstream"
        let firstContainer = try container()
        let secondContainer = try container()
        try writeSkill(fixture, root: first, body: "Base")
        try ManifestService().write(.init(schemaVersion: ManifestService.currentSchemaVersion,
            categories: [], projects: [], skills: []), toRoot: first)
        try await connect(fixture, root: first, container: firstContainer, credentials: credentials)
        try await connect(fixture, root: second, container: secondContainer, credentials: credentials)
        try ManifestService().write(.init(schemaVersion: ManifestService.currentSchemaVersion,
            categories: [], projects: [], skills: []), toRoot: downstream)
        try await connect(fixture, root: downstream, container: container(), credentials: credentials)

        let git = fixture.git
        let engine = SyncEngine(gitService: git, manifestService: ManifestService(),
            storeRebuildService: StoreRebuildService(), lockPath: fixture.base + "/sync.lock")
        let coordinator = SyncCoordinator(modelContainer: secondContainer)
        await coordinator.configure(engine: engine, git: git, credentials: credentials, root: second,
            audit: CredentialAudit(), machine: (InertMachineIdentity(), InertMachineStateService()))
        try writeSkill(fixture, root: second, body: "Synced edit")
        let cycle = await coordinator.runCycle()
        guard case let .synced(pushed, _, _, _) = cycle else {
            return XCTFail("Expected a successful sync, got \(cycle)")
        }
        XCTAssertTrue(pushed)
        try NativeTestWork.run {
            _ = try git.pullRebase(at: first, credential: fixture.transport == .ssh ? .sshAgent : fixture.credential)
        }
        try writeSkill(fixture, root: first, body: "Remote edit")
        try NativeTestWork.run {
            _ = try git.stageAllAndCommit(at: first, message: "Remote edit")
            try git.push(at: first, credential: fixture.transport == .ssh ? .sshAgent : fixture.credential)
        }
        try writeSkill(fixture, root: second, body: "Local edit")
        guard case .conflicted = await coordinator.runCycle() else { return XCTFail("Expected conflict") }
        let conflicts = ConflictResolutionModel(engine: engine, git: git, credentials: credentials,
            root: second, steps: SyncStepModel())
        await conflicts.loadAndReport(container: secondContainer)
        guard case let .ready(groups) = conflicts.phase, groups.count == 1 else {
            return XCTFail("Expected one loaded conflict, got \(conflicts.phase)")
        }
        conflicts.choose(groups[0].id, .thisMachine)
        await conflicts.applyAndReport(container: secondContainer)
        XCTAssertEqual(conflicts.phase, .done)
        try assertDownstreamAndReceipts(fixture, second: second, downstream: downstream, credentials: credentials)
    }

    private func assertDownstreamAndReceipts(
        _ fixture: GitCredentialFixture, second: String, downstream: String,
        credentials: CredentialStoreProtocol
    ) throws {
        let git = fixture.git
        let daemon = SyncDaemon(root: downstream, appSupport: fixture.base + "/daemon", git: git,
            hasLocalBranches: { try git.hasLocalBranches(at: $0) }, credentials: credentials,
            reconciler: CredentialReconciler(), now: Date.init)
        XCTAssertEqual(try NativeTestWork.run { daemon.runOnce() }, .synced(changed: true))
        XCTAssertEqual(try fixture.files.readFile(at: downstream + "/skills/example/SKILL.md"),
                       try fixture.files.readFile(at: second + "/skills/example/SKILL.md"))
        let network = try fixture.files.readFile(at: fixture.networkTrace).split(separator: "\n")
        for command in ["clone", "fetch", "push", "ls-remote"] {
            XCTAssertTrue(network.contains(Substring(command)), "Missing authenticated \(command)")
        }
        XCTAssertEqual(try fixture.files.readFile(at: fixture.foreignTrace), "")
        XCTAssertFalse(try fixture.files.readFile(at: fixture.argvTrace).contains(fixture.token))
        for root in [fixture.base + "/first", second, downstream] {
            XCTAssertFalse(try fixture.files.readFile(at: root + "/.git/config").contains(fixture.token))
        }
    }

    func testInstallAndUpstreamHistoryUseSharedCredentialIsolation() throws {
        try NativeTestWork.run {
            let fixture = try GitCredentialFixture()
            defer { try? fixture.remove() }
            let seed = fixture.base + "/seed"
            let clone = fixture.base + "/install"
            try fixture.files.writeFile(at: seed + "/skills/example/SKILL.md", content: "Original skill\n")
            _ = try fixture.raw(["init", "--initial-branch=main", seed])
            _ = try fixture.raw(["-C", seed, "add", "."])
            _ = try fixture.raw(["-C", seed, "commit", "-m", "Seed"])
            _ = try fixture.raw(["-C", seed, "push", "file://" + fixture.bare, "main"])
            try fixture.clearTraces()
            let git = fixture.git
            try git.cloneShallow(remote: fixture.remote, branch: "main", into: clone, credential: fixture.credential)
            let commit = try git.commitSHA(at: clone)
            XCTAssertEqual(try git.remoteHead(remote: fixture.remote, ref: "main", credential: fixture.credential), commit)
            let result = try git.upstreamHistory(UpstreamHistoryGitRequest(remote: fixture.remote, ref: "main",
                installedCommit: commit, path: "skills/example", repositoryPath: fixture.base + "/history",
                commitLimit: 2, rowLimit: 3, textByteLimit: 1_024, baselineFileLimit: 10,
                baselineByteLimit: 10_000, credential: fixture.credential))
            XCTAssertEqual(result.rows.first?.sha, commit)
            XCTAssertEqual(try fixture.files.readFile(at: fixture.foreignTrace), "")
            let commands = try fixture.files.readFile(at: fixture.networkTrace).split(separator: "\n")
            for command in ["clone", "ls-remote", "fetch"] { XCTAssertTrue(commands.contains(Substring(command))) }
        }
    }

    func testMissingAndBlankTokenNeverUseForeignCredentialPrograms() throws {
        try NativeTestWork.run {
            let fixture = try GitCredentialFixture()
            defer { try? fixture.remove() }
            let credentials: [GitCredential?] = [nil, .httpsToken(username: "u", token: ""),
                                                .httpsToken(username: "u", token: " \t\n")]
            let sources: [[String: String]] = [[:], ["GIT_ASKPASS": fixture.askpass],
                                               ["SSH_ASKPASS": fixture.askpass]]
            for source in sources {
                // Disable just the helper to prove each askpass source is capable of supplying a token.
                let config = try fixture.files.readFile(at: fixture.config)
                if source["SSH_ASKPASS"] != nil {
                    try fixture.files.writeFile(at: fixture.config,
                        content: config.replacingOccurrences(of: "    askPass = \(fixture.askpass)\n", with: ""))
                }
                defer { try? fixture.files.writeFile(at: fixture.config, content: config) }
                XCTAssertTrue(try fixture.lookup(["-c", "credential.helper="], environment: source)
                    .contains("password=wrong-token"))
                let saved = source.keys.reduce(into: [String: String]()) { result, key in
                    result[key] = ProcessInfo.processInfo.environment[key]
                }
                for (key, value) in source { setenv(key, value, 1) }
                defer {
                    for key in source.keys {
                        if let value = saved[key] { setenv(key, value, 1) } else { unsetenv(key) }
                    }
                }
                for credential in credentials {
                    try fixture.clearTraces()
                    XCTAssertThrowsError(try fixture.git.remoteReferences(remote: fixture.remote, credential: credential)) {
                        guard case GitError.authenticationFailed = $0 else {
                            return XCTFail("Expected authentication failure, got \($0)")
                        }
                    }
                    XCTAssertEqual(try fixture.files.readFile(at: fixture.foreignTrace), "")
                    XCTAssertEqual(try fixture.files.readFile(at: fixture.networkTrace), "")
                }
            }
        }
    }

    private func container() throws -> ModelContainer {
        try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func connect(_ fixture: GitCredentialFixture, root: String, container: ModelContainer,
                         credentials: CredentialStoreProtocol) async throws {
        let model = SyncSetupModel(context: ModelContext(container), git: fixture.git, credentials: credentials,
            root: root, lockPath: root + "-sync.lock", steps: SyncStepModel())
        await model.connectAndReport(url: fixture.remote, username: "pensieve",
                                     token: fixture.transport == .ssh ? "" : fixture.token)
        XCTAssertEqual(model.state, .done)
        guard model.state == .done else { throw CredentialTestFailure.connect }
    }

    private func writeSkill(_ fixture: GitCredentialFixture, root: String, body: String) throws {
        try fixture.files.writeFile(at: root + "/skills/example/SKILL.md",
            content: "---\nname: Example\ndescription: Credential fixture\n---\n\(body)\n")
    }
}

private enum CredentialTestFailure: Error { case connect }
private struct CredentialAudit: SyncAuditWriting {
    func record(category: String, detail: String) {}
}
private struct CredentialReconciler: DeployReconciling {
    func reconcile(root: String) -> ReconcileOutcome { ReconcileOutcome() }
}
