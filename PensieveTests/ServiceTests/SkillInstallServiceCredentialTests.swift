import XCTest
@testable import Pensieve

private final class RejectingInstallGitService: SkillInstallGitServing {
    let cloneError: Error
    private(set) var receivedCredentials: [GitCredential?] = []

    init(cloneError: Error) {
        self.cloneError = cloneError
    }

    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?) throws {
        receivedCredentials.append(credential)
        throw cloneError
    }

    func commitSHA(at path: String) throws -> String { "unused" }
    func currentBranch(at path: String) throws -> String { "unused" }
    func treeHash(at repositoryPath: String, path: String) throws -> String { "unused" }
}

extension SkillInstallServiceTests {
    func testDefaultInstallRemotePolicyRejectsStoredUnsafeRemotesBeforeGit() throws {
        let rejectingGit = RejectingInstallGitService(
            cloneError: GitError.commandFailed(args: ["clone"], exitCode: 128, stderr: "must not run")
        )
        let installer = SkillInstallService(
            gitService: rejectingGit,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: tempDir + "/remote-policy-scratch"
        )

        for remote in [
            "ext::sh -c touch /tmp/pensieve-should-not-exist",
            "https://attacker.example/owner/repo"
        ] {
            XCTAssertThrowsError(try installer.fetch(repo: remote, ref: "main", credential: nil)) {
                XCTAssertEqual($0 as? SkillInstallError, .unsupportedRepositoryRemote)
            }
        }
        XCTAssertTrue(rejectingGit.receivedCredentials.isEmpty)
    }

    func testInstallCredentialSelectionPrefersInstallSlotAndNeverSyncSlot() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.store(
            token: "sync-decoy",
            username: "sync-user",
            forHost: "github.com"
        )
        try credentials.store(
            token: "install-secret",
            username: "x-access-token",
            forHost: CredentialHost.githubInstall
        )
        let rejection = GitError.commandFailed(args: ["clone"], exitCode: 128, stderr: "injected")
        let rejectingGit = RejectingInstallGitService(cloneError: rejection)
        let installer = SkillInstallService(
            gitService: rejectingGit,
            credentialStore: credentials,
            fileService: fileService,
            scratchRoot: tempDir + "/credential-scratch"
        )

        XCTAssertThrowsError(
            try installer.fetch(repo: "https://github.com/example/private.git", ref: nil, credential: nil)
        )
        XCTAssertEqual(
            rejectingGit.receivedCredentials.last!,
            .httpsToken(username: "x-access-token", token: "install-secret")
        )

        try credentials.delete(forHost: CredentialHost.githubInstall)
        XCTAssertThrowsError(
            try installer.fetch(
                repo: "https://github.com/example/public.git",
                ref: nil,
                credential: .httpsToken(username: "sync-user", token: "sync-decoy")
            )
        )
        XCTAssertNil(
            rejectingGit.receivedCredentials.last!,
            "an absent install token must stay anonymous instead of using the sync-host decoy"
        )
    }

    func testAuthFailureMappedDistinctFromNotFound() throws {
        assertShallowCloneDisablesConfiguredCredentialHelpers()

        let authGit = RejectingInstallGitService(cloneError: GitError.commandFailed(
            args: ["clone"],
            exitCode: 128,
            stderr: "fatal: unable to access repository: The requested URL returned error: 403"
        ))
        let authService = SkillInstallService(
            gitService: authGit,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: tempDir + "/auth-scratch"
        )

        XCTAssertThrowsError(
            try authService.fetch(repo: "https://github.com/example/private.git", ref: nil, credential: nil)
        ) { error in
            XCTAssertEqual(error as? SkillInstallError, .authenticationFailed)
            XCTAssertEqual(
                error.localizedDescription,
                "Authentication failed — for private repositories add a GitHub token in Settings"
            )
        }

        XCTAssertThrowsError(
            try service.fetch(repo: tempDir + "/missing-repository", ref: nil, credential: nil)
        ) { error in
            XCTAssertEqual(error as? SkillInstallError, .repositoryNotFound)
            XCTAssertNotEqual(error as? SkillInstallError, .authenticationFailed)
            XCTAssertTrue(
                error.localizedDescription.contains("if it's private"),
                "not-found must stay authentication-ambiguous (GitHub hides private repositories as 404)"
            )
        }

        assertLocalPermissionFailureIsNotAuthentication()
    }

    private func assertShallowCloneDisablesConfiguredCredentialHelpers() {
        let productionGit = GitService()
        XCTAssertThrowsError(
            try productionGit.cloneShallow(
                remote: "file:///definitely-missing-pensieve-install-repository",
                branch: nil,
                into: tempDir + "/missing-helper-safe-clone",
                credential: nil
            )
        ) { error in
            guard case let GitError.commandFailed(args, _, _, _) = error else {
                return XCTFail("expected command failure, got \(error)")
            }
            XCTAssertEqual(Array(args.prefix(3)), ["-c", "credential.helper=", "clone"])
        }
    }

    private func assertLocalPermissionFailureIsNotAuthentication() {
        let localPermissionGit = RejectingInstallGitService(cloneError: GitError.commandFailed(
            args: ["clone"],
            exitCode: 128,
            stderr: "fatal: could not create work tree dir: Permission denied"
        ))
        let localPermissionService = SkillInstallService(
            gitService: localPermissionGit,
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: tempDir + "/local-permission-scratch"
        )

        XCTAssertThrowsError(
            try localPermissionService.fetch(
                repo: "https://github.com/example/public.git",
                ref: nil,
                credential: nil
            )
        ) { error in
            XCTAssertNil(error as? SkillInstallError)
            XCTAssertTrue(error is GitError)
        }
    }
}
