import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testShallowProbeFailureThrowsInsteadOfReportingCompleteHistory() {
        let git = GitService(fileService: fileService, askpassHelperPath: TestPaths.gitAskpassHelperPath)

        XCTAssertThrowsError(try git.isShallowRepository(at: tempDir + "/missing-repository"))
    }

    func testTrackedRefPrefersBranchOverSameNamedTag() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "base\n", in: repository)
        let base = try commit(repository, message: "base", timestamp: 1_700_020_001)
        XCTAssertEqual(try rawGit(["-C", repository, "branch", "release", base]).exit, 0)

        try write("skills/demo/SKILL.md", text: "tag\n", in: repository)
        let tagCommit = try commit(repository, message: "tag commit", timestamp: 1_700_020_002)
        XCTAssertEqual(try rawGit(["-C", repository, "tag", "release", tagCommit]).exit, 0)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "release"]).exit, 0)
        try write("skills/demo/SKILL.md", text: "branch\n", in: repository)
        let branchCommit = try commit(repository, message: "branch commit", timestamp: 1_700_020_003)
        try write("SKILL.md", text: "branch\n", in: localDirectory)

        let result = try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                ref: "release",
                installedCommit: branchCommit,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.headCommit, branchCommit)
        XCTAssertEqual(result.rows.first?.sha, branchCommit)
        XCTAssertFalse(result.rows.contains(where: { $0.sha == tagCommit }))
        XCTAssertEqual(result.installedPosition, .at(sha: branchCommit))
    }

    func testAnnotatedTagHeadIsPeeledToItsCommit() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "tagged\n", in: repository)
        let taggedCommit = try commit(repository, message: "tagged commit", timestamp: 1_700_021_001)
        let tag = try rawGit([
            "-C", repository, "-c", "user.name=History Author",
            "-c", "user.email=history@example.com", "tag", "-a", "v1", "-m", "version one"
        ])
        XCTAssertEqual(tag.exit, 0, tag.stderr)
        let tagObject = try revision("v1^{tag}", in: repository)
        try write("SKILL.md", text: "tagged\n", in: localDirectory)

        let result = try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                ref: "v1",
                installedCommit: taggedCommit,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.headCommit, taggedCommit)
        XCTAssertNotEqual(result.headCommit, tagObject)
        XCTAssertEqual(result.installedPosition, .at(sha: taggedCommit))
    }

    func testMergeThatChangesSkillPathIsRowAndInstalledPosition() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "base\n", in: repository)
        let base = try commit(repository, message: "base", timestamp: 1_700_022_001)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "-b", "side", base]).exit, 0)
        try write("side.txt", text: "side\n", in: repository)
        _ = try commit(repository, message: "side", timestamp: 1_700_022_002)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "main"]).exit, 0)
        try write("main.txt", text: "main\n", in: repository)
        _ = try commit(repository, message: "main", timestamp: 1_700_022_003)
        let merge = try rawGit(["-C", repository, "merge", "--no-ff", "--no-commit", "side"])
        XCTAssertEqual(merge.exit, 0, merge.stderr)
        try write("skills/demo/SKILL.md", text: "evil merge\n", in: repository)
        let mergeCommit = try commit(repository, message: "evil merge", timestamp: 1_700_022_004)
        try write("SKILL.md", text: "evil merge\n", in: localDirectory)

        let result = try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                installedCommit: mergeCommit,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )

        let row = try XCTUnwrap(result.rows.first(where: { $0.sha == mergeCommit }))
        XCTAssertEqual(row.filesChanged, 1)
        XCTAssertEqual(row.linesAdded, 1)
        XCTAssertEqual(row.linesRemoved, 1)
        XCTAssertEqual(result.installedPosition, .at(sha: mergeCommit))
    }

    func testUnrelatedMergeResolvesInstalledPositionToEarlierFirstParentChange() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "base\n", in: repository)
        let base = try commit(repository, message: "base", timestamp: 1_700_023_001)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "-b", "side", base]).exit, 0)
        try write("side.txt", text: "side\n", in: repository)
        _ = try commit(repository, message: "side", timestamp: 1_700_023_002)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "main"]).exit, 0)
        try write("skills/demo/SKILL.md", text: "installed\n", in: repository)
        let pathCommit = try commit(repository, message: "path", timestamp: 1_700_023_003)
        let merge = try rawGit(["-C", repository, "merge", "--no-ff", "-m", "merge side", "side"])
        XCTAssertEqual(merge.exit, 0, merge.stderr)
        let mergeCommit = try revision("HEAD", in: repository)
        try write("SKILL.md", text: "installed\n", in: localDirectory)

        let result = try read(repository: repository, installedCommit: mergeCommit)

        XCTAssertFalse(result.rows.contains(where: { $0.sha == mergeCommit }))
        XCTAssertTrue(result.rows.contains(where: { $0.sha == pathCommit }))
        XCTAssertEqual(result.installedPosition, .at(sha: pathCommit))
    }

    func testMergeBringingPathChangeIsRowAndInstalledPosition() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "base\n", in: repository)
        let base = try commit(repository, message: "base", timestamp: 1_700_024_001)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "-b", "side", base]).exit, 0)
        try write("skills/demo/SKILL.md", text: "installed\n", in: repository)
        _ = try commit(repository, message: "side path", timestamp: 1_700_024_002)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "main"]).exit, 0)
        try write("main.txt", text: "main\n", in: repository)
        _ = try commit(repository, message: "main", timestamp: 1_700_024_003)
        let merge = try rawGit(["-C", repository, "merge", "--no-ff", "-m", "merge side", "side"])
        XCTAssertEqual(merge.exit, 0, merge.stderr)
        let mergeCommit = try revision("HEAD", in: repository)
        try write("SKILL.md", text: "installed\n", in: localDirectory)

        let result = try read(repository: repository, installedCommit: mergeCommit)

        let row = try XCTUnwrap(result.rows.first(where: { $0.sha == mergeCommit }))
        XCTAssertEqual(row.filesChanged, 1)
        XCTAssertEqual(row.linesAdded, 1)
        XCTAssertEqual(row.linesRemoved, 1)
        XCTAssertEqual(result.installedPosition, .at(sha: mergeCommit))
    }

    private func read(repository: String, installedCommit: String) throws -> UpstreamHistoryResult {
        try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                installedCommit: installedCommit,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )
    }
}
