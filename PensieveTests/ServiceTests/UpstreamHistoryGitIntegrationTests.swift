import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testRealGitHistoryFiltersPathParsesStatsAndFindsInstalledPosition() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "version one\n", in: repository)
        try write("skills/demo/notes.txt", text: "alpha\n", in: repository)
        let first = try commit(repository, message: "create demo", timestamp: 1_700_000_001)
        try write("skills/demo/SKILL.md", text: "version one\n", in: localDirectory)
        try write("skills/demo/notes.txt", text: "alpha\n", in: localDirectory)
        let installedHash = try stableHash(at: localDirectory)

        try write("README.md", text: "unrelated\n", in: repository)
        let installedHead = try commit(repository, message: "repository only", timestamp: 1_700_000_002)
        try write("skills/demo/SKILL.md", text: "version two\n", in: repository)
        try write("skills/demo/notes.txt", text: "alpha\nbeta\n", in: repository)
        let textChange = try commit(repository, message: "update demo", timestamp: 1_700_000_003)
        try write("skills/demo/image.bin", data: Data([0, 1, 2, 3]), in: repository)
        let binaryChange = try commit(repository, message: "binary only", timestamp: 1_700_000_004)
        try FileManager.default.removeItem(atPath: repository + "/skills/demo/SKILL.md")
        let removedSkill = try commit(repository, message: "move instructions", timestamp: 1_700_000_005)
        try write("skills/demo/odd\n\"name.txt", text: "one\ntwo\n", in: repository)
        let hostileSubject = "odd\u{1f}subject\u{2028}next\u{1b}[31mred"
        let oddName = try commit(repository, message: hostileSubject, timestamp: 1_700_000_006)

        let result = try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                installedCommit: installedHead,
                contentHash: installedHash
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.rows.map(\.sha), [oddName, removedSkill, binaryChange, textChange, first])
        XCTAssertEqual(result.installedPosition, .at(sha: first))
        XCTAssertEqual(result.rows[0].filesChanged, 1)
        XCTAssertEqual(result.rows[0].linesAdded, 2)
        XCTAssertEqual(result.rows[0].linesRemoved, 0)
        XCTAssertEqual(result.rows[0].subject, "odd subject nextred")
        XCTAssertNil(result.rows[0].skillMarkdown)
        XCTAssertEqual(result.rows[2].filesChanged, 1)
        XCTAssertNil(result.rows[2].linesAdded)
        XCTAssertNil(result.rows[2].linesRemoved)
        XCTAssertEqual(result.rows[3].author, "History Author")
        XCTAssertEqual(result.rows[3].date, Date(timeIntervalSince1970: 1_700_000_003))
        XCTAssertEqual(result.rows[3].subject, "update demo")
        XCTAssertEqual(result.rows[3].skillMarkdown, .text("version two\n"))
        XCTAssertEqual(result.localEdits, .none)
        XCTAssertEqual(result.installedBaseline?.files?.map(\.path), ["SKILL.md", "notes.txt"])
        XCTAssertFalse(result.hasOlderHistory)
        try assertScratchEmpty()
    }

    func testHistoryWindowsGrowWithoutReorderingAndEventuallyReachInstalledRow() throws {
        let repository = try makeRepository()
        var commits: [String] = []
        for index in 1 ... 22 {
            let body = "version \(index)\n"
            try write("skills/demo/SKILL.md", text: body, in: repository)
            commits.append(try commit(
                repository,
                message: "version \(index)",
                timestamp: 1_700_001_000 + index
            ))
            if index == 1 { try write("SKILL.md", text: body, in: localDirectory) }
        }
        let installedHash = try stableHash(at: localDirectory)
        let stored = origin(
            repo: URL(fileURLWithPath: repository).absoluteString,
            installedCommit: commits[0],
            contentHash: installedHash
        )

        let firstWindow = try service().read(origin: stored, localDirectory: localDirectory)
        let secondWindow = try service().read(
            origin: stored,
            localDirectory: localDirectory,
            windowCount: 2
        )

        XCTAssertEqual(firstWindow.rows.count, UpstreamHistoryService.rowWindow)
        XCTAssertTrue(firstWindow.hasOlderHistory)
        XCTAssertEqual(firstWindow.installedPosition, .olderThanRowsRead)
        XCTAssertEqual(Array(secondWindow.rows.prefix(firstWindow.rows.count)), firstWindow.rows)
        XCTAssertEqual(secondWindow.rows.count, 22)
        XCTAssertEqual(secondWindow.installedPosition, .at(sha: commits[0]))
        XCTAssertFalse(secondWindow.hasOlderHistory)
        XCTAssertEqual(secondWindow.rows.map(\.sha), commits.reversed())
    }

    func testCommitOutsideTrackedRefReportsNotInHistoryAndCarriesNoBaseline() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "main one\n", in: repository)
        let mainOne = try commit(repository, message: "main one", timestamp: 1_700_002_001)
        try write("skills/demo/SKILL.md", text: "main two\n", in: repository)
        _ = try commit(repository, message: "main two", timestamp: 1_700_002_003)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "-b", "removed", mainOne]).exit, 0)
        try write("skills/demo/SKILL.md", text: "removed branch\n", in: repository)
        let removed = try commit(repository, message: "removed", timestamp: 1_700_002_002)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "main"]).exit, 0)
        XCTAssertEqual(try rawGit(["-C", repository, "branch", "-D", "removed"]).exit, 0)
        try write("SKILL.md", text: "removed branch\n", in: localDirectory)

        let result = try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                installedCommit: removed,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.installedPosition, .notInRefHistory)
        XCTAssertNil(result.installedBaseline)
    }

    func testOversizedSkillMarkdownIsExplicitlyTooLargeInRowAndBaseline() throws {
        let repository = try makeRepository()
        let large = String(repeating: "x", count: UpstreamHistoryService.textByteLimit + 1)
        try write("skills/demo/SKILL.md", text: large, in: repository)
        let installed = try commit(repository, message: "large", timestamp: 1_700_003_001)
        try write("SKILL.md", text: large, in: localDirectory)

        let result = try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                installedCommit: installed,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.rows.first?.skillMarkdown, .tooLarge)
        XCTAssertEqual(result.installedBaseline?.files?.first?.content, .tooLarge)
    }

    func testRealGitMissingRefUsesUpdateCheckBoundaryCopy() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "body\n", in: repository)
        let installed = try commit(repository, message: "initial", timestamp: 1_700_004_001)
        try write("SKILL.md", text: "body\n", in: localDirectory)

        XCTAssertThrowsError(try service().read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                ref: "missing-ref",
                installedCommit: installed,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                UpdateCheckError.trackedRefNotFound("missing-ref").localizedDescription
            )
            XCTAssertEqual(error as? UpstreamHistoryError, .trackedRefNotFound("missing-ref"))
        }
    }

    func testAggregateBaselineByteLimitIsExplicitlyTooLarge() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "body\n", in: repository)
        let installed = try commit(repository, message: "initial", timestamp: 1_700_005_001)
        try write("SKILL.md", text: "body\n", in: localDirectory)

        let result = try service(baselineByteLimit: 1).read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                installedCommit: installed,
                contentHash: try stableHash(at: localDirectory)
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.installedBaseline, .tooLarge)
    }
}
