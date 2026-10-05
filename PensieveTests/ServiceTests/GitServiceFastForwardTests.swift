import XCTest
@testable import Pensieve

/// PLAN-12 / 12.4 — fast-forward-only git primitives over real `file://` bare-repo fixtures (the
/// PLAN-08/09 pattern, mirrored from GitServiceRebaseTests). Proves `fastForwardOnly` fast-forwards a
/// clean clone, leaves a diverged HEAD/worktree untouched, and reports up-to-date otherwise; and that
/// `isWorktreeClean` reflects uncommitted edits.
final class GitServiceFastForwardTests: XCTestCase {
    private var tempDir: String!
    private var git: GitService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveGitServiceFastForwardTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        git = GitService()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    // MARK: Fixture helpers (mirror GitServiceRebaseTests)

    @discardableResult
    private func rawGit(_ args: [String], in dir: String? = nil) throws -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(bytes: outData, encoding: .utf8) ?? "", p.terminationStatus)
    }

    private func porcelain(_ dir: String) throws -> String {
        try rawGit(["-C", dir, "status", "--porcelain"]).out
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

    // MARK: (a) clean clone + upstream commit → .fastForwarded, HEAD moves

    func testFastForwardsCleanCloneWhenUpstreamAdvances() throws {
        let remote = try seedRemote { try write("README.md", "base\n", in: $0) }
        let cloneA = try clone(remote, named: "aheadA-\(UUID().uuidString)")
        let cloneB = try clone(remote, named: "behindB-\(UUID().uuidString)")

        try write("feature.txt", "from A\n", in: cloneA)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "A adds feature"))
        try git.push(at: cloneA, credential: nil)

        let before = try XCTUnwrap(git.headSHA(at: cloneB))
        let result = try git.fastForwardOnly(at: cloneB, credential: nil)
        let after = try XCTUnwrap(git.headSHA(at: cloneB))

        XCTAssertEqual(result, .fastForwarded(from: before, to: after))
        XCTAssertNotEqual(before, after)                               // HEAD moved
        XCTAssertEqual(try String(contentsOfFile: cloneB + "/feature.txt", encoding: .utf8), "from A\n")
    }

    // MARK: (b) upstream + local divergent commit → .diverged, HEAD + worktree unchanged

    func testDivergedLeavesHeadAndWorktreeUntouched() throws {
        let remote = try seedRemote { try write("README.md", "base\n", in: $0) }
        let cloneA = try clone(remote, named: "divergeA-\(UUID().uuidString)")
        let cloneB = try clone(remote, named: "divergeB-\(UUID().uuidString)")

        try write("from-a.txt", "A\n", in: cloneA)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "A commit"))
        try git.push(at: cloneA, credential: nil)

        // cloneB makes its OWN local commit without pulling → the two histories diverge.
        try write("from-b.txt", "B\n", in: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "B commit"))
        // ...plus an extra UNCOMMITTED edit, so the worktree-preservation assertion is substantive
        // (a `.diverged` that secretly reset --hard / checked out would blow this away).
        try write("dirty.txt", "uncommitted\n", in: cloneB)

        let beforeHead = try XCTUnwrap(git.headSHA(at: cloneB))
        let beforeStatus = try porcelain(cloneB)

        let result = try git.fastForwardOnly(at: cloneB, credential: nil)

        XCTAssertEqual(result, .diverged)
        XCTAssertEqual(try git.headSHA(at: cloneB), beforeHead)            // HEAD unmoved
        XCTAssertEqual(try porcelain(cloneB), beforeStatus)           // worktree unmoved (incl. uncommitted)
    }

    // MARK: (c) no upstream change → .upToDate

    func testUpToDateWhenNoUpstreamChange() throws {
        let remote = try seedRemote { try write("README.md", "base\n", in: $0) }
        let cloneB = try clone(remote, named: "uptodateB-\(UUID().uuidString)")

        let before = try XCTUnwrap(git.headSHA(at: cloneB))
        let result = try git.fastForwardOnly(at: cloneB, credential: nil)

        XCTAssertEqual(result, .upToDate)
        XCTAssertEqual(try git.headSHA(at: cloneB), before)               // HEAD unchanged
    }

    // MARK: (d) uncommitted edit → isWorktreeClean false

    func testIsWorktreeCleanReflectsUncommittedEdits() throws {
        let remote = try seedRemote { try write("README.md", "base\n", in: $0) }
        let cloneB = try clone(remote, named: "cleanB-\(UUID().uuidString)")

        XCTAssertTrue(git.isWorktreeClean(at: cloneB))                // fresh clone is clean

        try write("scratch.txt", "uncommitted\n", in: cloneB)
        XCTAssertFalse(git.isWorktreeClean(at: cloneB))              // untracked file → not clean
    }
}
