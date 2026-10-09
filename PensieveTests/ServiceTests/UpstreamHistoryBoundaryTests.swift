import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    /// Protects 39.1-i: an impossible window is rejected before multiplication or Git work can trap.
    func testOverflowingWindowIsRejectedBeforeGitRuns() throws {
        let git = RecordingUpstreamHistoryGit(result: .success(emptySnapshot()))
        let service = boundaryService(git: git)

        XCTAssertThrowsError(try service.read(
            origin: validBoundaryOrigin(),
            localDirectory: localDirectory,
            windowCount: Int.max
        )) {
            XCTAssertEqual($0 as? UpstreamHistoryError, .invalidWindow)
        }
        XCTAssertTrue(git.requests.isEmpty)
    }

    func testGitRefNameRulesRejectEveryBadShapeBeforeGitAndAcceptLiteralBranch() throws {
        let invalidRefs = [
            "", "-main", "/main", "main/", "main.lock", "main.", "topic//name",
            "topic/.hidden", "topic:other", "feature*", "feature?", "feature[0]",
            "feature\\name", "feature~1", "feature^2", "feature name", "line\nname",
            "topic..name", "topic@{upstream}", "@", "*:refs/pensieve/all/*"
        ] + PathJoiningScalars.values.map { "-" + PathJoiningScalars.name("main", scalar: $0) }

        for invalidRef in invalidRefs {
            let git = RecordingUpstreamHistoryGit(result: .success(emptySnapshot()))
            let service = boundaryService(git: git)
            var stored = validBoundaryOrigin()
            stored.ref = invalidRef

            XCTAssertThrowsError(try service.read(origin: stored, localDirectory: localDirectory)) {
                XCTAssertEqual($0 as? UpstreamHistoryError, .invalidRef, invalidRef)
            }
            XCTAssertTrue(git.requests.isEmpty, invalidRef)
        }

        let git = RecordingUpstreamHistoryGit(result: .success(emptySnapshot()))
        let service = boundaryService(git: git)
        var stored = validBoundaryOrigin()
        stored.ref = "release/2026-09"

        _ = try service.read(origin: stored, localDirectory: localDirectory)

        XCTAssertEqual(git.requests.count, 1)
        XCTAssertEqual(git.requests.first?.ref, "release/2026-09")
    }

    func testUnsafeStoredCoordinatesAreTypedErrorsBeforeGitRuns() throws {
        let snapshot = emptySnapshot()
        let git = RecordingUpstreamHistoryGit(result: .success(snapshot))
        var valid = origin(
            repo: "fixture://remote",
            installedCommit: String(repeating: "a", count: 40),
            contentHash: "same"
        )
        let invalidCases: [(InstalledOrigin, UpstreamHistoryError)] = [
            ({ var value = valid; value.installedCommit = "abc"; return value }(), .invalidInstalledCommit),
            ({ var value = valid; value.ref = "-main"; return value }(), .invalidRef),
            ({ var value = valid; value.ref = "ma\u{1b}in"; return value }(), .invalidRef),
            ({ var value = valid; value.path = "-skill"; return value }(), .invalidPath),
            ({ var value = valid; value.path = "skills/line\nname"; return value }(), .invalidPath),
            ({ var value = valid; value.path = "/skills/demo"; return value }(), .invalidPath),
            ({ var value = valid; value.path = "skills/../demo"; return value }(), .invalidPath),
            ({ var value = valid; value.path = "skills/./demo"; return value }(), .invalidPath),
            ({ var value = valid; value.path = "skills//demo"; return value }(), .invalidPath),
            ({ var value = valid; value.path = "skills/demo/"; return value }(), .invalidPath)
        ]
        let service = UpstreamHistoryService(
            gitService: git,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            contentHasher: FixedContentHasher(value: "same"),
            scratchRoot: scratchRoot,
            remoteValidator: fixtureValidator
        )

        for (stored, expected) in invalidCases {
            XCTAssertThrowsError(try service.read(origin: stored, localDirectory: localDirectory)) {
                XCTAssertEqual($0 as? UpstreamHistoryError, expected)
            }
        }
        XCTAssertTrue(git.requests.isEmpty)

        valid.repo = "https://attacker.example/owner/repo"
        let policyService = UpstreamHistoryService(
            gitService: git,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            contentHasher: FixedContentHasher(value: "same"),
            scratchRoot: scratchRoot
        )
        XCTAssertThrowsError(try policyService.read(origin: valid, localDirectory: localDirectory)) {
            XCTAssertEqual($0 as? UpstreamHistoryError, .unsupportedRepositoryRemote)
        }
        XCTAssertTrue(git.requests.isEmpty)
    }

    private func boundaryService(git: RecordingUpstreamHistoryGit) -> UpstreamHistoryService {
        UpstreamHistoryService(
            gitService: git,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            contentHasher: FixedContentHasher(value: "same"),
            scratchRoot: scratchRoot,
            remoteValidator: fixtureValidator
        )
    }

    private func validBoundaryOrigin() -> InstalledOrigin {
        origin(
            repo: "fixture://remote",
            installedCommit: String(repeating: "a", count: 40),
            contentHash: "same"
        )
    }

    func testNetworkFetchArgumentsIsolateCredentialsAndTerminateRemoteOptions() throws {
        let repositoryPath = "/tmp/history"
        let remote = "https://github.com/example/repository.git"
        let args = GitService.upstreamHistoryFetchArguments(
            repositoryPath: repositoryPath,
            remote: remote,
            remoteRef: "refs/heads/main",
            depth: 201
        )
        let commitArgs = GitService.upstreamHistoryCommitFetchArguments(
            repositoryPath: repositoryPath,
            remote: remote,
            commit: String(repeating: "a", count: 40)
        )
        for invocation in [args, commitArgs] {
            XCTAssertEqual(Array(invocation.prefix(2)), GitService.installCredentialIsolationArgs)
            let terminator = try XCTUnwrap(invocation.lastIndex(of: "--"))
            XCTAssertEqual(invocation[invocation.index(after: terminator)], remote)
        }

        let git = RecordingUpstreamHistoryGit(result: .success(emptySnapshot()))
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "sync", username: "sync", forHost: "github.com")
        try credentials.store(
            token: "install",
            username: "installer",
            forHost: CredentialHost.githubInstall
        )
        let service = UpstreamHistoryService(
            gitService: git,
            credentialStore: credentials,
            fileService: fileService,
            contentHasher: FixedContentHasher(value: "same"),
            scratchRoot: scratchRoot
        )
        let stored = origin(
            repo: "https://github.com/example/repository",
            installedCommit: String(repeating: "a", count: 40),
            contentHash: "same"
        )

        _ = try service.read(origin: stored, localDirectory: localDirectory)

        let request = try XCTUnwrap(git.requests.first)
        XCTAssertEqual(request.remote, remote)
        XCTAssertEqual(request.credential, .httpsToken(username: "installer", token: "install"))
    }

    func testUntrustedMetadataIsSanitizedAndCappedWithoutSplittingRows() throws {
        let sha = String(repeating: "b", count: 40)
        let hostile = UpstreamHistoryGitRow(
            sha: sha,
            author: String(repeating: "A", count: 200) + "\u{1f}\u{1b}[31m",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "subject\u{2028}next\u{1b}[2J"
                + String(repeating: "\u{301}", count: 400)
                + String(repeating: "S", count: 400),
            filesChanged: 1,
            linesAdded: 2,
            linesRemoved: 1,
            skillMarkdown: .text("body")
        )
        let snapshot = UpstreamHistoryGitSnapshot(
            headCommit: sha,
            rows: [hostile],
            installedPosition: .reachable(pathCommit: sha),
            hasMoreCommits: false,
            installedBaseline: .files([])
        )
        let git = RecordingUpstreamHistoryGit(result: .success(snapshot))
        let service = UpstreamHistoryService(
            gitService: git,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            contentHasher: FixedContentHasher(value: "same"),
            scratchRoot: scratchRoot,
            remoteValidator: fixtureValidator
        )

        let result = try service.read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: sha,
                contentHash: "same"
            ),
            localDirectory: localDirectory
        )

        let row = try XCTUnwrap(result.rows.first)
        XCTAssertEqual(row.sha, sha)
        XCTAssertLessThanOrEqual(row.author.count, UpstreamHistoryService.authorLimit)
        XCTAssertLessThanOrEqual(row.subject.count, UpstreamHistoryService.subjectLimit)
        XCTAssertLessThanOrEqual(
            row.subject.unicodeScalars.count,
            UpstreamHistoryService.subjectLimit
        )
        XCTAssertFalse(row.author.unicodeScalars.contains { $0.properties.generalCategory == .control })
        XCTAssertFalse(row.subject.contains("\u{1b}"))
        XCTAssertFalse(row.subject.contains("[2J"))
    }

    func testEveryReadOutcomeDeletesItsScratchSessionAndLaunchSweepRemovesCrashResidue() throws {
        let stored = origin(
            repo: "fixture://remote",
            installedCommit: String(repeating: "a", count: 40),
            contentHash: "same"
        )
        let outcomes: [(Result<UpstreamHistoryGitSnapshot, Error>, Bool)] = [
            (.success(emptySnapshot()), false),
            (.failure(GitError.commandFailed(args: ["fetch"], exitCode: 128, stderr: "failed")), false),
            (.failure(GitError.commandFailed(args: ["show"], exitCode: 128, stderr: "failed")), true)
        ]
        for (outcome, leavesArtifact) in outcomes {
            let git = RecordingUpstreamHistoryGit(result: outcome)
            git.createScratchArtifact = leavesArtifact
            let service = UpstreamHistoryService(
                gitService: git,
                credentialStore: InMemoryCredentialStore(),
                fileService: fileService,
                contentHasher: FixedContentHasher(value: "same"),
                scratchRoot: scratchRoot,
                remoteValidator: fixtureValidator
            )
            _ = try? service.read(origin: stored, localDirectory: localDirectory)
            try assertScratchEmpty()
        }

        try fileService.writeFile(at: scratchRoot + "/crashed/repository/FETCH_HEAD", content: "partial")
        UpstreamHistoryService.cleanupScratchRoot(fileService: fileService, scratchRoot: scratchRoot)
        XCTAssertFalse(fileService.directoryExists(at: scratchRoot))
    }

    func testRepositoryFailuresUseInstallMessagesIncludingMissingRef() throws {
        let sha = String(repeating: "a", count: 40)
        let stored = origin(repo: "fixture://remote", installedCommit: sha, contentHash: "same")
        let cases: [(Error, String)] = [
            (GitError.commandFailed(
                args: ["fetch"], exitCode: 128, stderr: "fatal: could not resolve host: github.com"
            ), SkillInstallError.networkUnavailable.localizedDescription),
            (GitError.commandFailed(
                args: ["fetch"], exitCode: 128, stderr: "fatal: repository not found"
            ), SkillInstallError.repositoryNotFound.localizedDescription),
            (GitError.commandFailed(
                args: ["fetch"], exitCode: 128, stderr: "fatal: Authentication failed"
            ), SkillInstallError.authenticationFailed.localizedDescription),
            (UpstreamHistoryError.trackedRefNotFound("main"),
             UpdateCheckError.trackedRefNotFound("main").localizedDescription)
        ]
        for (failure, expectedMessage) in cases {
            let git = RecordingUpstreamHistoryGit(result: .failure(failure))
            let service = UpstreamHistoryService(
                gitService: git,
                credentialStore: InMemoryCredentialStore(),
                fileService: fileService,
                contentHasher: FixedContentHasher(value: "same"),
                scratchRoot: scratchRoot,
                remoteValidator: fixtureValidator
            )
            XCTAssertThrowsError(try service.read(origin: stored, localDirectory: localDirectory)) {
                XCTAssertEqual($0.localizedDescription, expectedMessage)
            }
        }
    }

    private func emptySnapshot() -> UpstreamHistoryGitSnapshot {
        UpstreamHistoryGitSnapshot(
            headCommit: String(repeating: "c", count: 40),
            rows: [],
            installedPosition: .notInRefHistory,
            hasMoreCommits: false,
            installedBaseline: nil
        )
    }
}
