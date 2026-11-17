import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testViewChangesLoadsThePinnedUpdateAfterTheBranchMovesOn() throws {
        let fixture = try prepareRealPinnedUpdate()
        let local = fixture.storeRoot + "/skills/vendor/SKILL.md"
        let before = try fileService.readData(at: local)
        try writeSkill(name: "Moved Again", description: "unreviewed", body: "third body",
                       repository: fixture.repository)
        _ = try commit(fixture.repository, message: "move before diff")
        let row = try UpdatesViewModel.makeRow(skill: fixture.skill, driftedLocally: false)
        var preview: PinnedSkillDiff?
        XCTAssertNoThrow(preview = try NativeTestWork.run {
            try UpdatesViewModel.defaultDiffOperation(skillInstallService: fixture.service,
                                                     row: row, container: self.container)
        })
        let markdown = preview?.files.first { $0.path == "SKILL.md" }
        XCTAssertNotNil(markdown?.diff)
        if case let .text(_, new) = markdown?.content {
            XCTAssertTrue(new.contains("fresh body"))
            XCTAssertFalse(new.contains("third body"))
        } else {
            XCTFail("The pinned SKILL.md changes must load")
        }
        XCTAssertEqual(try fileService.readData(at: local), before)
        XCTAssertTrue(fixture.skill.updateAvailable)
        XCTAssertEqual(fixture.skill.upstreamCommit, fixture.pinnedCommit)
    }

    func testViewChangesNamesAPinnedCommitThatIsGoneAndOffersRecheck() throws {
        let fixture = try prepareRealPinnedUpdate()
        let missing = String(repeating: "a", count: 40)
        fixture.skill.upstreamCommit = missing
        XCTAssertThrowsError(try nativePreview(fixture.service, skill: fixture.skill)) { error in
            XCTAssertEqual(error.localizedDescription,
                "Commit aaaaaaa is no longer in the repository — re-check to review the latest version")
            XCTAssertTrue(UpdatesViewModel.offersRecheck(error))
            self.assertPrivateDownloadError(error)
        }
    }

    func testViewChangesKeepsEachDownloadFailuresOwnMessage() throws {
        let fixture = try prepareRealPinnedUpdate()
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "install-fixture", username: "installer", forHost: CredentialHost.githubInstall)
        try credentials.store(token: "sync-decoy", username: "sync", forHost: "github.com")
        let failures: [(Error, String)] = [
            (GitError.authenticationFailed(remote: "remote: untrusted", detail: "refused"),
             SkillInstallError.authenticationFailed.localizedDescription),
            (GitError.commandFailed(args: [], exitCode: 128, stderr: "Could not resolve host: remote: untrusted"),
             SkillInstallError.networkUnavailable.localizedDescription),
            (GitError.commandFailed(args: [], exitCode: 128, stderr: "remote: Repository not found."),
             SkillInstallError.repositoryNotFound.localizedDescription),
            (GitError.unusable(.developerToolsMissing),
             "Git isn't working on this Mac. Install the Command Line Tools "
                + "by running xcode-select --install in Terminal."),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                NSFilePathErrorKey: tempDir + "/askpass", NSLocalizedDescriptionKey: "remote: untrusted local path"
             ]), "Couldn't fetch the upstream repository."),
            (GitError.commandFailed(args: [], exitCode: 128, stderr: "remote: untrusted fetch rejection"),
             "Couldn't fetch the upstream repository.")
        ]
        for (failure, message) in failures {
            let git = PinnedPreviewGit(failure: failure)
            let service = pinnedPreviewService(fixture, git: git, credentials: credentials)
            let outcome = Result { try nativePreview(service, skill: fixture.skill) }
            XCTAssertEqual(git.downloadedCommits, [fixture.pinnedCommit])
            switch outcome {
            case let .failure(error):
                XCTAssertEqual(error.localizedDescription, message)
                XCTAssertFalse(UpdatesViewModel.offersRecheck(error))
                assertPrivateDownloadError(error)
            case .success:
                XCTFail("A failed pinned download must not load changes")
            }
            XCTAssertEqual(git.downloadCredentials, [
                .httpsToken(username: "installer", token: "install-fixture", host: "github.com")
            ])
        }
        try assertRealDownloadFailures(fixture, credentials: credentials)
    }

    private func assertRealDownloadFailures(_ fixture: RealFixture, credentials: CredentialStoreProtocol) throws {
        let transport = try GitFailureFixture()
        defer { try? transport.remove() }
        // Remote prose and an object rejection for a different ID must never mean this pin is gone.
        for detail in ["remote: not our ref " + fixture.pinnedCommit,
                       "fatal: remote error: upload-pack: not our ref " + String(repeating: "b", count: 40)] {
            let git = try transport.executable("""
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = fetch ]; then printf '%s\\n' '\(detail)' >&2; exit 128; fi
                exit 0
                """)
            let service = pinnedPreviewService(fixture, git: git)
            XCTAssertThrowsError(try nativePreview(service, skill: fixture.skill)) { error in
                XCTAssertEqual(error.localizedDescription, "Couldn't fetch the upstream repository.")
                XCTAssertFalse(UpdatesViewModel.offersRecheck(error))
                self.assertPrivateDownloadError(error)
            }
        }
        let helper = tempDir + "/unwritable-askpass"
        try fileService.createDirectory(at: helper)
        let git = GitService(fileService: fileService, askpassHelperPath: helper)
        let service = pinnedPreviewService(fixture, git: git, credentials: credentials)
        XCTAssertThrowsError(try nativePreview(service, skill: fixture.skill)) { error in
            XCTAssertEqual(error.localizedDescription, "Couldn't fetch the upstream repository.")
            self.assertPrivateDownloadError(error)
        }
    }

    func testViewChangesRefusesAMalformedPinBeforeGitRuns() throws {
        let fixture = try prepareRealPinnedUpdate()
        for pin in ["main", "--upload-pack=x", "+refs/heads/a:refs/heads/b", "abcdef0",
                    String(repeating: "A", count: 40), String(repeating: "a", count: 40) + "\n"] {
            fixture.skill.upstreamCommit = pin
            let git = PinnedPreviewGit()
            let service = pinnedPreviewService(fixture, git: git)
            XCTAssertThrowsError(try nativePreview(service, skill: fixture.skill)) { error in
                XCTAssertEqual(error as? SkillUpdateFlowError, .missingPinnedUpdate)
                XCTAssertEqual(error.localizedDescription,
                    "This update is no longer pinned — re-check to review the latest version")
                XCTAssertFalse(error.localizedDescription.contains(pin))
                XCTAssertTrue(UpdatesViewModel.offersRecheck(error))
            }
            XCTAssertEqual(git.calls, 0, "An invalid saved pin must never reach git")
        }
    }

    func testViewChangesRefusesAMismatchedDownloadWithoutReadingFiles() throws {
        let fixture = try prepareRealPinnedUpdate()
        for wrongHead in [true, false] {
            let spy = ImportBoundedReadSpy()
            let git = PinnedPreviewGit(wrongHead: wrongHead, wrongTree: !wrongHead)
            let service = pinnedPreviewService(fixture, git: git, files: spy)
            let outcome = Result { try nativePreview(service, skill: fixture.skill) }
            XCTAssertEqual(git.downloadedCommits, [fixture.pinnedCommit])
            switch outcome {
            case let .failure(error):
                XCTAssertEqual(error as? SkillUpdateFlowError, .repositoryChanged)
                XCTAssertEqual(error.localizedDescription, SkillUpdateFlowError.repositoryChangedMessage)
            case .success:
                XCTFail("A mismatched checkout must not load changes")
            }
            XCTAssertTrue(spy.comparisonThreads.isEmpty, "No file comparison before commit and tree verification")
            XCTAssertTrue(spy.readAttempts.isEmpty, "No SKILL.md prefix read before commit and tree verification")
            XCTAssertTrue(spy.textReads.isEmpty)
        }
    }

    func pinnedPreviewService(_ fixture: RealFixture, git: SkillInstallGitServing,
                              files: FileServiceProtocol = FileService(),
                              credentials: CredentialStoreProtocol = InMemoryCredentialStore()) -> SkillInstallService {
        SkillInstallService(gitService: git, credentialStore: credentials, fileService: files,
            scratchRoot: tempDir + "/preview-scratch", storeRoot: fixture.storeRoot,
            lockPath: tempDir + "/sync.lock",
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) })
    }

    private func assertPrivateDownloadError(_ error: Error) {
        XCTAssertFalse(error.localizedDescription.contains(tempDir))
        XCTAssertFalse(error.localizedDescription.contains("remote:"))
        XCTAssertFalse(error.localizedDescription.contains("untrusted"))
    }
}

/// Records transport requests and otherwise uses real git; can misreport checkout verification.
final class PinnedPreviewGit: SkillInstallGitServing {
    let git = TestPaths.git
    let failure: Error?
    var questionFailure: Error?
    var questionObservation: (() -> Void)?
    var questionCredentials: [GitCredential?] = []
    var wrongHead: Bool
    var wrongTree: Bool
    var downloadedCommits: [String] = []
    var downloadCredentials: [GitCredential?] = []
    var calls = 0

    init(failure: Error? = nil, wrongHead: Bool = false, wrongTree: Bool = false) {
        self.failure = failure
        self.wrongHead = wrongHead
        self.wrongTree = wrongTree
    }

    func remoteHead(remote: String, ref: String, credential: GitCredential?) throws -> String? {
        calls += 1
        questionCredentials.append(credential)
        questionObservation?()
        return try git.remoteHead(remote: remote, ref: ref, credential: credential)
    }

    func pinnedCommitIsReachable(_ commit: String, from tip: String, remote: String,
                                 into path: String, credential: GitCredential?) throws -> Bool? {
        calls += 1
        questionCredentials.append(credential)
        questionObservation?()
        if let questionFailure { throw questionFailure }
        return try git.pinnedCommitIsReachable(commit, from: tip, remote: remote, into: path, credential: credential)
    }

    func downloadPinnedCommit(remote: String, commit: String, into path: String,
                              credential: GitCredential?) throws {
        calls += 1
        downloadedCommits.append(commit)
        downloadCredentials.append(credential)
        if let failure { throw failure }
        try git.downloadPinnedCommit(remote: remote, commit: commit, into: path, credential: credential)
    }

    func cloneShallow(remote: String, branch: String?, into path: String, credential: GitCredential?) throws {
        calls += 1
        try git.cloneShallow(remote: remote, branch: branch, into: path, credential: credential)
    }
    func commitSHA(at path: String) throws -> String {
        calls += 1
        return wrongHead ? String(repeating: "f", count: 40) : try git.commitSHA(at: path)
    }
    func currentBranch(at path: String) throws -> String {
        calls += 1
        return try git.currentBranch(at: path)
    }
    func treeHash(at repositoryPath: String, path: String) throws -> String {
        calls += 1
        return wrongTree ? "wrong-tree" : try git.treeHash(at: repositoryPath, path: path)
    }
}
