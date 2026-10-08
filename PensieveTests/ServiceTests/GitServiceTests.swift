import XCTest
@testable import Pensieve

// Frozen PLAN-24 keeps its added service seams in this existing test file and class.
// swiftlint:disable file_length

/// PLAN-08 / 08.1 — GitService against REAL temp git repos over file:// (no network). Proves
/// init→main, clone delivery, up-to-date / merged / conflicted classification, safe rebase abort,
/// nothing-to-commit → false, remote round-trip, and empty-vs-nonempty remote detection.
/// 08.2 adds the HTTPS credential-injection assertions (env-fed askpass; secret never in argv/helper).
final class GitServiceTests: XCTestCase {
    private var tempDir: String!
    private var git: GitService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveGitServiceTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        git = GitService(
            fileService: LinkServiceCanonicalDirectoryFileService(
            wrapped: FileService(),
            pathMappings: [((TestPaths.gitAskpassHelperPath), tempDir + "/askpass")],
            physicalSandbox: tempDir
        ),
            askpassHelperPath: TestPaths.gitAskpassHelperPath
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    // MARK: Fixtures

    /// The captured result of one raw `git` fixture invocation (struct, not a 3-tuple, for SwiftLint).
    private struct RawResult {
        let out: String
        let err: String
        let code: Int32
    }

    private struct AskpassWriteBoom: Error {}

    /// A FileService double whose executable-file write always fails — proves an askpass-helper write
    /// failure PROPAGATES out of childEnvironment (10.4 / C3) instead of being try?-swallowed.
    private struct AskpassWriteFailingFileService: FileServiceProtocol {
        func writeExecutableFile(at path: String, content: String) throws { throw AskpassWriteBoom() }
        func readFile(at path: String) throws -> String { "" }
        func writeFile(at path: String, content: String) throws {}
        func deleteFile(at path: String) throws {}
        func fileExists(at path: String) -> Bool { false }
        func isExecutableFile(at path: String) -> Bool { false }
        func directoryExists(at path: String) -> Bool { false }
        func createDirectory(at path: String) throws {}
        func deleteDirectory(at path: String) throws {}
        func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
        func symlinkTarget(at path: String) throws -> String { "" }
        func isSymlink(at path: String) -> Bool { false }
        func listDirectory(at path: String) throws -> [String] { [] }
        func contentsHash(at path: String) throws -> String { "" }
    }

    /// Test-local raw git (fixtures only — production code uses GitService). Hermetic identity so a
    /// commit works under a config-less test HOME.
    @discardableResult
    private func rawGit(_ args: [String], in dir: String? = nil) throws -> RawResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "test@pensieve.local"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "test@pensieve.local"
        p.environment = env
        let o = Pipe(); let e = Pipe()
        p.standardOutput = o; p.standardError = e
        try p.run()
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RawResult(out: String(bytes: od, encoding: .utf8) ?? "",
                         err: String(bytes: ed, encoding: .utf8) ?? "",
                         code: p.terminationStatus)
    }

    private func makeBareRemote() throws -> String {
        let remotePath = tempDir + "/remote.git"
        let r = try rawGit(["init", "--bare", remotePath])
        XCTAssertEqual(r.code, 0, "bare init failed: \(r.err)")
        return "file://" + remotePath
    }

    /// A bare remote seeded with one commit on `main` (via init+push — exercises initRepository).
    private func seededRemote() throws -> String {
        let remote = try makeBareRemote()
        let seed = tempDir + "/seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try git.initRepository(at: seed)
        try git.setRemote(remote, at: seed)
        try write("README.md", "seed\n", in: seed)
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        let barePath = String(remote.dropFirst("file://".count))
        let head = try rawGit(["-C", barePath, "symbolic-ref", "HEAD", "refs/heads/main"])
        XCTAssertEqual(head.code, 0, head.err)
        return remote
    }

    private func write(_ name: String, _ content: String, in dir: String) throws {
        try content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    private func clone(_ remote: String, _ name: String) throws -> String {
        let dst = tempDir + "/" + name
        try git.clone(remote: remote, into: dst, credential: nil)
        return dst
    }

    // MARK: Tests

    func testInitRepositoryYieldsMainBranch() throws {
        let work = tempDir + "/w"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git.initRepository(at: work)
        XCTAssertEqual(try git.runOrThrow(["-C", work, "rev-parse", "--is-inside-work-tree"], in: nil).stdout, "true\n")
        try write("a.txt", "1\n", in: work)
        XCTAssertTrue(try git.stageAllAndCommit(at: work, message: "first"))
        let branch = try rawGit(["-C", work, "rev-parse", "--abbrev-ref", "HEAD"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "main")
    }

    func testRemoteAbsentForPlainDirAndUnknownForMissingRoot() throws {
        let plain = tempDir + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        XCTAssertNil(try git.remoteURL(at: plain))
        XCTAssertThrowsError(try git.remoteURL(at: tempDir + "/does-not-exist"))
    }

    func testCloneDeliversAFile() throws {
        let remote = try seededRemote()
        let b = try clone(remote, "b")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b + "/README.md"))
        let originalHead = try git.commitSHA(at: b)
        try assertCloneRefusesOccupiedStore(remote: remote, destination: b)
        XCTAssertEqual(try git.commitSHA(at: b), originalHead, "Publication must preserve an occupied store")
        XCTAssertEqual(try FileService().readFile(at: b + "/README.md"), "seed\n")
        try assertClonePublicationRace(remote: remote)
        let failures = ["clone", "metadata-write", "metadata-path", "head-probe", "head-read",
                        "checkout", "terminated-checkout"]
        for failure in failures {
            try assertFailedCloneCanRetry(remote: remote, failure: failure)
        }
    }

    func testRemoteURLRoundTrip() throws {
        let work = tempDir + "/w"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git.initRepository(at: work)
        XCTAssertNil(try git.remoteURL(at: work))
        try git.setRemote("file:///tmp/one.git", at: work)
        XCTAssertEqual(try git.remoteURL(at: work), "file:///tmp/one.git")
        try git.setRemote("file:///tmp/two.git", at: work)   // update, not duplicate
        XCTAssertEqual(try git.remoteURL(at: work), "file:///tmp/two.git")
    }

    func testConfiguredRemoteURLIsLiteralUnderInsteadOf() throws {
        let work = tempDir + "/remove-remote"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git.initRepository(at: work)
        let literal = "https://github.com/octocat/pensieve-skills.git"
        try git.setRemote(literal, at: work)
        let rewrite = try rawGit([
            "-C", work, "config", "url.git@github.com:.insteadOf", "https://github.com/"
        ])
        XCTAssertEqual(rewrite.code, 0, rewrite.err)
        XCTAssertEqual(try git.remoteURL(at: work), "git@github.com:octocat/pensieve-skills.git")
        XCTAssertEqual(try git.configuredRemoteURL(at: work), literal)
        try git.removeRemote(at: work)
        XCTAssertNil(try git.configuredRemoteURL(at: work))
    }

    func testConfiguredRemoteURLThrowsOnBrokenRepository() throws {
        let work = tempDir + "/broken-repository"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try "not a gitdir\n".write(toFile: work + "/.git", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try git.configuredRemoteURL(at: work))
    }

    /// A corrupt or missing `.git/HEAD` leaves `.git/config` intact but makes the directory
    /// undiscoverable; the repository-optional `git config --get` then reads the global config and
    /// reports the key absent (exit 1). `--local` turns that into an error (exit 128), so a disconnect
    /// can never report success over a damaged store. (Layer-2 finding, 2026-09-12.)
    func testConfiguredRemoteURLThrowsOnCorruptHEAD() throws {
        let work = tempDir + "/corrupt-head"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git.initRepository(at: work)
        try git.setRemote("https://github.com/octocat/pensieve-skills.git", at: work)
        try "garbage\n".write(toFile: work + "/.git/HEAD", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try git.configuredRemoteURL(at: work))
    }

    func testRemoveRemoteWithoutOriginThrows() throws {
        let work = tempDir + "/remove-missing-remote"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git.initRepository(at: work)
        XCTAssertThrowsError(try git.removeRemote(at: work))
    }

    func testRemoteHasCommits() throws {
        let empty = try makeBareRemote()
        XCTAssertFalse(git.remoteHasCommits(remote: empty, credential: nil))
        let seeded = try seededRemote()
        XCTAssertTrue(git.remoteHasCommits(remote: seeded, credential: nil))
    }

    func testNothingToCommitReturnsFalse() throws {
        let remote = try seededRemote()
        let a = try clone(remote, "a")
        XCTAssertFalse(try git.stageAllAndCommit(at: a, message: "noop"))
    }

    func testPullRebaseUpToDate() throws {
        let remote = try seededRemote()
        let a = try clone(remote, "a")
        XCTAssertEqual(try git.pullRebase(at: a, credential: nil), .upToDate)
    }

    func testPullRebaseMergedNonConflicting() throws {
        let remote = try seededRemote()
        let a = try clone(remote, "a")
        let b = try clone(remote, "b")
        // A adds a.txt and pushes.
        try write("a.txt", "A\n", in: a)
        XCTAssertTrue(try git.stageAllAndCommit(at: a, message: "A adds a"))
        try git.push(at: a, credential: nil)
        // B adds a DIFFERENT file, then pulls — non-conflicting → merged.
        try write("b.txt", "B\n", in: b)
        XCTAssertTrue(try git.stageAllAndCommit(at: b, message: "B adds b"))
        XCTAssertEqual(try git.pullRebase(at: b, credential: nil), .merged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b + "/a.txt"))   // A's change arrived
    }
}

// MARK: PLAN-24 / 24.2 git-state and adoption seams

extension GitServiceTests {
    func testClassifyLsRemoteFailureAuthVsOther() {
        XCTAssertEqual(
            GitService.classifyLsRemoteFailure(
                exitCode: 128,
                combinedOutput: "Permission denied (publickey)"
            ),
            .auth
        )
        XCTAssertEqual(
            GitService.classifyLsRemoteFailure(exitCode: 128, combinedOutput: "repository unavailable"),
            .other
        )
    }

    func testHasLocalBranchesSignalShapes() throws {
        let work = tempDir + "/branch-signals"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git.initRepository(at: work)
        XCTAssertFalse(try git.hasLocalBranches(at: work))

        let remote = try seededRemote()
        try git.setRemote(remote, at: work)
        try git.fetchBranch("main", at: work, credential: nil)
        XCTAssertFalse(try git.hasLocalBranches(at: work), "remote-tracking refs are not local branches")

        try git.materializeFromFetchHead(at: work)
        try git.bornBranch("main", at: work)
        XCTAssertTrue(try git.hasLocalBranches(at: work))
        let current = try rawGit(["-C", work, "symbolic-ref", "HEAD", "refs/heads/weird"])
        XCTAssertEqual(current.code, 0, current.err)
        XCTAssertTrue(try git.hasLocalBranches(at: work), "foreign shape still has refs/heads/main")

        let plain = tempDir + "/plain-signal"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        XCTAssertThrowsError(try git.hasLocalBranches(at: plain))
    }

    func testHasRemoteTrackingBranchBothWays() throws {
        let work = tempDir + "/tracking"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git.initRepository(at: work)
        XCTAssertFalse(git.hasRemoteTrackingBranch("main", at: work))
        try git.setRemote(try seededRemote(), at: work)
        try git.fetchBranch("main", at: work, credential: nil)
        XCTAssertTrue(git.hasRemoteTrackingBranch("main", at: work))
    }

    func testHasRemoteOriginConfiguredTriState() throws {
        let configured = tempDir + "/origin-configured"
        try FileManager.default.createDirectory(atPath: configured, withIntermediateDirectories: true)
        try git.initRepository(at: configured)
        try git.setRemote("file:///tmp/origin.git", at: configured)
        XCTAssertTrue(try git.hasRemoteOriginConfigured(at: configured))

        let clean = tempDir + "/origin-clean"
        try FileManager.default.createDirectory(atPath: clean, withIntermediateDirectories: true)
        try git.initRepository(at: clean)
        XCTAssertFalse(try git.hasRemoteOriginConfigured(at: clean))

        let corrupt = tempDir + "/origin-corrupt"
        try FileManager.default.createDirectory(atPath: corrupt, withIntermediateDirectories: true)
        try git.initRepository(at: corrupt)
        try write(".git/config", "[core\n", in: corrupt)
        XCTAssertThrowsError(try git.hasRemoteOriginConfigured(at: corrupt)) { error in
            guard case let GitError.commandFailed(_, exitCode, _, _) = error else {
                return XCTFail("expected GitError.commandFailed, got \(error)")
            }
            XCTAssertEqual(exitCode, 128)
        }
    }

    func testBornBranchCreateOnlyBothWays() throws {
        let work = tempDir + "/born"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git.initRepository(at: work)
        try git.setRemote(try seededRemote(), at: work)
        try git.fetchBranch("main", at: work, credential: nil)
        try git.materializeFromFetchHead(at: work)
        try git.bornBranch("main", at: work)
        let original = try git.commitSHA(at: work)
        XCTAssertThrowsError(try git.bornBranch("main", at: work))
        XCTAssertEqual(try git.commitSHA(at: work), original)
    }
}

extension GitServiceTests {
    func testPullRebaseConflictedThenAbortRestoresCleanState() throws {
        let remote = try seededRemote()
        let a = try clone(remote, "a")
        let b = try clone(remote, "b")
        // Both edit README.md divergently.
        try write("README.md", "A version\n", in: a)
        XCTAssertTrue(try git.stageAllAndCommit(at: a, message: "A edits readme"))
        try git.push(at: a, credential: nil)
        try write("README.md", "B version\n", in: b)
        XCTAssertTrue(try git.stageAllAndCommit(at: b, message: "B edits readme"))
        // Pull on B conflicts.
        XCTAssertEqual(try git.pullRebase(at: b, credential: nil), .conflicted(["README.md"]))
        XCTAssertEqual(try git.conflictedFiles(at: b), ["README.md"])
        // Abort restores B to its pre-pull state — nothing lost, no conflicted files.
        try git.abortRebase(at: b)
        XCTAssertEqual(try git.runOrThrow(["-C", b, "rev-parse", "--is-inside-work-tree"], in: nil).stdout, "true\n")
        XCTAssertTrue(try git.conflictedFiles(at: b).isEmpty)
        let body = try String(contentsOfFile: b + "/README.md", encoding: .utf8)
        XCTAssertEqual(body, "B version\n")   // B's edit survives the abort
        let before = try git.commitSHA(at: b)
        for failure in ["metadata-write", "metadata-path"] {
            if FileService().fileExists(at: b + "-fault") { try FileService().deleteFile(at: b + "-fault") }
            XCTAssertEqual(try git.pullRebase(at: b, credential: nil), .conflicted(["README.md"]))
            try FileService().deleteFile(at: b + "/.git/info/attributes")
            let failing = try failingMetadataGit(failure, root: b)
            XCTAssertThrowsError(try failing.abortRebase(at: b), "Repair failure may be reported")
            XCTAssertTrue(FileService().fileExists(at: b + "-fault"))
            XCTAssertFalse(git.isRebaseInProgress(at: b), "Repair failure must never skip abort")
            XCTAssertTrue(try git.conflictedFiles(at: b).isEmpty)
            XCTAssertEqual(try git.commitSHA(at: b), before)
            XCTAssertEqual(try FileService().readFile(at: b + "/README.md"), "B version\n")
            XCTAssertEqual(try rawGit(["-C", b, "status", "--porcelain"]).out, "")
        }
    }

    // MARK: 10.5 — conflicted-path NUL enumeration (C8): an embedded-newline path must not fragment

    func testConflictedFilesHandlesEmbeddedNewlinePath() throws {
        let repo = tempDir + "/nl-conflict"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let name = "a\nb.txt"   // a path byte git C-quotes in non-`-z` output; `-z` returns it raw

        func writeFixture(_ content: String) throws {
            try content.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
        }

        try rawGit(["-C", repo, "init", "-q"])
        try rawGit(["-C", repo, "symbolic-ref", "HEAD", "refs/heads/main"])
        try writeFixture("base")
        try rawGit(["-C", repo, "add", "-A"])
        try rawGit(["-C", repo, "commit", "-qm", "base"])

        try rawGit(["-C", repo, "checkout", "-q", "-b", "other"])
        try writeFixture("other")
        try rawGit(["-C", repo, "commit", "-qam", "other"])

        try rawGit(["-C", repo, "checkout", "-q", "main"])
        try writeFixture("mine")
        try rawGit(["-C", repo, "commit", "-qam", "mine"])

        // Rebase main onto other → conflict on the newline-named path. A non-zero exit is EXPECTED
        // (rawGit returns the result; it does not throw on a non-zero git exit) — do not assert the code.
        _ = try rawGit(["-C", repo, "rebase", "-q", "other"])

        let conflicted = try git.conflictedFiles(at: repo)
        XCTAssertEqual(conflicted.count, 1, "embedded-newline path must not fragment: \(conflicted)")
        XCTAssertEqual(conflicted.first, name, "the single entry must be the exact raw newline-containing name")
    }

    // MARK: 08.2 — HTTPS credential injection (env-fed askpass; secret never in argv or the helper file)

    func testHttpsTokenFeedsAskpassViaChildEnv() throws {
        let secret = "ghp_\(UUID().uuidString)"
        let env = try git.childEnvironment(credential: .httpsToken(username: "x-access-token", token: secret))
        XCTAssertNotNil(env["GIT_ASKPASS"])
        XCTAssertEqual(env["PENSIEVE_GIT_USERNAME"], "x-access-token")
        XCTAssertEqual(env["PENSIEVE_GIT_PASSWORD"], secret)   // the token rides the CHILD ENV
    }

    func testAskpassHelperExistsExecutableAndCarriesNoSecret() throws {
        let secret = "ghp_\(UUID().uuidString)"
        let env = try git.childEnvironment(credential: .httpsToken(username: "x-access-token", token: secret))
        let helper = try XCTUnwrap(env["GIT_ASKPASS"])
        XCTAssertTrue(git.fileService.isExecutableFile(at: helper))
        let helperBody = try git.fileService.readFile(at: helper)
        XCTAssertFalse(helperBody.contains(secret))   // the helper reads env; it holds NO secret at rest
        XCTAssertTrue(helperBody.contains("PENSIEVE_GIT_PASSWORD"))
        try assertHelperRemainsExecutableDuringRewrite(body: helperBody, environment: env, secret: secret)
    }

    private func assertHelperRemainsExecutableDuringRewrite(
        body: String, environment: [String: String], secret: String
    ) throws {
        let helper = tempDir + "/askpass"
        try FileService().deleteFile(at: helper)
        var observations = 0
        var executions = 0
        // A second caller executes the shared helper while the first caller's write is paused.
        let files = AskpassWriteObservingFileService {
            observations += 1
            // Before first publication, an absent helper is valid; a visible one must be executable.
            guard FileService().fileExists(at: helper) else { return }
            executions += 1
            let mode = try FileManager.default.attributesOfItem(atPath: helper)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700, "A published helper must already be owner-only and executable")
            XCTAssertEqual(try FileService().readFile(at: helper), body)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["Password"]
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            do { try process.run() } catch {
                XCTFail("The shared helper could not execute during replacement: \(error)")
                return
            }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(bytes: bytes, encoding: .utf8), secret)
        }
        let writer = GitService(fileService: files, askpassHelperPath: helper)
        for _ in 0..<2 {
            _ = try writer.childEnvironment(credential: .httpsToken(username: "other", token: "other-fixture-token"))
        }
        XCTAssertGreaterThan(observations, 0, "The replacement must be observed")
        XCTAssertGreaterThan(executions, 0, "A second caller must execute the shared helper")
        let mode = try FileManager.default.attributesOfItem(atPath: helper)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        XCTAssertEqual(try FileService().readFile(at: helper), body)
        XCTAssertEqual(try FileService().listDirectory(at: tempDir), ["askpass"])
    }

    private struct NetworkCredentialOperation {
        let name: String
        let command: String
        let run: () throws -> Void

        init(_ name: String, _ command: String, _ run: @escaping () throws -> Void) {
            self.name = name
            self.command = command
            self.run = run
        }
    }

    func testTokenNeverAppearsInAnyNetworkOpArgv() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let secret = "ghp_\(UUID().uuidString)"
        let credential = GitCredential.httpsToken(username: "u", token: secret)
        let service = try fixture.credentialRecordingExecutable(expectedToken: secret)
        let remote = "https://fixture.test/store.git"
        let root = fixture.root
        let operations: [NetworkCredentialOperation] = [
            .init("clone", "clone", { try service.clone(remote: remote, into: root, credential: credential) }),
            .init("cloneShallow default branch", "clone", {
                try service.cloneShallow(remote: remote, branch: nil, into: root, credential: credential)
            }),
            .init("cloneShallow named branch", "clone", {
                try service.cloneShallow(remote: remote, branch: "main", into: root, credential: credential)
            }),
            .init("remoteHasCommits", "ls-remote", { _ = service.remoteHasCommits(remote: remote, credential: credential) }),
            .init("remoteDefaultBranch", "ls-remote", {
                _ = try service.remoteDefaultBranch(remote: remote, credential: credential)
            }),
            .init("remoteBranches", "ls-remote", { _ = try service.remoteBranches(remote: remote, credential: credential) }),
            .init("remoteHead", "ls-remote", { _ = try service.remoteHead(remote: remote, ref: "main", credential: credential) }),
            .init("fetch", "fetch", { try service.fetch(at: root, credential: credential) }),
            .init("fetchBranch", "fetch", { try service.fetchBranch("main", at: root, credential: credential) }),
            .init("pullRebase", "pull", { _ = try service.pullRebase(at: root, credential: credential) }),
            .init("push", "push", { try service.push(at: root, credential: credential) }),
            .init("collapseToSingleCommit", "fetch", {
                _ = try service.collapseToSingleCommit(at: root, message: "collapsed", credential: credential)
            }),
            .init("fastForwardOnly", "fetch", { _ = try service.fastForwardOnly(at: root, credential: credential) })
        ]
        for operation in operations {
            try assertNetworkCredential(operation.name, command: operation.command, secret: secret, fixture: fixture,
                                        operation: operation.run)
        }
        try assertHistoryNetworkCredentials(service, secret: secret, fixture: fixture)
    }

    private func assertNetworkCredential(
        _ name: String, command: String, secret: String, fixture: GitFailureFixture,
        networkCalls: Int = 1, operation: () throws -> Void
    ) throws {
        // Each operation starts with an empty receipt, so a previous call cannot supply its proof.
        try fixture.files.writeFile(at: fixture.trace, content: "")
        try fixture.files.writeFile(at: fixture.credentialTrace, content: "")
        try operation()
        let argv = try fixture.files.readFile(at: fixture.trace)
        XCTAssertFalse(argv.contains(secret), "\(name): token must be absent from received argv")
        let receipts = try fixture.files.readFile(at: fixture.credentialTrace).split(separator: "\n").filter {
            $0.split(separator: "\t", maxSplits: 1).last?.split(separator: " ").contains(Substring(command)) == true
        }
        XCTAssertEqual(receipts.count, networkCalls, "\(name): network argv receipt must exist for every call")
        for receipt in receipts {
            XCTAssertEqual(receipt.split(separator: "\t", maxSplits: 1).first, "received",
                           "\(name): git must receive the token through its environment")
        }
    }

    private func assertHistoryNetworkCredentials(_ service: GitService, secret: String, fixture: GitFailureFixture) throws {
        let head = String(repeating: "a", count: 40)
        let older = String(repeating: "b", count: 40)
        for (ref, installed) in [("main", head), ("v1", head), ("main", older)] {
            let fetches = ref == "v1" || installed == older ? 2 : 1
            try assertNetworkCredential("upstreamHistory \(ref) installed \(installed)",
                                        command: "fetch", secret: secret, fixture: fixture, networkCalls: fetches) {
                _ = try service.upstreamHistory(UpstreamHistoryGitRequest(
                    remote: "https://fixture.test/store.git", ref: ref, installedCommit: installed,
                    path: "skills/example", repositoryPath: fixture.root, commitLimit: 2, rowLimit: 3,
                    textByteLimit: 1_024, baselineFileLimit: 10, baselineByteLimit: 10_000,
                    credential: .httpsToken(username: "u", token: secret)
                ))
            }
        }
    }

    func testSshAgentSetsNoAskpass() throws {
        // Seed STALE auth vars in the parent process env, then prove childEnvironment sanitizes them
        // for a non-.httpsToken op — a .sshAgent/nil op must never ride an inherited askpass or secret.
        setenv("GIT_ASKPASS", "/tmp/evil-askpass", 1)
        setenv("PENSIEVE_GIT_USERNAME", "stale-user", 1)
        setenv("PENSIEVE_GIT_PASSWORD", "stale-secret", 1)
        defer {
            unsetenv("GIT_ASKPASS"); unsetenv("PENSIEVE_GIT_USERNAME"); unsetenv("PENSIEVE_GIT_PASSWORD")
        }
        let env = try git.childEnvironment(credential: .sshAgent)
        XCTAssertNil(env["GIT_ASKPASS"])           // inherited askpass stripped
        XCTAssertNil(env["PENSIEVE_GIT_USERNAME"]) // inherited username stripped
        XCTAssertNil(env["PENSIEVE_GIT_PASSWORD"]) // inherited secret stripped
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            XCTAssertEqual(env["SSH_AUTH_SOCK"], sock)   // agent socket passes through untouched
        }
    }

    // MARK: 10.4 — inherited git-behavior env stripped (C5); GIT_CONFIG_NOSYSTEM preserved

    func testChildEnvironmentStripsInheritedGitOverridesButPreservesNoSystem() throws {
        setenv("GIT_SSH_COMMAND", "ssh -oProxyCommand=evil", 1); setenv("GIT_CONFIG_COUNT", "1", 1)
        setenv("GIT_CONFIG_KEY_0", "core.pager", 1); setenv("GIT_TRACE", "1", 1)
        setenv("GIT_ALLOW_PROTOCOL", "ext:file:https", 1); setenv("GIT_PROTOCOL_FROM_USER", "1", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)   // HARDENING var — must SURVIVE
        defer {
            unsetenv("GIT_SSH_COMMAND"); unsetenv("GIT_CONFIG_COUNT")
            unsetenv("GIT_CONFIG_KEY_0"); unsetenv("GIT_TRACE")
            unsetenv("GIT_ALLOW_PROTOCOL"); unsetenv("GIT_PROTOCOL_FROM_USER")
            unsetenv("GIT_CONFIG_NOSYSTEM")
        }
        let env = try git.childEnvironment(credential: nil)
        XCTAssertNil(env["GIT_SSH_COMMAND"]); XCTAssertNil(env["GIT_CONFIG_COUNT"])
        XCTAssertNil(env["GIT_CONFIG_KEY_0"])    // GIT_CONFIG_KEY_ prefix, stripped
        XCTAssertNil(env["GIT_TRACE"])           // GIT_TRACE prefix, stripped
        XCTAssertNil(env["GIT_ALLOW_PROTOCOL"]); XCTAssertNil(env["GIT_PROTOCOL_FROM_USER"])
        XCTAssertEqual(env["GIT_CONFIG_NOSYSTEM"], "1")   // hardening var PRESERVED
    }

    func testAskpassHelperWriteFailurePropagates() throws {
        let failingGit = GitService(fileService: AskpassWriteFailingFileService(),
            askpassHelperPath: TestPaths.gitAskpassHelperPath)
        XCTAssertThrowsError(
            try failingGit.childEnvironment(credential: .httpsToken(username: "u", token: "ghp_x"))
        )
    }
}

/// Uses the real filesystem and observes completed writes through the existing FileService boundary.
/// Executable writes inherit the production default, so the observation falls before its next step.
private struct AskpassWriteObservingFileService: FileServiceProtocol {
    let beforeWrite: (String) throws -> Void
    let afterWrite: () throws -> Void
    let beforeDelete: (String) -> Void
    private let wrapped = FileService()

    init(beforeWrite: @escaping (String) throws -> Void = { _ in },
         beforeDelete: @escaping (String) -> Void = { _ in },
         afterWrite: @escaping () throws -> Void = {}) {
        self.beforeWrite = beforeWrite
        self.afterWrite = afterWrite
        self.beforeDelete = beforeDelete
    }

    func writeFile(at path: String, content: String) throws {
        try beforeWrite(path)
        try wrapped.writeFile(at: path, content: content)
        try afterWrite()
    }
    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws {
        beforeDelete(path)
        try wrapped.deleteDirectory(at: path)
    }
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        try wrapped.entryTypeWithoutFollowingLinks(at: path)
    }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}

extension GitServiceTests {
    private func assertFailedCloneCanRetry(remote: String, failure: String) throws {
        let files = FileService()
        let destination = tempDir + "/clone-" + failure
        try files.createDirectory(at: destination)
        let failed = try failingMetadataGit(failure, root: destination)
        XCTAssertThrowsError(try failed.clone(remote: remote, into: destination, credential: nil), failure) { error in
            if failure == "head-probe" { XCTAssertEqual(error as? GitError, .unusable(.licenseNotAccepted)) }
        }
        XCTAssertTrue(files.fileExists(at: destination + "-fault"), "The injected failure must be reached")
        XCTAssertFalse(files.directoryExists(at: destination + "/.git"), "Failed connect must not leave a syncable repo")
        XCTAssertEqual(try files.listDirectory(at: destination), [], "Failed connect must preserve the empty store")
        XCTAssertFalse(files.fileExists(at: destination + "-published"), "Checkout must finish before publication")
        do { try git.clone(remote: remote, into: destination, credential: nil) } catch {
            XCTFail("Retry failed for \(failure): \(error)")
            return
        }
        XCTAssertEqual(try files.readFile(at: destination + "/README.md"), "seed\n", "Retry must deliver the remote")
        XCTAssertTrue(git.isWorktreeClean(at: destination))
    }

    /// Real git delegates keep their argv. Only metadata/checkout failures are simulated; receipts
    /// prove the fault fired and observe whether the canonical store was exposed during checkout.
    private func failingMetadataGit(_ failure: String, root: String) throws -> GitService {
        let files = FileService()
        let executable = root + "-git"
        try files.writeExecutableFile(at: executable, content: metadataFailureScript(failure, root: root))
        let observing = AskpassWriteObservingFileService(beforeWrite: { path in
            if failure == "metadata-write", path.hasSuffix("/info/attributes") {
                try files.writeFile(at: root + "-fault", content: "metadata write refused")
                throw AskpassWriteBoom()
            }
        }, beforeDelete: { path in
            XCTAssertTrue(files.directoryExists(at: path), "Cleanup must not delete an absent clone folder")
        })
        return GitService(fileService: observing, askpassHelperPath: tempDir + "/askpass", executablePath: executable)
    }

    private func metadataFailureScript(_ failure: String, root: String) -> String {
        """
            #!/bin/sh
            fail_command() {
                repository=''
                \(FakeGitScript.skipGlobalOptions)
                failure='\(failure)'
                if [ "$1" = clone ] && [ "$failure" = clone ]; then
                    touch '\(root)-fault'; echo 'clone failed' >&2; exit 128
                fi
                if [ "$1 $2" = 'rev-parse --path-format=absolute' ] && [ "$failure" = metadata-path ]; then
                    touch '\(root)-fault'; echo 'metadata lookup failed' >&2; exit 128
                fi
                if [ "$1 $2" = 'rev-parse HEAD' ] || [ "$1" = for-each-ref ]; then
                    case "$failure" in
                      head-probe) touch '\(root)-fault'; echo 'Xcode license not accepted' >&2; exit 69 ;;
                      head-read) touch '\(root)-fault'; echo 'head observation failed' >&2; exit 128 ;;
                    esac
                fi
                if [ "$1" = --version ] && [ "$failure" = head-probe ] && [ -f '\(root)-fault' ]; then
                    echo 'Xcode license not accepted' >&2; exit 69
                fi
                if [ "$1" = checkout ]; then
                    if [ -d '\(root)/.git' ]; then touch '\(root)-published'; fi
                    case "$failure" in
                      checkout|terminated-checkout)
                        touch '\(root)-fault'; echo 'partial checkout' > "$repository/README.md"
                        if [ "$failure" = terminated-checkout ]; then kill -TERM "$$"; fi
                        echo 'checkout failed' >&2; exit 128 ;;
                    esac
                fi
            }
            fail_command "$@"
            exec /usr/bin/git "$@"
            """ + "\n"
    }
}

extension GitServiceTests {
    private func assertCloneRefusesOccupiedStore(remote: String, destination: String) throws {
        let files = FileService()
        let trace = tempDir + "/occupied-trace"
        let executable = tempDir + "/occupied-git"
        try files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            touch '\(trace)'
            exec /usr/bin/git "$@"
            """ + "\n")
        let recording = GitService(askpassHelperPath: tempDir + "/askpass", executablePath: executable)
        XCTAssertThrowsError(try recording.clone(remote: remote, into: destination, credential: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists and is not an empty directory"))
        }
        XCTAssertFalse(files.fileExists(at: trace), "An occupied store must refuse before downloading")
    }

    private func assertClonePublicationRace(remote: String) throws {
        let files = FileService()
        let destination = tempDir + "/publication-race"
        try files.createDirectory(at: destination)
        let observing = AskpassWriteObservingFileService(beforeWrite: { path in
            if path.hasSuffix("/info/attributes") {
                try files.writeFile(at: destination + "/keep", content: "arrived during download")
            }
        })
        let cloning = GitService(fileService: observing, askpassHelperPath: tempDir + "/askpass")
        XCTAssertThrowsError(try cloning.clone(remote: remote, into: destination, credential: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists and is not an empty directory"))
        }
        XCTAssertEqual(try files.readFile(at: destination + "/keep"), "arrived during download")
        XCTAssertFalse(files.directoryExists(at: destination + "/.git"))
    }
}
