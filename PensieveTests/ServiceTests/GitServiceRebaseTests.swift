import XCTest
@testable import Pensieve

/// PLAN-09 / 09.1 — conflict-resolution git primitives over real temp file:// repositories.
final class GitServiceRebaseTests: XCTestCase {
    private var tempDir: String!
    private var git: GitService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveGitServiceRebaseTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        git = TestPaths.git
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    private struct RawResult {
        let out: String
        let err: String
        let code: Int32
    }

    @discardableResult
    private func rawGit(_ args: [String], in dir: String? = nil) throws -> RawResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        p.environment = env
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RawResult(out: String(bytes: outData, encoding: .utf8) ?? "",
                         err: String(bytes: errData, encoding: .utf8) ?? "",
                         code: p.terminationStatus)
    }

    private func seedRemote(writeSeed: (String) throws -> Void) throws -> String {
        let remotePath = tempDir + "/remote-\(UUID().uuidString).git"
        XCTAssertEqual(try rawGit(["init", "--bare", remotePath]).code, 0)
        let remote = "file://" + remotePath
        let seed = tempDir + "/seed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try git.initRepository(at: seed)
        try git.setRemote(remote, at: seed)
        try writeSeed(seed)
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        return remote
    }

    private func clone(_ remote: String, named name: String) throws -> String {
        let path = tempDir + "/" + name
        try git.clone(remote: remote, into: path, credential: nil)
        return path
    }

    private func write(_ relativePath: String, _ content: String, in root: String) throws {
        let fullPath = root + "/" + relativePath
        let parent = (fullPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
    }

    private func remove(_ relativePath: String, in root: String) throws {
        let fullPath = root + "/" + relativePath
        if FileManager.default.fileExists(atPath: fullPath) {
            try FileManager.default.removeItem(atPath: fullPath)
        }
    }

    private func skillMarkdown(body: String) -> String {
        "---\nname: demo\ndescription: demo skill\n---\n\n\(body)\n"
    }

    private func makeTwoCloneConflict(
        aBody: String, bBody: String,
        beforeRebase: (String) throws -> Void = { _ in }
    ) throws -> (cloneB: String, path: String) {
        let path = "skills/demo/SKILL.md"
        let remote = try seedRemote { seed in
            try write(path, skillMarkdown(body: "base"), in: seed)
        }
        let cloneA = try clone(remote, named: "cloneA-\(UUID().uuidString)")
        let cloneB = try clone(remote, named: "cloneB-\(UUID().uuidString)")
        try write(path, skillMarkdown(body: aBody), in: cloneA)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "A edits demo"))
        try git.push(at: cloneA, credential: nil)
        try write(path, skillMarkdown(body: bBody), in: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "B edits demo"))
        // Optional hook to configure cloneB BEFORE the rebase captures its options (e.g. bad signing).
        try beforeRebase(cloneB)
        XCTAssertEqual(try git.pullRebase(at: cloneB, credential: nil), .conflicted([path]))
        return (cloneB, path)
    }

    func testStageMappingAndContinueRebase() throws {
        let (cloneB, path) = try makeTwoCloneConflict(aBody: "OTHER machine line", bBody: "THIS machine line")
        XCTAssertEqual(try git.blob(atStage: 2, path: path, in: cloneB), skillMarkdown(body: "OTHER machine line"))
        XCTAssertEqual(try git.blob(atStage: 3, path: path, in: cloneB), skillMarkdown(body: "THIS machine line"))

        try write(path, skillMarkdown(body: "THIS machine line"), in: cloneB)
        try git.stagePath(path, at: cloneB)
        XCTAssertEqual(try git.continueRebase(at: cloneB), .merged)
        XCTAssertTrue(try git.conflictedFiles(at: cloneB).isEmpty)
    }

    func testKeepOtherEmptyCommitSkipsAndLeavesNothingToPush() throws {
        let (cloneB, path) = try makeTwoCloneConflict(aBody: "Other wins", bBody: "This loses")
        let otherSide = try XCTUnwrap(git.blob(atStage: 2, path: path, in: cloneB))
        try write(path, otherSide, in: cloneB)
        try git.stagePath(path, at: cloneB)

        XCTAssertEqual(try git.continueRebase(at: cloneB), .merged)
        XCTAssertFalse(try git.hasCommitsToPush(at: cloneB))
        XCTAssertEqual(try String(contentsOfFile: cloneB + "/" + path, encoding: .utf8), otherSide)
    }

    func testAddAddAndDeleteModifyBlobShapes() throws {
        try assertAddAddConflictHasBothSides()
        try assertDeleteModifyConflictHasNilSide()
    }

    private func assertAddAddConflictHasBothSides() throws {
        let path = "skills/new-skill/SKILL.md"
        let remote = try seedRemote { seed in
            try write("README.md", "seed\n", in: seed)
        }
        let cloneA = try clone(remote, named: "addA-\(UUID().uuidString)")
        let cloneB = try clone(remote, named: "addB-\(UUID().uuidString)")
        try write(path, skillMarkdown(body: "Added by other"), in: cloneA)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "A adds skill"))
        try git.push(at: cloneA, credential: nil)
        try write(path, skillMarkdown(body: "Added by this"), in: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "B adds skill"))
        XCTAssertEqual(try git.pullRebase(at: cloneB, credential: nil), .conflicted([path]))

        let other = try git.blob(atStage: 2, path: path, in: cloneB)
        let this = try git.blob(atStage: 3, path: path, in: cloneB)
        XCTAssertNotNil(other)
        XCTAssertNotNil(this)
        XCTAssertNotEqual(other, this)
    }

    private func assertDeleteModifyConflictHasNilSide() throws {
        let path = "skills/delete-modify/SKILL.md"
        let remote = try seedRemote { seed in
            try write(path, skillMarkdown(body: "base"), in: seed)
        }
        let cloneA = try clone(remote, named: "deleteA-\(UUID().uuidString)")
        let cloneB = try clone(remote, named: "modifyB-\(UUID().uuidString)")
        try remove(path, in: cloneA)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "A deletes skill"))
        try git.push(at: cloneA, credential: nil)
        try write(path, skillMarkdown(body: "B modifies skill"), in: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "B modifies skill"))
        XCTAssertEqual(try git.pullRebase(at: cloneB, credential: nil), .conflicted([path]))

        let side2 = try git.blob(atStage: 2, path: path, in: cloneB)
        let side3 = try git.blob(atStage: 3, path: path, in: cloneB)
        XCTAssertNotEqual(side2 == nil, side3 == nil, "delete/modify must have exactly one absent side")
    }

    func testCollapseToSingleCommitLeavesOneCommitAhead() throws {
        let remote = try seedRemote { seed in
            try write("README.md", "seed\n", in: seed)
        }
        let cloneB = try clone(remote, named: "collapse-\(UUID().uuidString)")
        try write("one.txt", "one\n", in: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "one"))
        try write("two.txt", "two\n", in: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "two"))

        XCTAssertTrue(try git.collapseToSingleCommit(at: cloneB, message: "collapsed", credential: nil))
        let count = try rawGit(["rev-list", "--count", "origin/main..HEAD"], in: cloneB).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(count, "1")
    }

    func testNonEmptyContinueFailureDoesNotSkip() throws {
        // Force `rebase --continue` to FAIL at the COMMIT step while a NON-empty resolution is staged:
        // require signing but point `gpg.program` at a program that always fails, configured BEFORE the
        // rebase starts so the rebase captures it. This shape is what proves the empty-skip guard: a
        // blind `rebase --skip` WOULD still succeed here and silently drop the resolved commit (verified:
        // `--continue` errors "gpg failed to sign", `--skip` completes and resets to the other side). An
        // `index.lock` cannot prove this — it blocks BOTH `--continue` and `--skip`, so the two are
        // indistinguishable. With the real guard, `continueRebase` sees the staged tree is non-empty
        // (not proven empty) and THROWS instead of skipping.
        let (cloneB, path) = try makeTwoCloneConflict(aBody: "Other text", bBody: "This text") { repo in
            try self.rawGit(["config", "commit.gpgsign", "true"], in: repo)
            try self.rawGit(["config", "gpg.program", "/usr/bin/false"], in: repo)
        }
        let resolved = skillMarkdown(body: "Resolved non-empty content")
        try write(path, resolved, in: cloneB)
        try git.stagePath(path, at: cloneB)

        XCTAssertThrowsError(try git.continueRebase(at: cloneB)) { error in
            guard case GitError.commandFailed = error else { return XCTFail("expected commandFailed") }
        }
        // The resolved content survived (a blind skip would have reset it to the other side) and the
        // rebase is still in progress — nothing was silently skipped.
        XCTAssertEqual(try String(contentsOfFile: cloneB + "/" + path, encoding: .utf8), resolved)
        XCTAssertTrue(git.isRebaseInProgress(at: cloneB), "a git failure must not be silently skipped")
    }

    func testChildEnvironmentIsNonInteractive() throws {
        let env = try git.childEnvironment(credential: nil)
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(env["GIT_EDITOR"], "true")
        XCTAssertEqual(env["GIT_SEQUENCE_EDITOR"], "true")
    }

    func testLogAndShowSkillHistory() throws {
        let root = tempDir + "/history-\(UUID().uuidString)"
        let path = "skills/history/SKILL.md"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git.initRepository(at: root)

        let original = skillMarkdown(body: "original body")
        try write(path, original, in: root)
        XCTAssertTrue(try git.stageAllAndCommit(at: root, message: "original skill"))
        try write(path, skillMarkdown(body: "second body"), in: root)
        XCTAssertTrue(try git.stageAllAndCommit(at: root, message: "second skill"))
        try write(path, skillMarkdown(body: "third body"), in: root)
        XCTAssertTrue(try git.stageAllAndCommit(at: root, message: "third skill"))

        let commits = git.log(forPath: path, at: root, limit: 10)
        XCTAssertEqual(commits.map(\.subject), ["third skill", "second skill", "original skill"])
        XCTAssertEqual(commits.count, 3)
        XCTAssertFalse(commits.contains { $0.sha.isEmpty || $0.author.isEmpty })

        let oldest = try XCTUnwrap(commits.last)
        XCTAssertEqual(git.show(sha: oldest.sha, path: path, at: root), original)
        XCTAssertNil(git.show(sha: oldest.sha, path: "skills/missing/SKILL.md", at: root))
    }

    func testLogResultThrowsOnCommandFailure() {
        XCTAssertThrowsError(try git.logResult(
            forPath: "skills/history/SKILL.md",
            at: tempDir + "/missing-repo",
            limit: 10
        )) { error in
            guard case GitError.commandFailed = error else {
                return XCTFail("expected commandFailed, got \(error)")
            }
        }
    }
}
