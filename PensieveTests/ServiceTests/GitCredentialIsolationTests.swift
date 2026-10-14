import Darwin
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
        let pid = try XCTUnwrap(Int32(try agent.agentPID))
        defer {
            // Cleanup owns the process, even when a PID receipt becomes unreadable.
            try? agent.fixture.files.writeFile(at: agent.socketDirectory + "/pid", content: "not-a-pid")
            try? agent.remove()
            XCTAssertEqual(kill(pid, 0), -1, "The owned ssh-agent must be stopped")
        }
        try assertAgentDeadlineOutlivesTestTimeout(pid: pid)
        XCTAssertTrue(agent.socket.hasPrefix(TestTemporaryDirectory.path), "The suite must contain its agent socket")
        let previous = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", agent.socket, 1)
        defer {
            if let previous { setenv("SSH_AUTH_SOCK", previous, 1) } else { unsetenv("SSH_AUTH_SOCK") }
        }
        try agent.fixture.clearTraces()
        try await exerciseSyncLifecycle(agent.fixture)
        XCTAssertFalse(try agent.fixture.files.readFile(at: agent.fixture.base + "/agent-calls").isEmpty)
    }

    func testConflictPushRefusalCanBeRepairedWithoutDisconnecting() async throws {
        let fixture = try NativeTestWork.run { try GitCredentialFixture() }
        defer { try? fixture.remove() }
        try fixture.clearTraces()
        try await exerciseSyncLifecycle(fixture, repairToken: true)
    }

    private func exerciseSyncLifecycle(_ fixture: GitCredentialFixture, repairToken: Bool = false) async throws {
        let credentials = InMemoryCredentialStore()
        let first = fixture.base + "/first", second = fixture.base + "/second", downstream = fixture.base + "/downstream"
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
        guard case let .synced(pushed, _, _, _, _) = cycle else {
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
        if repairToken {
            try await repairConflictToken(fixture, conflicts: conflicts, second: second,
                downstream: downstream, container: secondContainer, credentials: credentials)
            return
        }
        await conflicts.applyAndReport(container: secondContainer)
        XCTAssertEqual(conflicts.phase, .done)
        try assertDownstreamAndReceipts(fixture, second: second, downstream: downstream, credentials: credentials)
    }

    private func repairConflictToken(_ fixture: GitCredentialFixture, conflicts: ConflictResolutionModel,
                                     second: String, downstream: String, container: ModelContainer,
                                     credentials: CredentialStoreProtocol) async throws {
        let replacement = fixture.token + "-replacement"
        try fixture.files.writeFile(at: fixture.base + "/rotate-at-push", content: replacement)
        await conflicts.applyAndReport(container: container)
        let failedPhase = ConflictResolutionModel.Phase.error(
            "fixture.test didn’t accept the access token. Replace it in Settings › Sync, then try again.")
        XCTAssertEqual(conflicts.phase, failedPhase, "The failure must leave the conflict sheet open")
        let model = SyncTokenModel(git: fixture.git, credentials: credentials,
            root: second, lockPath: fixture.base + "/sync.lock", steps: SyncStepModel())
        model.refresh(remoteURL: fixture.remote)
        model.token = replacement
        model.save()
        await TestWait.until(failureMessage: "Conflict token replacement did not finish") { model.state != .checking }
        XCTAssertEqual(model.state, .saved)
        XCTAssertEqual(conflicts.phase, failedPhase, "Replacing a token must not dismiss or reload the conflict")
        // Retry re-inspects; the prior pick has already rebased, so inspection finishes its unpushed commit.
        await conflicts.loadAndReport(container: container)
        XCTAssertEqual(conflicts.phase, .empty)
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
            let store = InMemoryCredentialStore()
            let slot = CredentialHost.installNamespace(for: "fixture.test")
            try store.store(token: fixture.token, username: "pensieve", forHost: slot)
            let credential = try XCTUnwrap(store.credential(forHost: slot))
            let git = fixture.git
            try git.cloneShallow(remote: fixture.remote, branch: "main", into: clone, credential: credential)
            let commit = try git.commitSHA(at: clone)
            XCTAssertEqual(try git.remoteHead(remote: fixture.remote, ref: "main", credential: credential), commit)
            let result = try git.upstreamHistory(UpstreamHistoryGitRequest(remote: fixture.remote, ref: "main",
                installedCommit: commit, path: "skills/example", repositoryPath: fixture.base + "/history",
                commitLimit: 2, rowLimit: 3, textByteLimit: 1_024, baselineFileLimit: 10,
                baselineByteLimit: 10_000, credential: credential))
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
            let credentials: [GitCredential?] = [nil, .httpsToken(username: "u", token: "", host: "fixture.test"),
                                                .httpsToken(username: "u", token: " \t\n", host: "fixture.test")]
            let sources: [[String: String]] = [[:], ["GIT_ASKPASS": fixture.askpass],
                                               ["SSH_ASKPASS": fixture.askpass],
                                               ["GIT_ASKPASS": fixture.askpass, "SSH_ASKPASS": fixture.askpass]]
            for source in sources {
                // Disable just the helper to prove each askpass source is capable of supplying a token.
                let config = try fixture.files.readFile(at: fixture.config)
                if source["SSH_ASKPASS"] != nil && source["GIT_ASKPASS"] == nil {
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
                        guard case let GitError.authenticationFailed(_, detail) = $0 else {
                            return XCTFail("Expected authentication failure, got \($0)")
                        }
                        XCTAssertFalse(detail.contains("unable to read askpass response"), detail)
                    }
                    XCTAssertEqual(try fixture.files.readFile(at: fixture.foreignTrace), "")
                    XCTAssertEqual(try fixture.files.readFile(at: fixture.networkTrace), "")
                }
            }
        }
    }

    func testTokenIsWithheldFromRewritesExtraPushURLsAndProxyPrompts() throws {
        try NativeTestWork.run {
            let fixture = try GitCredentialFixture()
            defer { try? fixture.remove() }
            let root = fixture.base + "/store"
            try fixture.files.createDirectory(at: root)
            try fixture.git.initRepository(at: root)
            try fixture.git.setRemote(fixture.remote, at: root)
            // Git supplies the username itself, so every denied destination reaches a password prompt.
            _ = try fixture.raw(["-C", root, "config", "credential.username", "pensieve"])
            let config = try fixture.files.readFile(at: fixture.config)
            try fixture.files.writeFile(at: fixture.config, content: config + "\n[credential]\n    sanitizePrompt = false\n")
            let cases = [
                ["url.http://fixture.test/.pushInsteadOf", "https://fixture.test/"],
                ["url.https://elsewhere.test/.pushInsteadOf", "https://fixture.test/"],
                ["url.https://fixture.test%2F@example.com/.pushInsteadOf", "https://fixture.test/"],
                ["remote.origin.url", "https://elsewhere.test/store.git"],
                ["http.proxy", "http://proxy.test:8080"]
            ]
            for entry in cases {
                _ = try fixture.raw(["-C", root, "config", "--add"] + entry)
                defer { _ = try? fixture.raw(["-C", root, "config", "--unset-all", entry[0]]) }
                try fixture.clearTraces()
                try fixture.files.writeFile(at: fixture.base + "/credential-receipts", content: "")
                var failure: Error?
                do { try fixture.git.push(at: root, credential: fixture.credential) } catch { failure = error }
                let receipts = try fixture.files.readFile(at: fixture.base + "/credential-receipts")
                // An extra origin URL first authenticates the legitimate destination, then refuses the extra.
                XCTAssertEqual(receipts.components(separatedBy: "password=" + fixture.token).count - 1,
                               entry[0] == "remote.origin.url" ? 1 : 0, "\(entry): \(receipts)")
                guard case .authenticationFailed? = failure as? GitError else {
                    XCTFail("Expected sign-in refusal for \(entry), got \(String(describing: failure))")
                    continue
                }
                XCTAssertEqual(try fixture.files.readFile(at: fixture.networkTrace), "")
                XCTAssertEqual(try fixture.files.readFile(at: fixture.foreignTrace), "")
            }
        }
    }

}

extension GitCredentialIsolationTests {
    func testRealGitPromptsMatchHTTPSHostExactlyWithCasePortsAndIPv6() throws {
        try NativeTestWork.run { [self] in
            let fixture = try GitCredentialFixture()
            defer { try? fixture.remove() }
            let cases = [("FiXtUrE.TeSt", "fixture.test:8443"),
                         ("2001:DB8::1", "[2001:db8::1]:8443"),
                         ("my_host.test", "my_host.test"),
                         ("%67ithub.com", "%67ithub.com"),
                         ("ÄXAMPLE.test", "ÄXAMPLE.test"),
                         ("percent%25host.test", "percent%25host.test")]
            for (host, authority) in cases {
                let spec = try XCTUnwrap(RemoteURLPolicy.parse("https://\(authority)/store.git"))
                XCTAssertEqual(spec.host, authority == "fixture.test:8443" ? "fixture.test"
                    : authority.hasPrefix("[") ? "2001:db8::1" : host)
                let credential = GitCredential.httpsToken(username: "kept", token: fixture.token, host: host)
                try assertCredentialFill(fixture, credential: credential, remote: "https://\(authority)/store.git",
                    options: ["-c", "credential.useHttpPath=true"])
                for scheme in ["HTTPS", "Https"] {
                    try assertCredentialFill(fixture, credential: credential, remote: "\(scheme)://\(authority)/store.git")
                }
                for denied in ["http://\(authority)/store.git", "HTTP://\(authority)/store.git",
                               "https://elsewhere.test/store.git", "HTTPS://elsewhere.test/store.git",
                               "Https://example.com/x@\(host)/r.git", "HTTPS://example.com/x@\(host)/r.git",
                               "https://[2001:db8::2]:8443/store.git", "https://%65lsewhere.test/store.git",
                               "https://fixture.test%2F@example.com/store.git",
                               "https://fixture.test%40elsewhere.test/store.git",
                               "https://fixture.test%3Aelsewhere.test/store.git",
                               "https://fixture.test:/store.git", "https://[2001:db8::1]:elsewhere.test/store.git",
                               "https://%2567ithub.com/store.git", "https://äxample.test/store.git"] {
                    try fixture.files.writeFile(at: fixture.base + "/credential-input", content: "url=\(denied)\n\n")
                    XCTAssertThrowsError(try fixture.git.runOrThrow(["credential", "fill"],
                        in: nil, credential: credential), "\(host) must refuse \(denied)")
                }
            }
            try fixture.files.writeFile(at: fixture.base + "/credential-input",
                content: "url=https://fixture.test/store.git\n\n")
            for host in ["*.test", "fixture.test%00", "fixture.test%0A", "fixture.test%0D"] {
                XCTAssertThrowsError(try fixture.git.runOrThrow(["credential", "fill"], in: nil,
                    credential: .httpsToken(username: "kept", token: fixture.token, host: host)),
                    "Saved hosts cannot be patterns or hide control bytes: \(host)")
            }
        }
    }

    private func assertCredentialFill(_ fixture: GitCredentialFixture, credential: GitCredential,
                                      remote: String, options: [String] = []) throws {
        try fixture.files.writeFile(at: fixture.base + "/credential-input", content: "url=\(remote)\n\n")
        do {
            let auth = try fixture.git.runOrThrow(options + ["credential", "fill"], in: nil, credential: credential).stdout
            XCTAssertTrue(auth.contains("username=kept"), remote)
            XCTAssertTrue(auth.contains("password=" + fixture.token), remote)
        } catch {
            XCTFail("Saved credential must answer git’s prompt for \(remote): \(error)")
        }
    }

    func testAskpassPercentDecodingWorksAcrossShellsInShMode() throws {
        try NativeTestWork.run {
            let fixture = try GitCredentialFixture()
            defer { try? fixture.remove() }
            let cases = [("my_host.test", "my%5Fhost.test"), ("%67ithub.com", "github.com"),
                         ("ÄXAMPLE.test", "%C3%84XAMPLE.test")]
            for (host, promptHost) in cases {
                let environment = try fixture.git.childEnvironment(credential:
                    .httpsToken(username: "kept", token: fixture.token, host: host))
                let helper = try XCTUnwrap(environment["GIT_ASKPASS"])
                for shell in ["/bin/sh", "/bin/dash", "/bin/zsh"] {
                    for (field, expected) in [("Username", "kept"), ("Password", fixture.token)] {
                        let arguments = (shell == "/bin/zsh" ? ["--emulate", "sh"] : [])
                            + [helper, "\(field) for 'https://\(promptHost)': "]
                        // Foundation Process decomposes Unicode environment values; use production’s byte-preserving spawn.
                        let child = try GitProcess(executable: shell, arguments: arguments,
                            workingDirectory: nil, environment: environment)
                        let output = try child.readOutput()
                        XCTAssertEqual(output.exit, 0, "\(shell): \(host)")
                        XCTAssertEqual(String(bytes: output.stdout, encoding: .utf8), expected, "\(shell): \(host)")
                    }
                }
            }
        }
    }

    private func assertAgentDeadlineOutlivesTestTimeout(pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,args="]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let rows = try XCTUnwrap(String(bytes: data, encoding: .utf8)).split(separator: "\n").map {
            $0.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        let agentRow = try XCTUnwrap(rows.first { $0.first == String(pid) })
        let driver = agentRow[1]
        let timer = try XCTUnwrap(rows.first { $0.count == 4 && $0[1] == driver && $0[2] == "/bin/sleep" })
        let lifetime = try XCTUnwrap(Int(timer[3]))
        // test.sh bounds each test at 180 seconds; the crash timer must leave cleanup a margin.
        XCTAssertGreaterThanOrEqual(lifetime, 240, "The fixture must never expire during a running test")
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
