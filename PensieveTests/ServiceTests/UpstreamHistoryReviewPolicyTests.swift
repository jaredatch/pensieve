import XCTest
@testable import Pensieve

extension UpstreamHistoryServiceTests {
    func testCRLFLocalEditsCountByNewlineInsteadOfAsOneGrapheme() throws {
        let before = "one\r\ntwo\r\n"
        let after = "one\r\nchanged\r\n"
        try write("SKILL.md", text: after, in: localDirectory)
        let baseline = UpstreamHistoryBaselineFile(
            path: "SKILL.md",
            content: .text(before),
            fingerprint: UpstreamHistoryService.gitBlobFingerprint(Data(before.utf8)),
            isExecutable: false
        )
        let sha = String(repeating: "a", count: 40)
        let git = RecordingUpstreamHistoryGit(result: .success(UpstreamHistoryGitSnapshot(
            headCommit: sha,
            rows: [],
            installedPosition: .reachable(pathCommit: nil),
            hasMoreCommits: false,
            installedBaseline: .files([baseline])
        )))

        let result = try service(
            git: git,
            contentHasher: FixedContentHasher(value: "sha256:changed")
        ).read(
            origin: origin(
                repo: "fixture://remote",
                installedCommit: sha,
                contentHash: "sha256:installed"
            ),
            localDirectory: localDirectory
        )

        guard case let .changed(changes) = result.localEdits else {
            return XCTFail("expected measured CRLF edit")
        }
        XCTAssertEqual(changes.first?.linesAdded, 1)
        XCTAssertEqual(changes.first?.linesRemoved, 1)
    }

    func testInstallAndHistoryRejectTheSameMalformedRelativePaths() throws {
        let invalid = ["skills/./demo", "skills//demo", "skills/demo/", "-plain"]
            + PathJoiningScalars.values.map { "-" + PathJoiningScalars.name("x", scalar: $0) }
        let git = RecordingUpstreamHistoryGit(result: .success(UpstreamHistoryGitSnapshot(
            headCommit: String(repeating: "a", count: 40),
            rows: [],
            installedPosition: .notInRefHistory,
            hasMoreCommits: false,
            installedBaseline: nil
        )))
        let reader = service(git: git, contentHasher: FixedContentHasher(value: "same"))
        let installer = SkillInstallService(
            gitService: GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass"),
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: tempDir + "/install-scratch",
            storeRoot: tempDir + "/store",
            lockPath: tempDir + "/sync.lock",
            remoteValidator: fixtureValidator
        )

        for path in invalid {
            XCTAssertFalse(InstallRelativePathPolicy.isValid(path))
            XCTAssertThrowsError(try installer.discover(at: tempDir + "/repository", path: path)) {
                XCTAssertEqual($0 as? SkillInstallError, .invalidRepositoryPath(path))
            }
            var stored = origin(
                repo: "fixture://remote",
                installedCommit: String(repeating: "a", count: 40),
                contentHash: "same"
            )
            stored.path = path
            XCTAssertThrowsError(try reader.read(origin: stored, localDirectory: localDirectory)) {
                XCTAssertEqual($0 as? UpstreamHistoryError, .invalidPath)
            }
        }
        XCTAssertTrue(git.requests.isEmpty)
    }
}
