import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testProbeRejectsEveryUnsafeStoredCoordinateBeforeGitRuns() throws {
        try NativeTestWork.run { [self] in
            let git = RecordingUpstreamHistoryGit(result: .success(probeSnapshot()))
            git.remoteHeadResult = .success(String(repeating: "b", count: 40))
            let reader = service(git: git, contentHasher: FixedContentHasher(value: "same"))
            let valid = origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: "same"
            )
            let invalid: [(InstalledOrigin, UpstreamHistoryError)] = [
                ({ var value = valid; value.ref = "-main"; return value }(), .invalidRef),
                ({ var value = valid; value.path = "skills/../demo"; return value }(), .invalidPath),
                ({ var value = valid; value.installedCommit = "short"; return value }(), .invalidInstalledCommit)
            ]

            for (stored, expected) in invalid {
                XCTAssertThrowsError(try reader.probeHead(origin: stored)) {
                    XCTAssertEqual($0 as? UpstreamHistoryError, expected)
                }
            }
            let strictReader = UpstreamHistoryService(
                gitService: git,
                credentialStore: InMemoryCredentialStore(),
                fileService: fileService,
                contentHasher: FixedContentHasher(value: "same"),
                scratchRoot: scratchRoot
            )
            var rejectedRepository = valid
            rejectedRepository.repo = "https://attacker.example/owner/repository"
            XCTAssertThrowsError(try strictReader.probeHead(origin: rejectedRepository)) {
                XCTAssertEqual($0 as? UpstreamHistoryError, .unsupportedRepositoryRemote)
            }
            XCTAssertTrue(git.headRequests.isEmpty)
            XCTAssertTrue(git.requests.isEmpty)
        }
    }

    func testProbeReconstructsRemoteAndUsesInstallCredential() throws {
        try NativeTestWork.run { [self] in
            let expectedHead = String(repeating: "b", count: 40)
            let git = RecordingUpstreamHistoryGit(result: .success(probeSnapshot()))
            git.remoteHeadResult = .success(expectedHead)
            let credentials = InMemoryCredentialStore()
            try credentials.store(token: "sync", username: "sync", forHost: "github.com")
            try credentials.store(
                token: "install",
                username: "installer",
                forHost: CredentialHost.githubInstall
            )
            let reader = UpstreamHistoryService(
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

            XCTAssertEqual(try reader.probeHead(origin: stored), expectedHead)

            let request = try XCTUnwrap(git.headRequests.first)
            XCTAssertEqual(request.remote, "https://github.com/example/repository.git")
            XCTAssertEqual(request.ref, "main")
            XCTAssertEqual(request.credential, .httpsToken(username: "installer", token: "install", host: "github.com"))
            XCTAssertTrue(git.requests.isEmpty)
        }
    }

    func testProbeGitInvocationCarriesRemoteAndCredential() throws {
        try NativeTestWork.run { [self] in
            let expectedHead = String(repeating: "c", count: 40)
            let remote = "https://github.com/example/repository.git"
            let credential = GitCredential.httpsToken(username: "installer", token: "secret", host: "github.com")
            var capturedArgs: [String] = []
            var capturedCredential: GitCredential?
            let git = GitService(fileService: fileService,
                                 askpassHelperPath: TestPaths.gitAskpassHelperPath) { args, suppliedCredential in
                capturedArgs = args
                capturedCredential = suppliedCredential
                return GitService.GitOutput(
                    stdout: "\(expectedHead)\trefs/heads/main\n",
                    stderr: "",
                    exit: 0
                )
            }

            XCTAssertEqual(
                try git.remoteHead(remote: remote, ref: "main", credential: credential),
                expectedHead
            )
            XCTAssertEqual(capturedArgs[0...1], ["ls-remote", "--"])
            XCTAssertEqual(capturedArgs[2], remote)
            XCTAssertEqual(capturedCredential, credential)
        }
    }

    private func probeSnapshot() -> UpstreamHistoryGitSnapshot {
        UpstreamHistoryGitSnapshot(
            headCommit: String(repeating: "a", count: 40),
            rows: [],
            installedPosition: .notInRefHistory,
            hasMoreCommits: false,
            installedBaseline: nil
        )
    }
}
