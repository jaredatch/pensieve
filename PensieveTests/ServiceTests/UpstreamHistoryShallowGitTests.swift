import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testShippingHistoryLimitsStayPinned() throws {
        let git = RecordingUpstreamHistoryGit(result: .success(UpstreamHistoryGitSnapshot(
            headCommit: String(repeating: "a", count: 40),
            rows: [],
            installedPosition: .notInRefHistory,
            hasMoreCommits: false,
            installedBaseline: nil
        )))
        let reader = service(git: git, contentHasher: FixedContentHasher(value: "same"))
        _ = try reader.read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "b", count: 40),
                contentHash: "same"
            ),
            localDirectory: localDirectory
        )

        let request = try XCTUnwrap(git.requests.first)
        XCTAssertEqual(request.commitLimit, 200)
        XCTAssertEqual(request.rowLimit, 21)
        XCTAssertEqual(request.textByteLimit, 256 * 1_024)
        XCTAssertEqual(request.baselineFileLimit, 512)
        XCTAssertEqual(request.baselineByteLimit, 8 * 1_024 * 1_024)
    }

    func testShallowReadFetchesOldInstalledBaselineAndExcludesBoundaryCommit() throws {
        let repository = try makeRepository()
        var commits: [String] = []
        for version in 1 ... 6 {
            let body = "version \(version)\n"
            try write("skills/demo/SKILL.md", text: body, in: repository)
            commits.append(try commit(
                repository,
                message: "version \(version)",
                timestamp: 1_700_010_000 + version
            ))
            if version == 1 { try write("SKILL.md", text: body, in: localDirectory) }
        }
        let installedHash = try stableHash(at: localDirectory)
        try write("SKILL.md", text: "locally edited\n", in: localDirectory)

        let result = try service(commitWindow: 2, rowWindow: 3).read(
            origin: origin(
                repo: URL(fileURLWithPath: repository).absoluteString,
                installedCommit: commits[0],
                contentHash: installedHash
            ),
            localDirectory: localDirectory
        )

        XCTAssertEqual(result.rows.map(\.sha), [commits[5], commits[4]])
        XCTAssertFalse(result.rows.map(\.sha).contains(commits[3]), "shallow boundary is not a row")
        XCTAssertTrue(result.hasOlderHistory, "a shallow clone proves that older history remains")
        XCTAssertEqual(result.installedPosition, .olderThanRowsRead)
        XCTAssertEqual(result.installedBaseline?.files?.map(\.path), ["SKILL.md"])
        guard case let .changed(changes) = result.localEdits else {
            return XCTFail("the fetched installed baseline must measure local edits")
        }
        XCTAssertEqual(changes.first?.linesAdded, 1)
        XCTAssertEqual(changes.first?.linesRemoved, 1)
    }

    func testShallowOutsideRefStaysOlderUntilRootThenBecomesNotInHistory() throws {
        let repository = try makeRepository()
        try write("skills/demo/SKILL.md", text: "main one\n", in: repository)
        let forkPoint = try commit(repository, message: "main one", timestamp: 1_700_011_001)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "-b", "removed", forkPoint]).exit, 0)
        try write("skills/demo/SKILL.md", text: "removed\n", in: repository)
        let removed = try commit(repository, message: "removed", timestamp: 1_700_011_002)
        XCTAssertEqual(try rawGit(["-C", repository, "checkout", "main"]).exit, 0)
        for version in 2 ... 5 {
            try write("skills/demo/SKILL.md", text: "main \(version)\n", in: repository)
            _ = try commit(repository, message: "main \(version)", timestamp: 1_700_011_000 + version)
        }
        XCTAssertEqual(try rawGit(["-C", repository, "branch", "-D", "removed"]).exit, 0)
        try write("SKILL.md", text: "removed\n", in: localDirectory)
        let stored = origin(
            repo: URL(fileURLWithPath: repository).absoluteString,
            installedCommit: removed,
            contentHash: try stableHash(at: localDirectory)
        )
        let reader = service(commitWindow: 2, rowWindow: 2)

        let shallow = try reader.read(origin: stored, localDirectory: localDirectory)
        let throughRoot = try reader.read(
            origin: stored,
            localDirectory: localDirectory,
            windowCount: 3
        )

        XCTAssertEqual(shallow.installedPosition, .olderThanRowsRead)
        XCTAssertTrue(shallow.hasOlderHistory)
        XCTAssertEqual(throughRoot.installedPosition, .notInRefHistory)
        XCTAssertFalse(throughRoot.hasOlderHistory)
        XCTAssertNil(throughRoot.installedBaseline)
    }

    func testBothNetworkCallSitesCarryIsolationRemoteAndRequestCredential() throws {
        let repository = try repositoryWithVersions(4)
        let installed = try revision("HEAD~3", in: repository)
        let remote = URL(fileURLWithPath: repository).absoluteString
        let executor = GitService(fileService: fileService, askpassHelperPath: TestPaths.gitAskpassHelperPath)
        var invocations: [([String], GitCredential?)] = []
        let git = GitService(
            fileService: fileService,
            askpassHelperPath: TestPaths.gitAskpassHelperPath,
            upstreamHistoryNetworkRunner: { args, credential in
                invocations.append((args, credential))
                return try executor.run(args, in: nil, credential: credential)
            }
        )

        _ = try git.upstreamHistory(UpstreamHistoryGitRequest(
            remote: remote,
            ref: "main",
            installedCommit: installed,
            path: "skills/demo",
            repositoryPath: tempDir + "/network-calls",
            commitLimit: 2,
            rowLimit: 3,
            textByteLimit: 1_024,
            baselineFileLimit: 10,
            baselineByteLimit: 10_000,
            credential: .sshAgent
        ))

        XCTAssertEqual(invocations.count, 2)
        for (args, credential) in invocations {
            XCTAssertEqual(Array(args.prefix(2)), GitService.installCredentialIsolationArgs)
            let terminator = try XCTUnwrap(args.lastIndex(of: "--"))
            XCTAssertEqual(args[args.index(after: terminator)], remote)
            XCTAssertEqual(credential, .sshAgent)
        }
    }

    func testFailedInstalledCommitFetchIsUnavailableRegardlessOfGitWording() throws {
        let repository = try repositoryWithVersions(4)
        let installed = try revision("HEAD~3", in: repository)
        let remote = URL(fileURLWithPath: repository).absoluteString
        let executor = GitService(fileService: fileService, askpassHelperPath: TestPaths.gitAskpassHelperPath)
        var networkCall = 0
        let git = GitService(
            fileService: fileService,
            askpassHelperPath: TestPaths.gitAskpassHelperPath,
            upstreamHistoryNetworkRunner: { args, credential in
                networkCall += 1
                if networkCall == 2 {
                    return GitService.GitOutput(
                        stdout: "",
                        stderr: "fatal: server declined the object in unfamiliar words",
                        exit: 128
                    )
                }
                return try executor.run(args, in: nil, credential: credential)
            }
        )

        let result = try git.upstreamHistory(UpstreamHistoryGitRequest(
            remote: remote,
            ref: "main",
            installedCommit: installed,
            path: "skills/demo",
            repositoryPath: tempDir + "/failed-by-sha",
            commitLimit: 2,
            rowLimit: 3,
            textByteLimit: 1_024,
            baselineFileLimit: 10,
            baselineByteLimit: 10_000,
            credential: nil
        ))

        guard case .olderThanScan = result.installedPosition else {
            return XCTFail("a declined by-sha fetch means the installed commit is not available yet")
        }
        XCTAssertNil(result.installedBaseline)
    }

    private func repositoryWithVersions(_ count: Int) throws -> String {
        let repository = try makeRepository()
        for version in 1 ... count {
            try write("skills/demo/SKILL.md", text: "version \(version)\n", in: repository)
            _ = try commit(
                repository,
                message: "version \(version)",
                timestamp: 1_700_012_000 + version
            )
        }
        return repository
    }
}
