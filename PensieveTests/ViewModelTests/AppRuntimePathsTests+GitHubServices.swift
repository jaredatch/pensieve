import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension AppRuntimePathsTests {
    func assertLaunchCleanup(paths: AppRuntimePaths, scratchRoots: [String]) throws {
        let sandbox = (paths.storeRoot as NSString).deletingLastPathComponent
        let files = LinkServiceCanonicalDirectoryFileService(
            wrapped: FileService(), pathMappings: [], physicalSandbox: sandbox
        )
        let otherPaths = AppRuntimePaths(storeRoot: sandbox + "/other-store", appSupportDir: sandbox + "/other-support")
        let vendorTemp = paths.storeRoot + ".vendor-" + UUID().uuidString + ".tmp"
        let sentinels = [
            otherPaths.skillInstallScratchRoot + "/leftover",
            otherPaths.updateCheckScratchRoot + "/leftover",
            otherPaths.upstreamHistoryScratchRoot + "/leftover",
            otherPaths.storeRoot + ".vendor-" + UUID().uuidString + ".tmp/leftover",
            paths.skillsDir + "/keep/SKILL.md", paths.gitAskpassHelperPath,
            paths.upstreamHistoryCacheDir + "/cached"
        ]
        for path in sentinels { try files.writeFile(at: path, content: "keep") }
        for scratch in scratchRoots { try files.writeFile(at: scratch + "/leftover", content: "abandoned") }
        try files.writeFile(at: vendorTemp + "/leftover", content: "abandoned")
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: paths.syncLockPath))
        defer { lock.release() }
        paths.cleanupGitHubSkillTemps(fileService: files)
        for scratch in scratchRoots { XCTAssertFalse(files.directoryExists(at: scratch), scratch) }
        XCTAssertTrue(files.directoryExists(at: vendorTemp), "The runtime's held lock must protect vendor temps")
        lock.release()
        paths.cleanupGitHubSkillTemps(fileService: files)
        XCTAssertFalse(files.directoryExists(at: vendorTemp))
        for path in sentinels { XCTAssertEqual(try files.readFile(at: path), "keep", path) }
    }

    private struct LocalRemote {
        let git: GitService
        let files: FileServiceProtocol
        let repository: String
        let url: String
        let original: String
        let first: String
        let ref: String
    }

    /// The containment double fences FileService calls. Subprocess destinations and the raw-POSIX
    /// lock are checked before use, and credentials must be in-memory before a service runs.
    func testAuthenticatedGitHubServicesUseOnlyTemporaryRuntimePaths() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let paths = fixture.paths
        let files = LinkServiceCanonicalDirectoryFileService(
            wrapped: fixture.files, pathMappings: [], physicalSandbox: fixture.base
        )
        let operations = paths.makeUpdatesViewModelOperations(fileService: files)
        let installer = operations.skillInstallService
        let checker = operations.updateCheckService
        let history = paths.makeUpstreamHistoryService(fileService: files)
        XCTAssertEqual(installer.storeRoot, paths.storeRoot)
        XCTAssertEqual(installer.lockPath, paths.syncLockPath)
        XCTAssertEqual(checker.storeRoot, paths.storeRoot)
        let scratches = [installer.scratchRoot, checker.scratchRoot, history.scratchRoot]
        let expectedScratches = ["skill-install-scratch", "update-check-scratch", "upstream-history-scratch"].map {
            paths.appSupportDir + "/" + $0
        }
        XCTAssertEqual(scratches, expectedScratches)
        guard installer.storeRoot == paths.storeRoot, checker.storeRoot == paths.storeRoot,
              installer.lockPath == paths.syncLockPath, scratches == expectedScratches else { return }
        try requireContainedGit([installer.gitService, checker.gitService, history.gitService], files: files)
        let credentials = try XCTUnwrap(installer.credentialStore as? InMemoryCredentialStore)
        XCTAssertTrue(checker.credentialStore as AnyObject === credentials)
        let historyCredentials = try XCTUnwrap(history.credentialStore as? InMemoryCredentialStore)
        // Tokens force the concrete GitService's helper write even for local file transport.
        try credentials.store(token: "fixture-install-token", username: "fixture", forHost: CredentialHost.githubInstall)
        try historyCredentials.store(token: "fixture-history-token", username: "fixture", forHost: CredentialHost.githubInstall)
        try withLocalGitHubRemote(fixture: fixture, files: files) { remote in
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            let fetch = try installer.fetch(repo: remote.url, ref: remote.ref, credential: nil)
            let candidate = try XCTUnwrap(fetch.candidates.first)
            let installed = try installer.install(candidate: candidate, from: fetch, context: context)
            XCTAssertEqual(installed, .installed(slug: "example"))
            let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "example" })
            XCTAssertEqual(try files.readFile(at: paths.skillsDir + "/example/SKILL.md"), remote.original)
            XCTAssertEqual(skill.installedOrigin?.installedCommit, remote.first)
            try assertTemporaryAskpass(paths: paths, files: files)
            try files.deleteFile(at: paths.gitAskpassHelperPath)
            try checkUpdatedRemote(operations: operations, history: history, paths: paths,
                                   remote: remote, context: context, skill: skill)
            for scratch in [installer.scratchRoot, checker.scratchRoot, history.scratchRoot] {
                XCTAssertTrue(scratch.hasPrefix(paths.appSupportDir + "/"))
                XCTAssertEqual(try files.listDirectory(at: scratch), [])
            }
            XCTAssertEqual(try files.readFile(at: paths.skillsDir + "/example/SKILL.md"), remote.original)
            XCTAssertEqual(try files.listDirectory(at: fixture.base).filter { $0.contains(".vendor-") }, [])
        }
    }

    private func checkUpdatedRemote(
        operations: UpdatesViewModel.DefaultOperations, history: UpstreamHistoryService, paths: AppRuntimePaths,
        remote: LocalRemote, context: ModelContext, skill: Skill
    ) throws {
        try remote.files.writeFile(at: remote.repository + "/skills/example/SKILL.md",
                                   content: remote.original + "second version\n")
        try remote.git.stageAllAndCommit(at: remote.repository, message: "upstream change")
        let second = try remote.git.commitSHA(at: remote.repository)
        let report = try operations.updateCheckService.checkAll(context: context)
        XCTAssertTrue(report.reachedRemote)
        XCTAssertNil(report.environmentError)
        let persisted = try XCTUnwrap(try ModelContext(context.container).fetch(FetchDescriptor<Skill>()).first {
            $0.id == skill.id
        })
        XCTAssertNil(persisted.checkError)
        XCTAssertTrue(persisted.updateAvailable)
        XCTAssertEqual(persisted.upstreamCommit, second)
        try assertTemporaryAskpass(paths: paths, files: remote.files)
        try remote.files.deleteFile(at: paths.gitAskpassHelperPath)
        let result = try history.read(
            origin: XCTUnwrap(skill.installedOrigin), localDirectory: paths.skillsDir + "/example"
        )
        XCTAssertEqual(result.headCommit, second)
        XCTAssertEqual(result.rows.map(\.sha), [second, remote.first])
        XCTAssertEqual(result.installedPosition, .at(sha: remote.first))
        XCTAssertEqual(result.localEdits, .none)
        try assertTemporaryAskpass(paths: paths, files: remote.files)
    }

    private func withLocalGitHubRemote(
        fixture: GitFailureFixture, files: FileServiceProtocol, operation: (LocalRemote) throws -> Void
    ) throws {
        let repository = fixture.base + "/upstream"
        let git = GitService(fileService: files, askpassHelperPath: fixture.support + "/setup-askpass")
        try files.createDirectory(at: repository)
        try git.initRepository(at: repository)
        let original = "---\nname: Example\ndescription: Local fixture\n---\nfirst version\n"
        try files.writeFile(at: repository + "/skills/example/SKILL.md", content: original)
        try git.stageAllAndCommit(at: repository, message: "initial skill")
        let ref = try git.currentBranch(at: repository)
        let first = try git.commitSHA(at: repository)
        let url = "https://github.com/fixture/\(UUID().uuidString).git"
        let configuration = fixture.base + "/configuration"
        try files.writeFile(at: configuration + "/git/config", content: """
            [url "\(URL(fileURLWithPath: repository).absoluteString)"]
                insteadOf = \(url)
            """ + "\n")
        let oldConfiguration = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", configuration, 1)
        defer {
            if let oldConfiguration { setenv("XDG_CONFIG_HOME", oldConfiguration, 1) } else { unsetenv("XDG_CONFIG_HOME") }
        }
        try operation(LocalRemote(git: git, files: files, repository: repository, url: url,
                                  original: original, first: first, ref: ref))
    }

    private func assertTemporaryAskpass(paths: AppRuntimePaths, files: FileServiceProtocol) throws {
        XCTAssertTrue(files.isExecutableFile(at: paths.gitAskpassHelperPath))
        let body = try files.readFile(at: paths.gitAskpassHelperPath)
        XCTAssertTrue(body.contains("$PENSIEVE_GIT_PASSWORD"))
        XCTAssertFalse(body.contains("fixture-install-token"))
        XCTAssertFalse(body.contains("fixture-history-token"))
    }

    private func requireContainedGit(_ services: [Any], files: LinkServiceCanonicalDirectoryFileService) throws {
        for service in services {
            let git = try XCTUnwrap(service as? GitService)
            let contained = try XCTUnwrap(git.fileService as? LinkServiceCanonicalDirectoryFileService)
            XCTAssertTrue(contained === files)
            // A replacement concrete FileService must fail before its first authenticated write.
            guard contained === files else { throw CocoaError(.fileWriteNoPermission) }
        }
    }
}
