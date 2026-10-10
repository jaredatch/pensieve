import AppKit
import SwiftUI
import XCTest
import SwiftData
@testable import Pensieve

// Frozen PLAN-24 keeps all setup fixtures and methods in this existing test file.
// swiftlint:disable file_length

// `Category` is aliased per-file (fileprivate) across the test target to disambiguate the model type;
// the in-memory `ModelContainer` schema list needs it. Mirrors CategoryDetailModelTests.
private typealias PensieveCategory = Pensieve.Category

@MainActor
final class SyncSetupModelTests: XCTestCase {

    private final class EventTrace {
        var events: [String] = []
    }

    private struct StubBoom: Error {}

    // MARK: - Stubs

    /// Records call order + scriptable results. Every op appends a tag to `calls`; `throwAuthOn` names
    /// a call that should throw `authenticationFailed`.
    private final class RecordingGitService: GitServiceProtocol {
        var beforeCall: ((String) -> Void)?
        private(set) var calls: [String] = []
        let trace: EventTrace
        var remoteHasCommitsResult = false
        var pullResult: PullResult = .upToDate
        var throwAuthOn: String?
        var throwOn: String?
        var defaultBranchFixture: String? = "main"
        var branchesFixture = ["main"]
        var hasLocalBranchesFixture: Result<Bool, Error> = .success(true)
        var hasRemoteTrackingBranchFixture = false
        var hasRemoteOriginConfiguredFixture: Result<Bool, Error> = .success(true)
        var configuredRemoteURLFixture: Result<String?, Error> = .success(nil)
        var remoteURLFixture: String?
        private(set) var lastCredential: GitCredential?

        init(trace: EventTrace = EventTrace()) { self.trace = trace }

        private func record(_ event: String) throws {
            beforeCall?(event)
            calls.append(event)
            trace.events.append(event)
            if throwOn == event { throw StubBoom() }
        }

        private func maybeThrowAuth(_ tag: String, remote: String) throws {
            if throwAuthOn == tag { throw GitError.authenticationFailed(remote: remote, detail: "stub") }
        }

        func initRepository(at path: String) throws { try record("init:\(path)") }
        func setRemote(_ url: String, at path: String) throws { try record("remote:\(url)") }
        func removeRemote(at path: String) throws {
            try record("remove-remote:\(path)")
            remoteURLFixture = nil
            configuredRemoteURLFixture = .success(nil)
        }
        func configuredRemoteURL(at path: String) throws -> String? {
            try record("config-remote:\(path)")
            return try configuredRemoteURLFixture.get()
        }
        func probeUsability() -> GitUsability { beforeCall?("probe"); return .usable }
        func remoteURL(at path: String) -> String? { beforeCall?("read-remote"); return remoteURLFixture }

        func remoteDefaultBranch(remote: String, credential: GitCredential?) throws -> String? {
            let tag = "lsremote-symref:\(remote)"
            try record(tag)
            try maybeThrowAuth(tag, remote: remote)
            return defaultBranchFixture
        }

        func remoteBranches(remote: String, credential: GitCredential?) throws -> [String] {
            let tag = "lsremote-heads:\(remote)"
            try record(tag)
            try maybeThrowAuth(tag, remote: remote)
            return branchesFixture
        }

        func checkoutUnbornBranch(_ branch: String, at path: String) throws {
            try record("checkout-B:\(branch)")
        }
        func fetchBranch(_ branch: String, at path: String, credential: GitCredential?) throws {
            try record("fetch:\(branch)")
        }
        func materializeFromFetchHead(at path: String) throws { try record("restore-fetch-head") }
        func bornBranch(_ branch: String, at path: String) throws { try record("born:\(branch)") }
        func setUpstream(branch: String, at path: String) throws { try record("upstream:\(branch)") }
        func hasLocalBranches(at path: String) throws -> Bool {
            beforeCall?("read-branches"); return try hasLocalBranchesFixture.get()
        }
        func hasRemoteTrackingBranch(_ branch: String, at path: String) -> Bool {
            beforeCall?("read-tracking"); return hasRemoteTrackingBranchFixture
        }
        func hasRemoteOriginConfigured(at path: String) throws -> Bool {
            try hasRemoteOriginConfiguredFixture.get()
        }

        func clone(remote: String, into path: String, credential: GitCredential?) throws {
            beforeCall?("clone")
            lastCredential = credential
            let event = "clone:\(remote)→\(path)"
            calls.append(event)
            trace.events.append(event)
            try maybeThrowAuth("clone", remote: remote)
        }

        func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool {
            beforeCall?("remoteHasCommits")
            calls.append("remoteHasCommits")
            return remoteHasCommitsResult
        }

        @discardableResult
        func stageAllAndCommit(at path: String, message: String) throws -> Bool {
            beforeCall?("commit")
            calls.append("commit")
            return true
        }

        func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
        func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
            try pullRebase(at: path, credential: nil)
        }
        func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
            beforeCall?("pull")
            calls.append("pull")
            return pullResult
        }

        func push(at path: String, credential: GitCredential?) throws {
            beforeCall?("push")
            lastCredential = credential
            calls.append("push")
            try maybeThrowAuth("push", remote: "origin")
        }

        func abortRebase(at path: String) throws { beforeCall?("abort"); calls.append("abort") }
        func conflictedFiles(at path: String) -> [String] { [] }
        func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
        func continueRebase(at path: String) throws -> PullResult { .upToDate }
        func skipRebase(at path: String) throws -> PullResult { .upToDate }
        func stagePath(_ path: String, at root: String) throws {}
        func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                    fetchedRevision: FetchedStoreRevision?) throws -> Bool { false }
        func hasCommitsToPush(at path: String) -> Bool { false }
    }

    private final class ThrowingCredentialStore: CredentialStoreProtocol {
        func store(token: String, username: String, forHost host: String) throws {}
        func credential(forHost host: String) -> GitCredential? { nil }
        func delete(forHost host: String) throws { throw StubBoom() }
    }

    /// Records the rebuild call; returns an empty result.
    private final class RecordingRebuilder: StoreRebuildServiceProtocol {
        private(set) var rebuildCount = 0
        var result = RebuildResult()
        let trace: EventTrace
        init(trace: EventTrace = EventTrace()) { self.trace = trace }
        @discardableResult
        func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
            rebuildCount += 1
            trace.events.append("rebuild:\(root)")
            return result
        }
    }

    /// Controllable dir/list; every other member inert. Only what `SyncSetupModel` touches matters.
    private final class StubFileService: FileServiceProtocol {
        var dirs: Set<String> = []
        var listing: [String: [String]] = [:]
        var files: Set<String> = []
        var regularFiles: Set<String> = []
        var symlinks: Set<String> = []
        var contents: [String: String] = [:]
        var readErrors: Set<String> = []
        var listErrors: Set<String> = []
        let trace: EventTrace

        init(trace: EventTrace = EventTrace()) { self.trace = trace }

        func directoryExists(at path: String) -> Bool { dirs.contains(path) }
        func listDirectory(at path: String) throws -> [String] {
            if listErrors.contains(path) { throw StubBoom() }
            return listing[path] ?? []
        }
        func readFile(at path: String) throws -> String {
            if readErrors.contains(path) { throw StubBoom() }
            return contents[path] ?? ""
        }
        func writeFile(at path: String, content: String) throws {}
        func writeExecutableFile(at path: String, content: String) throws {}
        func deleteFile(at path: String) throws { trace.events.append("delete:\(path)") }
        func fileExists(at path: String) -> Bool { files.contains(path) }
        func isExecutableFile(at path: String) -> Bool { false }
        func createDirectory(at path: String) throws {}
        func deleteDirectory(at path: String) throws { trace.events.append("delete:\(path)") }
        func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
        func symlinkTarget(at path: String) throws -> String {
            guard symlinks.contains(path) else { throw StubBoom() }
            return "target"
        }
        func isSymlink(at path: String) -> Bool { symlinks.contains(path) }
        func isRegularFile(at path: String) -> Bool { regularFiles.contains(path) }
        func contentsHash(at path: String) throws -> String { "" }
    }

    // MARK: - Fixtures

    private let root = TestTemporaryDirectory.path + "pensieve-sync-setup-test-\(UUID().uuidString)"

    private final class HostedWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var hostedWindows: [HostedWindow] = []

    override func tearDown() async throws {
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "A setup test left a hosted window alive after its test body ended",
                             diagnostics: { "live windows: \(self.hostedWindows.filter { $0.window != nil }.count)" }, {
            self.hostedWindows.allSatisfy { $0.window == nil }
        })
        try await super.tearDown()
    }

    override func tearDownWithError() throws {
        for path in [root, root + "-fixtures"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            DeployRecord.self, PensieveCategory.self,
            MachineDeployIntent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeModel(git: GitServiceProtocol,
                           credentials: CredentialStoreProtocol,
                           rebuilder: StoreRebuildServiceProtocol,
                           fileService: FileServiceProtocol,
                           lockPath: String? = nil,
                           context: ModelContext? = nil,
                           syncedFamiliesEmpty: (() -> Bool?)? = nil, steps: SyncStepModel? = nil) throws -> SyncSetupModel {
        SyncSetupModel(context: try context ?? makeContext(), git: git, credentials: credentials,
                       rebuilder: rebuilder, fileService: fileService, root: root,
                       lockPath: lockPath ?? root + "-sync.lock",
                       syncedFamiliesEmpty: syncedFamiliesEmpty, steps: steps ?? SyncStepModel())
    }

    /// A StubFileService configured so `firstSyncPlan` picks `.initAndPush` (no .git, skills present).
    private func existingUserFiles() -> StubFileService {
        let file = StubFileService()
        file.dirs = [root + "/skills"]
        file.listing[root + "/skills"] = ["swift-style"]
        return file
    }

    private func virginScaffold(trace: EventTrace = EventTrace(), gitDir: Bool = false) -> StubFileService {
        let file = StubFileService(trace: trace)
        let manifest = root + "/manifest"
        let childNames = ["categories", "skills", "deploys"]
        file.dirs = Set([root, manifest] + childNames.map { manifest + "/" + $0 })
        if gitDir { file.dirs.insert(root + "/.git") }
        file.listing[root] = gitDir ? ["manifest", ".git"] : ["manifest"]
        file.listing[manifest] = ["manifest.yaml", "projects.yaml"] + childNames
        for name in childNames { file.listing[manifest + "/" + name] = [] }
        file.regularFiles = [manifest + "/manifest.yaml", manifest + "/projects.yaml"]
        file.contents[manifest + "/manifest.yaml"] = "schema_version: \(ManifestService.currentSchemaVersion)\n"
        file.contents[manifest + "/projects.yaml"] = ManifestService.serializeProjects([])
        return file
    }
}

// MARK: - Original SyncSetupModel coverage

extension SyncSetupModelTests {
    func testFirstSyncPlanBranches() {
        XCTAssertEqual(SyncSetupModel.firstSyncPlan(hasGitDir: true, hasLocalSkills: true), .alreadyConfigured)
        XCTAssertEqual(SyncSetupModel.firstSyncPlan(hasGitDir: true, hasLocalSkills: false), .alreadyConfigured)
        XCTAssertEqual(SyncSetupModel.firstSyncPlan(hasGitDir: false, hasLocalSkills: true), .initAndPush)
        XCTAssertEqual(SyncSetupModel.firstSyncPlan(hasGitDir: false, hasLocalSkills: false), .cloneAndRebuild)
    }

    // MARK: - parseRemote

    func testParseRemoteDelegatesToPolicy() {
        XCTAssertEqual(SyncSetupModel.parseRemote("https://github.com/octocat/x.git"),
                       RemoteURLPolicy.parse("https://github.com/octocat/x.git"))
        XCTAssertNil(SyncSetupModel.parseRemote("file:///tmp/x"))
    }

    // MARK: - connect: call order

    func testConnectInitAndPushCallOrder() async throws {
        let git = RecordingGitService()   // remoteHasCommits false -> fresh remote, skip pull
        let model = try makeModel(git: git, credentials: InMemoryCredentialStore(),
                                  rebuilder: RecordingRebuilder(), fileService: existingUserFiles())
        await model.connectAndReport(url: "https://github.com/octocat/x.git", username: "octocat", token: "tok")
        XCTAssertEqual(git.calls, ["lsremote-symref:https://github.com/octocat/x.git",
                                   "lsremote-heads:https://github.com/octocat/x.git", "init:\(root)",
                                   "remote:https://github.com/octocat/x.git",
                                   "commit", "remoteHasCommits", "push"])
        XCTAssertEqual(model.state, .done)
    }

    func testConnectShortCircuitsUnderPreHeldLock() async throws {
        let lockPath = root + "-held-sync.lock"
        let held = SyncLock.tryAcquire(at: lockPath)
        defer { held?.release() }
        XCTAssertNotNil(held)
        let git = RecordingGitService()
        let model = try makeModel(git: git, credentials: InMemoryCredentialStore(),
                                  rebuilder: RecordingRebuilder(), fileService: existingUserFiles(),
                                  lockPath: lockPath)
        await model.connectAndReport(url: "https://github.com/octocat/x.git", username: "octocat", token: "tok")
        guard case let .failed(message) = model.state else { return XCTFail("expected .failed") }
        XCTAssertTrue(message.contains("already running"), "message: \(message)")
        XCTAssertTrue(git.calls.isEmpty, "lock must short-circuit before setup git operations")
    }

    func testDisconnectRemovesHTTPSRemoteAndItsCredentialOnly() async throws {
        let git = RecordingGitService()
        git.configuredRemoteURLFixture = .success("https://github.com/octocat/pensieve-skills.git")
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "sync-token", username: "octocat", forHost: "github.com")
        try credentials.store(token: "install-token", username: "octocat", forHost: CredentialHost.githubInstall)
        let model = try makeModel(git: git, credentials: credentials,
                                  rebuilder: RecordingRebuilder(), fileService: StubFileService())

        try await model.performDisconnect()

        XCTAssertEqual(git.calls, ["config-remote:\(root)", "remove-remote:\(root)"])
        XCTAssertNil(credentials.credential(forHost: "github.com"))
        XCTAssertNotNil(credentials.credential(forHost: CredentialHost.githubInstall))
    }

    func testDisconnectKeepsCredentialStoreForSSH() async throws {
        let git = RecordingGitService()
        git.configuredRemoteURLFixture = .success("git@github.com:octocat/pensieve-skills.git")
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "sync-token", username: "octocat", forHost: "github.com")
        let model = try makeModel(git: git, credentials: credentials,
                                  rebuilder: RecordingRebuilder(), fileService: StubFileService())

        try await model.performDisconnect()

        XCTAssertEqual(git.calls, ["config-remote:\(root)", "remove-remote:\(root)"])
        XCTAssertNotNil(credentials.credential(forHost: "github.com"))
    }

    func testDisconnectWithoutRemoteIsNoOp() async throws {
        let git = RecordingGitService()
        git.configuredRemoteURLFixture = .success(nil)
        let model = try makeModel(git: git, credentials: InMemoryCredentialStore(),
                                  rebuilder: RecordingRebuilder(), fileService: StubFileService())

        try await model.performDisconnect()
        XCTAssertFalse(git.calls.contains(where: { $0.hasPrefix("remove-remote:") }))
    }

    func testDisconnectPropagatesBrokenRepositoryRead() async throws {
        let git = RecordingGitService()
        git.configuredRemoteURLFixture = .failure(StubBoom())
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "sync-token", username: "octocat", forHost: "github.com")
        let model = try makeModel(git: git, credentials: credentials,
                                  rebuilder: RecordingRebuilder(), fileService: StubFileService())

        await XCTAssertThrowsErrorAsync(try await model.performDisconnect())
        XCTAssertFalse(git.calls.contains(where: { $0.hasPrefix("remove-remote:") }))
        XCTAssertNotNil(credentials.credential(forHost: "github.com"))
    }

    func testDisconnectKeychainFailureLeavesRemoteInPlace() async throws {
        let git = RecordingGitService()
        git.configuredRemoteURLFixture = .success("https://github.com/octocat/pensieve-skills.git")
        let model = try makeModel(git: git, credentials: ThrowingCredentialStore(),
                                  rebuilder: RecordingRebuilder(), fileService: StubFileService())

        await XCTAssertThrowsErrorAsync(try await model.performDisconnect())
        XCTAssertFalse(git.calls.contains(where: { $0.hasPrefix("remove-remote:") }))
    }

    func testDisconnectRefusesWhileSyncLocked() async throws {
        let lockPath = root + "-disconnect-held.lock"
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { held.release() }
        let git = RecordingGitService()
        git.configuredRemoteURLFixture = .success("https://github.com/octocat/pensieve-skills.git")
        let model = try makeModel(git: git, credentials: InMemoryCredentialStore(),
                                  rebuilder: RecordingRebuilder(), fileService: StubFileService(),
                                  lockPath: lockPath)

        await XCTAssertThrowsErrorAsync(try await model.performDisconnect()) {
            XCTAssertEqual($0 as? SyncError, .syncInProgress)
        }
        XCTAssertFalse(git.calls.contains(where: { $0.hasPrefix("remove-remote:") }))
    }

    func testConnectCloneAndRebuild() async throws {
        let git = RecordingGitService()
        let rebuilder = RecordingRebuilder()
        let model = try makeModel(git: git, credentials: InMemoryCredentialStore(),
                                  rebuilder: rebuilder, fileService: StubFileService())   // no .git, no skills
        await model.connectAndReport(url: "git@github.com:octocat/x.git", username: "", token: "")
        XCTAssertEqual(git.calls, ["lsremote-symref:git@github.com:octocat/x.git",
                                   "lsremote-heads:git@github.com:octocat/x.git", "clone:git@github.com:octocat/x.git→\(root)"])
        XCTAssertEqual(rebuilder.rebuildCount, 1)
        XCTAssertEqual(model.state, .done)
    }

    func testCloneOfNewerSchemaRemoteFailsInsteadOfReportingDone() async throws {
        let git = RecordingGitService()
        let rebuilder = RecordingRebuilder()
        rebuilder.result.storeUnreadable = true
        let model = try makeModel(git: git, credentials: InMemoryCredentialStore(),
                                  rebuilder: rebuilder, fileService: StubFileService())
        await model.connectAndReport(url: "git@github.com:octocat/x.git", username: "", token: "")
        XCTAssertEqual(git.calls, ["lsremote-symref:git@github.com:octocat/x.git",
                                   "lsremote-heads:git@github.com:octocat/x.git", "clone:git@github.com:octocat/x.git→\(root)"])
        guard case .failed = model.state else { return XCTFail("expected .failed, got \(model.state)") }
    }

    // MARK: - connect: credentials

    func testHTTPSConnectStoresPAT() async throws {
        let git = RecordingGitService()
        let creds = InMemoryCredentialStore()
        let model = try makeModel(git: git, credentials: creds,
                                  rebuilder: RecordingRebuilder(), fileService: existingUserFiles())
        await model.connectAndReport(url: "https://github.com/octocat/x.git", username: "octocat", token: "secret")
        XCTAssertEqual(creds.credential(forHost: "github.com"), .httpsToken(username: "octocat", token: "secret"))
        XCTAssertEqual(git.lastCredential, .httpsToken(username: "octocat", token: "secret"))
    }

    // MARK: - connect: auth-failure messaging

    func testAuthFailureMessageByTransport() async throws {
        let httpsGit = RecordingGitService()
        httpsGit.throwAuthOn = "push"
        let httpsModel = try makeModel(git: httpsGit, credentials: InMemoryCredentialStore(),
                                       rebuilder: RecordingRebuilder(), fileService: existingUserFiles())
        await httpsModel.connectAndReport(url: "https://github.com/octocat/x.git", username: "octocat", token: "tok")
        guard case let .failed(httpsMessage) = httpsModel.state else { return XCTFail("expected .failed") }
        XCTAssertTrue(httpsMessage.contains("authenticate"), "https message: \(httpsMessage)")
        XCTAssertTrue(httpsMessage.contains("access token"), "https message should be https-specific")

        let sshGit = RecordingGitService()
        sshGit.throwAuthOn = "clone"
        let sshModel = try makeModel(git: sshGit, credentials: InMemoryCredentialStore(),
                                     rebuilder: RecordingRebuilder(), fileService: StubFileService())
        await sshModel.connectAndReport(url: "git@github.com:octocat/x.git", username: "", token: "")
        guard case let .failed(sshMessage) = sshModel.state else { return XCTFail("expected .failed") }
        XCTAssertTrue(sshMessage.contains("authenticate"), "ssh message: \(sshMessage)")
        XCTAssertTrue(sshMessage.contains("SSH"), "ssh message should be ssh-specific")
    }

    // MARK: - connect: a diverged remote fails safely (no push/clobber; PLAN-09 resolves)

    func testInitAndPushDivergedRemoteFailsSafely() async throws {
        let git = RecordingGitService()
        git.remoteHasCommitsResult = true
        git.pullResult = .conflicted(["skills/x/SKILL.md"])
        let model = try makeModel(git: git, credentials: InMemoryCredentialStore(),
                                  rebuilder: RecordingRebuilder(), fileService: existingUserFiles())
        await model.connectAndReport(url: "https://github.com/octocat/x.git", username: "octocat", token: "tok")
        XCTAssertEqual(git.calls, ["lsremote-symref:https://github.com/octocat/x.git",
                                   "lsremote-heads:https://github.com/octocat/x.git", "init:\(root)",
                                   "remote:https://github.com/octocat/x.git", "commit",
                                   "remoteHasCommits", "pull", "abort"])
        XCTAssertFalse(git.calls.contains("push"), "must NOT push a diverged remote")
        guard case let .failed(message) = model.state else { return XCTFail("expected .failed") }
        XCTAssertTrue(message.contains("diverging"), "message: \(message)")
    }
}

// MARK: - PLAN-24 / 24.2 stub adoption and classifier coverage

extension SyncSetupModelTests {
    private var remoteURL: String { "https://github.com/octocat/x.git" }

    private func runConnect(
        file: FileServiceProtocol,
        git: RecordingGitService,
        rebuilder: RecordingRebuilder,
        context: ModelContext? = nil,
        familiesEmpty: (() -> Bool?)? = { true }
    ) async throws -> SyncSetupModel {
        let model = try makeModel(
            git: git,
            credentials: InMemoryCredentialStore(),
            rebuilder: rebuilder,
            fileService: file,
            context: context,
            syncedFamiliesEmpty: familiesEmpty
        )
        await model.connectAndReport(url: remoteURL, username: "octocat", token: "tok")
        return model
    }

    private func assertPlainCloneRefusal(_ file: StubFileService) async throws {
        let trace = file.trace
        let git = RecordingGitService(trace: trace)
        let rebuild = RecordingRebuilder(trace: trace)
        let model = try await runConnect(file: file, git: git, rebuilder: rebuild)
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(trace.events, ["lsremote-symref:\(remoteURL)", "lsremote-heads:\(remoteURL)",
                                     "clone:\(remoteURL)→\(root)", "rebuild:\(root)"])
        XCTAssertFalse(trace.events.contains(where: { $0.hasPrefix("delete:") }))
    }

    func testVirginAdoptionOrderTrace() async throws {
        let trace = EventTrace()
        let git = RecordingGitService(trace: trace)
        let rebuild = RecordingRebuilder(trace: trace)
        let model = try await runConnect(file: virginScaffold(trace: trace), git: git, rebuilder: rebuild)
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(trace.events, [
            "lsremote-symref:\(remoteURL)", "lsremote-heads:\(remoteURL)", "init:\(root)",
            "remote:\(remoteURL)", "fetch:main", "restore-fetch-head", "born:main",
            "rebuild:\(root)", "upstream:main"
        ])
    }

    func testVirginAdoptionNeverRemoves() async throws {
        let trace = EventTrace()
        _ = try await runConnect(
            file: virginScaffold(trace: trace),
            git: RecordingGitService(trace: trace),
            rebuilder: RecordingRebuilder(trace: trace)
        )
        XCTAssertFalse(trace.events.contains(where: { $0.hasPrefix("delete:") }))
    }

    func testNonEmptySwiftDataFamilyRefused() async throws {
        let insertions: [(ModelContext) -> Void] = [
            { $0.insert(Skill(name: "S", directoryName: "s")) },
            { $0.insert(PensieveCategory(name: "C")) },
            { $0.insert(Project(name: "P", path: "/tmp/p")) },
            { $0.insert(MachineDeployIntent(machineID: UUID().uuidString.lowercased(), skillSlug: "s", platformRaw: "codex")) }
        ]
        for insert in insertions {
            let context = try makeContext()
            insert(context)
            try context.save()
            let trace = EventTrace()
            let file = virginScaffold(trace: trace)
            let model = try await runConnect(
                file: file,
                git: RecordingGitService(trace: trace),
                rebuilder: RecordingRebuilder(trace: trace),
                context: context,
                familiesEmpty: nil
            )
            XCTAssertEqual(model.state, .done)
            XCTAssertTrue(trace.events.contains(where: { $0.hasPrefix("clone:") }), "trace: \(trace.events)")
        }

    }

    func testSwiftDataFetchFailureRefused() async throws {
        let file = virginScaffold()
        _ = try await runConnect(
            file: file, git: RecordingGitService(trace: file.trace),
            rebuilder: RecordingRebuilder(trace: file.trace), familiesEmpty: { nil }
        )
        XCTAssertTrue(file.trace.events.contains(where: { $0.hasPrefix("clone:") }))
    }

    func testSkillBodyRefused() async throws {
        let file = virginScaffold()
        let path = root + "/manifest/skills"
        file.listing[path] = ["alpha.yaml"]
        try await assertPlainCloneRefusal(file)
    }

    func testStrayTopLevelRefused() async throws {
        let file = virginScaffold(); file.listing[root]?.append("notes.txt")
        try await assertPlainCloneRefusal(file)
    }

    func testMachinesDirRefused() async throws {
        let file = virginScaffold(); file.listing[root + "/manifest"]?.append("machines")
        try await assertPlainCloneRefusal(file)
    }

    func testMissingManifestEntryRefused() async throws {
        let file = virginScaffold(); file.listing[root + "/manifest"]?.removeAll { $0 == "deploys" }
        try await assertPlainCloneRefusal(file)
    }

    func testWrongTypeManifestEntryRefused() async throws {
        let file = virginScaffold(); file.regularFiles.remove(root + "/manifest/projects.yaml")
        try await assertPlainCloneRefusal(file)
    }

    func testSymlinkedRootRefused() async throws {
        let file = virginScaffold(); file.symlinks.insert(root)
        try await assertPlainCloneRefusal(file)
    }

    func testSymlinkedManifestAnchorRefused() async throws {
        let file = virginScaffold(); file.symlinks.insert(root + "/manifest")
        try await assertPlainCloneRefusal(file)
    }

    func testSymlinkedChildDirRefused() async throws {
        let file = virginScaffold(); file.symlinks.insert(root + "/manifest/skills")
        try await assertPlainCloneRefusal(file)
    }

    func testOtherHiddenFileRefused() async throws {
        let file = virginScaffold(); file.listing[root + "/manifest/categories"] = [".keep"]
        try await assertPlainCloneRefusal(file)
    }

    func testDSStoreToleratedAllLevels() async throws {
        let trace = EventTrace(); let file = virginScaffold(trace: trace)
        for path in [root, root + "/manifest", root + "/manifest/categories"] {
            file.listing[path]?.append(".DS_Store")
            file.regularFiles.insert(path + "/.DS_Store")
        }
        let model = try await runConnect(
            file: file, git: RecordingGitService(trace: trace), rebuilder: RecordingRebuilder(trace: trace)
        )
        XCTAssertEqual(model.state, .done)
        XCTAssertTrue(trace.events.contains("init:\(root)"))
    }

    func testOldSchemaRefused() async throws {
        let file = virginScaffold(); file.contents[root + "/manifest/manifest.yaml"] = "schema_version: 3\n"
        try await assertPlainCloneRefusal(file)
    }

    func testNewerSchemaRefused() async throws {
        let file = virginScaffold(); file.contents[root + "/manifest/manifest.yaml"] = "schema_version: 6\n"
        try await assertPlainCloneRefusal(file)
    }

    func testMalformedSchemaRefused() async throws {
        let file = virginScaffold(); file.contents[root + "/manifest/manifest.yaml"] = "schema_version: nope\n"
        try await assertPlainCloneRefusal(file)
    }

    func testNonEmptyProjectsRefused() async throws {
        let file = virginScaffold(); file.contents[root + "/manifest/projects.yaml"] = "projects:\n  - nope\n"
        try await assertPlainCloneRefusal(file)
    }

    func testUnreadableManifestRefused() async throws {
        let file = virginScaffold(); file.readErrors.insert(root + "/manifest/manifest.yaml")
        try await assertPlainCloneRefusal(file)
    }

    func testAbsentRootPlainCloneUnchanged() async throws {
        try await assertPlainCloneRefusal(StubFileService())
    }

    func testRefusedStoreFallsBackToPlainClone() async throws {
        let file = virginScaffold(); file.listing[root]?.append("user.txt")
        try await assertPlainCloneRefusal(file)
    }

    func testDefaultBranchPolicySymrefWins() {
        XCTAssertEqual(SyncSetupModel.defaultBranch(symref: "trunk", heads: ["main"]), "trunk")
    }

    // Frozen method name mirrors git's conventional fallback branch spelling.
    // swiftlint:disable:next inclusive_language
    func testDefaultBranchPolicyFallbackMainThenMaster() {
        XCTAssertEqual(SyncSetupModel.defaultBranch(symref: nil, heads: ["master", "main"]), "main")
        XCTAssertEqual(SyncSetupModel.defaultBranch(symref: nil, heads: ["master"]), "master")
    }

    func testDefaultBranchPolicyRejectsInvalidNames() {
        for invalid in ["", "@", "-dash", "a//b", "a/.b", "a.lock", "a.", "a..b", "a@{b", "a b", "a~b"] {
            XCTAssertFalse(SyncSetupModel.isValidBranchName(invalid), invalid)
            XCTAssertEqual(SyncSetupModel.defaultBranch(symref: invalid, heads: ["main"]), "main")
        }
        XCTAssertFalse(SyncSetupModel.isValidBranchName(String(repeating: "a", count: 251)))
    }

    func testDefaultBranchUndeterminedFailsBeforeAnyMutation() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.defaultBranchFixture = nil; git.branchesFixture = ["trunk"]
        let model = try await runConnect(
            file: virginScaffold(trace: trace), git: git, rebuilder: RecordingRebuilder(trace: trace)
        )
        guard case .failed = model.state else { return XCTFail("expected failure") }
        XCTAssertEqual(trace.events, ["lsremote-symref:\(remoteURL)", "lsremote-heads:\(remoteURL)"])
    }

    func testRemoteDefaultBranchAuthFailureSurfacesAuth() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.throwAuthOn = "lsremote-symref:\(remoteURL)"
        let model = try await runConnect(file: virginScaffold(trace: trace), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace))
        guard case let .failed(message) = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("access token"))
    }

    func testRemoteBranchesAuthFailureSurfacesAuth() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.throwAuthOn = "lsremote-heads:\(remoteURL)"
        let model = try await runConnect(file: virginScaffold(trace: trace), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace))
        guard case let .failed(message) = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("access token"))
    }

    func testNonMainDefaultInsertsBranchMove() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.defaultBranchFixture = "master"; git.branchesFixture = ["master"]
        _ = try await runConnect(file: virginScaffold(trace: trace), git: git,
                                 rebuilder: RecordingRebuilder(trace: trace))
        XCTAssertTrue(trace.events.contains("checkout-B:master"))
        XCTAssertLessThan(try XCTUnwrap(trace.events.firstIndex(of: "remote:\(remoteURL)")),
                          try XCTUnwrap(trace.events.firstIndex(of: "checkout-B:master")))
    }

    func testFetchFailureSurfacesErrorNothingRemoved() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace); git.throwOn = "fetch:main"
        let model = try await runConnect(file: virginScaffold(trace: trace), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace))
        guard case .failed = model.state else { return XCTFail("expected failure") }
        XCTAssertFalse(trace.events.contains(where: { $0.hasPrefix("delete:") || $0.hasPrefix("rebuild:") }))
    }

    func testBornBranchFailureSurfacesErrorNoRebuild() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace); git.throwOn = "born:main"
        let model = try await runConnect(file: virginScaffold(trace: trace), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace))
        guard case .failed = model.state else { return XCTFail("expected failure") }
        XCTAssertFalse(trace.events.contains(where: { $0.hasPrefix("rebuild:") }))
    }

    func testSignalThrowFailsConnectZeroEvents() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.hasLocalBranchesFixture = .failure(StubBoom())
        let model = try await runConnect(file: virginScaffold(trace: trace, gitDir: true), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace))
        guard case .failed = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(trace.events.isEmpty)
    }

    func testBranchlessVirginReadopts() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.hasLocalBranchesFixture = .success(false); git.remoteURLFixture = remoteURL
        let model = try await runConnect(file: virginScaffold(trace: trace, gitDir: true), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace))
        XCTAssertEqual(model.state, .done); XCTAssertTrue(trace.events.contains("restore-fetch-head"))
    }

    func testBranchlessNoOriginVirginReadopts() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.hasLocalBranchesFixture = .success(false); git.remoteURLFixture = nil
        let model = try await runConnect(file: virginScaffold(trace: trace, gitDir: true), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace))
        XCTAssertEqual(model.state, .done); XCTAssertTrue(trace.events.contains("remote:\(remoteURL)"))
    }

    func testMidAdoptionErrorMessageContract() {
        let message = SyncSetupError.midAdoptionStoreUnrecognized.errorDescription ?? ""
        XCTAssertTrue(message.contains("Nothing was changed")); XCTAssertTrue(message.contains("~/.pensieve"))
    }

    private func nonVirginBranchlessHarness(
        remote: String?, tracking: Bool, familiesEmpty: Bool?
    ) async throws -> (SyncSetupModel, EventTrace) {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.hasLocalBranchesFixture = .success(false); git.remoteURLFixture = remote
        git.hasRemoteTrackingBranchFixture = tracking
        let file = virginScaffold(trace: trace, gitDir: true)
        file.listing[root]?.append("partial.txt")
        let model = try await runConnect(
            file: file, git: git, rebuilder: RecordingRebuilder(trace: trace),
            familiesEmpty: { familiesEmpty }
        )
        return (model, trace)
    }

    func testBranchlessPartialSameOriginWithTrackingRefReadopts() async throws {
        let (model, trace) = try await nonVirginBranchlessHarness(
            remote: remoteURL, tracking: true, familiesEmpty: true
        )
        XCTAssertEqual(model.state, .done); XCTAssertTrue(trace.events.contains("restore-fetch-head"))
    }

    func testBranchlessMatchingOriginWithoutTrackingRefThrowsZeroEvents() async throws {
        let (model, trace) = try await nonVirginBranchlessHarness(
            remote: remoteURL, tracking: false, familiesEmpty: true
        )
        guard case .failed = model.state else { return XCTFail("expected failure") }
        XCTAssertEqual(trace.events, ["lsremote-symref:\(remoteURL)", "lsremote-heads:\(remoteURL)"])
    }

    func testBranchlessDifferentOriginThrowsZeroEvents() async throws {
        let (model, trace) = try await nonVirginBranchlessHarness(
            remote: "https://example.com/other.git", tracking: true, familiesEmpty: true
        )
        guard case .failed = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(trace.events.isEmpty)
    }

    func testBranchlessNonEmptyFamiliesThrowsZeroEvents() async throws {
        let (model, trace) = try await nonVirginBranchlessHarness(
            remote: remoteURL, tracking: true, familiesEmpty: false
        )
        guard case .failed = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(trace.events.isEmpty)
    }

    func testLocalBranchesPresentNeverReadopts() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        git.hasLocalBranchesFixture = .success(true)
        let model = try await runConnect(file: virginScaffold(trace: trace, gitDir: true), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace), familiesEmpty: { false })
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(trace.events, ["remote:\(remoteURL)"])
    }

    func testLocalBranchesEmptyFamiliesRebuilds() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        let model = try await runConnect(file: virginScaffold(trace: trace, gitDir: true), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace))
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(trace.events, ["remote:\(remoteURL)", "rebuild:\(root)"])
    }

    func testLocalBranchesNonEmptyFamiliesSkipsRebuild() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        let model = try await runConnect(file: virginScaffold(trace: trace, gitDir: true), git: git,
                                         rebuilder: RecordingRebuilder(trace: trace), familiesEmpty: { false })
        XCTAssertEqual(model.state, .done); XCTAssertEqual(trace.events, ["remote:\(remoteURL)"])
    }

    // The frozen method pins both non-empty and empty fetched-store retry arms in one body.
    // swiftlint:disable:next function_body_length
    func testUpstreamFailureAfterIngestRetrySetRemoteOnly() async throws {
        let trace = EventTrace(); let git = RecordingGitService(trace: trace); git.throwOn = "upstream:main"
        let file = virginScaffold(trace: trace)
        let rebuild = RecordingRebuilder(trace: trace)
        var familiesEmpty = true
        let first = try await runConnect(
            file: file,
            git: git,
            rebuilder: rebuild,
            familiesEmpty: { familiesEmpty }
        )
        guard case .failed = first.state else { return XCTFail("expected first failure") }
        XCTAssertEqual(trace.events, [
            "lsremote-symref:\(remoteURL)", "lsremote-heads:\(remoteURL)", "init:\(root)",
            "remote:\(remoteURL)", "fetch:main", "restore-fetch-head", "born:main",
            "rebuild:\(root)", "upstream:main"
        ])

        familiesEmpty = false
        git.throwOn = nil; git.hasLocalBranchesFixture = .success(true); file.dirs.insert(root + "/.git")
        file.listing[root] = ["manifest", ".git"]
        let retryStart = trace.events.count
        let second = try await runConnect(
            file: file,
            git: git,
            rebuilder: rebuild,
            familiesEmpty: { familiesEmpty }
        )
        XCTAssertEqual(second.state, .done)
        XCTAssertEqual(trace.events.filter { $0 == "init:\(root)" }.count, 1)
        XCTAssertEqual(Array(trace.events[retryStart...]), ["remote:\(remoteURL)"])

        let emptyTrace = EventTrace()
        let emptyGit = RecordingGitService(trace: emptyTrace); emptyGit.throwOn = "upstream:main"
        let emptyFile = virginScaffold(trace: emptyTrace)
        let emptyRebuild = RecordingRebuilder(trace: emptyTrace)
        let emptyFirst = try await runConnect(
            file: emptyFile,
            git: emptyGit,
            rebuilder: emptyRebuild,
            familiesEmpty: { true }
        )
        guard case .failed = emptyFirst.state else { return XCTFail("expected empty-remote first failure") }
        emptyGit.throwOn = nil
        emptyGit.hasLocalBranchesFixture = .success(true)
        emptyFile.dirs.insert(root + "/.git")
        emptyFile.listing[root] = ["manifest", ".git"]
        let emptyRetryStart = emptyTrace.events.count
        let emptyRetry = try await runConnect(
            file: emptyFile,
            git: emptyGit,
            rebuilder: emptyRebuild,
            familiesEmpty: { true }
        )
        XCTAssertEqual(emptyRetry.state, .done)
        XCTAssertEqual(
            Array(emptyTrace.events[emptyRetryStart...]),
            ["remote:\(remoteURL)", "rebuild:\(root)"]
        )
    }

    func testStoreUnreadableFromRanRebuildThrows() async throws {
        let trace = EventTrace(); let rebuild = RecordingRebuilder(trace: trace)
        rebuild.result.storeUnreadable = true
        let model = try await runConnect(file: virginScaffold(trace: trace),
                                         git: RecordingGitService(trace: trace), rebuilder: rebuild)
        guard case .failed = model.state else { return XCTFail("expected failure") }
    }

    func testPreHeldLockZeroGitAndFilesystemEvents() async throws {
        let lockPath = root + "-plan24-held.lock"
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath)); defer { held.release() }
        let trace = EventTrace(); let git = RecordingGitService(trace: trace)
        let model = try makeModel(
            git: git, credentials: InMemoryCredentialStore(),
            rebuilder: RecordingRebuilder(trace: trace), fileService: virginScaffold(trace: trace),
            lockPath: lockPath, syncedFamiliesEmpty: { true }
        )
        await model.connectAndReport(url: remoteURL, username: "octocat", token: "tok")
        guard case .failed = model.state else { return XCTFail("expected failure") }
        XCTAssertTrue(trace.events.isEmpty)
    }
}

// MARK: - PLAN-24 / 24.2 disk-backed and real-git fixtures

extension SyncSetupModelTests {
    private struct BareFixture {
        let remote: String
        let barePath: String
        let seedPath: String
        let branch: String
    }

    @discardableResult
    private func fixtureGit(_ args: [String], in directory: String? = nil) throws -> GitService.GitOutput {
        try TestPaths.git.runOrThrow(args, in: directory)
    }

    private func makeBareFixture(
        branch: String = "main",
        danglingHead: Bool = false,
        collisionShapes: Bool = false
    ) throws -> BareFixture {
        let fixtures = root + "-fixtures"
        try FileManager.default.createDirectory(atPath: fixtures, withIntermediateDirectories: true)
        let suffix = UUID().uuidString
        let bare = fixtures + "/\(suffix).git"
        let seed = fixtures + "/\(suffix)-seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        let git = TestPaths.git
        try git.initRepository(at: seed)
        if branch != "main" { try git.checkoutUnbornBranch(branch, at: seed) }
        try ManifestService().write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [], projects: [], skills: []
            ),
            toRoot: seed
        )
        try FileService().writeFile(
            at: seed + "/skills/remote-skill/SKILL.md",
            content: SkillSerializer.serialize(
                name: "Remote Skill", description: "fixture", body: "Remote body"
            )
        )
        if collisionShapes {
            try FileManager.default.removeItem(atPath: seed + "/manifest/categories")
            try "remote category collision\n".write(
                toFile: seed + "/manifest/categories", atomically: true, encoding: .utf8
            )
            try "remote ds\n".write(toFile: seed + "/.DS_Store", atomically: true, encoding: .utf8)
            // Model an older build's tracked file independently of Pensieve's new-file exclusions.
            try fixtureGit(["-C", seed, "add", "--force", "--", ".DS_Store"])
            try fixtureGit(["-C", seed, "commit", "-m", "older build tracked Finder metadata"])
        }
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try fixtureGit(["init", "--bare", bare])
        // Every PLAN-24 bare fixture pins HEAD explicitly; dangling-HEAD coverage repoints it afterward.
        try fixtureGit(["-C", bare, "symbolic-ref", "HEAD", "refs/heads/\(branch)"])
        try git.setRemote("file://" + bare, at: seed)
        try fixtureGit(["-C", seed, "push", "-u", "origin", branch])
        if danglingHead {
            try fixtureGit(["-C", bare, "symbolic-ref", "HEAD", "refs/heads/missing"])
        }
        return BareFixture(remote: "file://" + bare, barePath: bare, seedPath: seed, branch: branch)
    }

    private func writeRealScaffold() throws {
        try ManifestService().write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [], projects: [], skills: []
            ),
            toRoot: root
        )
    }

    private func makeRealModel(context: ModelContext? = nil) throws -> (SyncSetupModel, ModelContext) {
        let resolvedContext = try context ?? makeContext()
        return (
            SyncSetupModel(
                context: resolvedContext,
                git: TestPaths.git,
                credentials: InMemoryCredentialStore(),
                rebuilder: StoreRebuildService(),
                fileService: FileService(),
                root: root,
                lockPath: root + "-real.lock"
            , steps: SyncStepModel()),
            resolvedContext
        )
    }

    private func performReal(_ model: SyncSetupModel, remote: String) async throws {
        try await model.perform(
            spec: RemoteSpec(url: remote, host: "local-fixture", transport: .ssh),
            credential: .sshAgent
        )
    }

    private func skillCount(_ context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<Skill>())
    }

    func testRealScaffoldJudgedVirgin() async throws {
        for legacyFolder in [false, true] {
            let fixture = try makeBareFixture()
            try writeRealScaffold()
            if legacyFolder { try FileService().createDirectory(at: root + "/manifest/scenarios") }
            let rootIdentity = FileService().fileIdentity(at: root, followingLinks: false)
            let (model, context) = try makeRealModel()
            try await performReal(model, remote: fixture.remote)
            XCTAssertEqual(FileService().fileIdentity(at: root, followingLinks: false), rootIdentity)
            XCTAssertTrue(try TestPaths.git.hasLocalBranches(at: root))
            XCTAssertEqual(try skillCount(context), 1)
            XCTAssertTrue(FileService().fileExists(at: root + "/skills/remote-skill/SKILL.md"))
            try FileService().deleteDirectory(at: root)
        }
    }

    func testRealScaffoldWithContentRefused() async throws {
        for child in ["skills/local.yaml", "scenarios/legacy.yaml"] {
            let fixture = try makeBareFixture()
            try writeRealScaffold()
            let localPath = root + "/manifest/" + child
            try FileService().writeFile(at: localPath, content: "local\n")
            let (model, _) = try makeRealModel()
            await XCTAssertThrowsErrorAsync(try await performReal(model, remote: fixture.remote))
            XCTAssertEqual(try FileService().readFile(at: localPath), "local\n")
            XCTAssertFalse(FileService().directoryExists(at: root + "/.git"))
            try FileService().deleteDirectory(at: root)
        }
    }

    func testRealGitAdoptionEndToEndUntrackedSurvivesUpstreamSet() async throws {
        let fixture = try makeBareFixture()
        try writeRealScaffold()
        try "local ds\n".write(toFile: root + "/.DS_Store", atomically: true, encoding: .utf8)
        let (model, _) = try makeRealModel()
        try await performReal(model, remote: fixture.remote)
        XCTAssertEqual(try String(contentsOfFile: root + "/.DS_Store", encoding: .utf8), "local ds\n")
        let upstream = try fixtureGit([
            "-C", root, "rev-parse", "--abbrev-ref", "main@{upstream}"
        ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(upstream, "origin/main")
        XCTAssertTrue(FileService().fileExists(at: root + "/skills/remote-skill/SKILL.md"))
    }

    func testRealGitCollisionShapesReplaceOnlyAdmittedEntries() async throws {
        let fixture = try makeBareFixture(collisionShapes: true)
        try writeRealScaffold()
        try "local ds\n".write(toFile: root + "/.DS_Store", atomically: true, encoding: .utf8)
        let (model, _) = try makeRealModel()
        try await performReal(model, remote: fixture.remote)
        XCTAssertEqual(try String(contentsOfFile: root + "/manifest/categories", encoding: .utf8),
                       "remote category collision\n")
        XCTAssertEqual(try String(contentsOfFile: root + "/.DS_Store", encoding: .utf8), "remote ds\n")
        XCTAssertTrue(try TestPaths.git.hasLocalBranches(at: root))
    }

    func testRealGitHeadlessRemoteFallbackAdopts() async throws {
        let fixture = try makeBareFixture(branch: "master", danglingHead: true)
        try writeRealScaffold()
        let (model, _) = try makeRealModel()
        try await performReal(model, remote: fixture.remote)
        XCTAssertEqual(try TestPaths.git.currentBranch(at: root),
            "master")
    }

    func testRealGitCrashedHalfAdoptionRetryHeals() async throws {
        let fixture = try makeBareFixture()
        try writeRealScaffold()
        let git = TestPaths.git
        try git.initRepository(at: root)
        try git.setRemote(fixture.remote, at: root)
        try git.fetchBranch("main", at: root, credential: nil)
        let (model, _) = try makeRealModel()
        try await performReal(model, remote: fixture.remote)
        XCTAssertTrue(try git.hasLocalBranches(at: root))
        XCTAssertTrue(FileService().fileExists(at: root + "/skills/remote-skill/SKILL.md"))
    }

    func testRealGitPartialMaterializationRetryHeals() async throws {
        let fixture = try makeBareFixture()
        try writeRealScaffold()
        let git = TestPaths.git
        try git.initRepository(at: root); try git.setRemote(fixture.remote, at: root)
        try git.fetchBranch("main", at: root, credential: nil); try git.materializeFromFetchHead(at: root)
        try "garbage\n".write(toFile: root + "/manifest/manifest.yaml", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: root + "/skills/remote-skill/SKILL.md")
        let (model, _) = try makeRealModel()
        try await performReal(model, remote: fixture.remote)
        XCTAssertEqual(
            try String(contentsOfFile: root + "/manifest/manifest.yaml", encoding: .utf8),
            "schema_version: \(ManifestService.currentSchemaVersion)\n"
        )
        XCTAssertTrue(FileService().fileExists(at: root + "/skills/remote-skill/SKILL.md"))
    }

    func testRealGitCrashRelaunchRetryHealsWithLaunchQuarantine() async throws {
        let fixture = try makeBareFixture()
        try writeRealScaffold()
        let git = TestPaths.git
        try git.initRepository(at: root); try git.setRemote(fixture.remote, at: root)
        try git.fetchBranch("main", at: root, credential: nil); try git.materializeFromFetchHead(at: root)
        let context = try makeContext()
        let launch = LaunchReconciler(
            migrationService: StoreMigrationService(skillStore: SkillStore(fileService: FileService(),
                baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot)),
            fileService: FileService(),
            manifestService: ManifestService(),
            root: root,
            lockPath: root + "-launch.lock",
            git: git
        ).reconcileOnLaunch(context: context, alreadyMigrated: true)
        XCTAssertTrue(launch.quarantined); XCTAssertEqual(try skillCount(context), 0)
        let (model, _) = try makeRealModel(context: context)
        try await performReal(model, remote: fixture.remote)
        XCTAssertTrue(try git.hasLocalBranches(at: root)); XCTAssertEqual(try skillCount(context), 1)
    }

    func testRealGitCrashedInitAndPushRetryErrorsSkillUntouched() async throws {
        let fixture = try makeBareFixture()
        try FileService().writeFile(
            at: root + "/skills/local/SKILL.md",
            content: SkillSerializer.serialize(name: "Local", description: "local", body: "precious")
        )
        let skillPath = root + "/skills/local/SKILL.md"
        let before = try Data(contentsOf: URL(fileURLWithPath: skillPath))
        let git = TestPaths.git; try git.initRepository(at: root); try git.setRemote(fixture.remote, at: root)
        try fixtureGit(["-C", root, "add", "-A"])
        let (model, _) = try makeRealModel()
        await XCTAssertThrowsErrorAsync(try await performReal(model, remote: fixture.remote)) { error in
            XCTAssertEqual(error as? SyncSetupError, .midAdoptionStoreUnrecognized)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: skillPath)), before)
        XCTAssertFalse(try git.hasLocalBranches(at: root))
    }

    func testRealGitPreOriginInitAndPushCrashErrorsSkillUntouched() async throws {
        let fixture = try makeBareFixture()
        try FileService().writeFile(
            at: root + "/skills/local/SKILL.md",
            content: SkillSerializer.serialize(name: "Local", description: "local", body: "precious")
        )
        let skillPath = root + "/skills/local/SKILL.md"
        let before = try Data(contentsOf: URL(fileURLWithPath: skillPath))
        let git = TestPaths.git; try git.initRepository(at: root)
        let context = try makeContext()
        let launch = LaunchReconciler(
            migrationService: StoreMigrationService(skillStore: SkillStore(fileService: FileService(),
                baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot)),
            fileService: FileService(),
            manifestService: ManifestService(),
            root: root,
            lockPath: root + "-launch.lock",
            git: git
        ).reconcileOnLaunch(context: context, alreadyMigrated: true)
        XCTAssertFalse(launch.quarantined); XCTAssertEqual(try skillCount(context), 1)
        let (model, _) = try makeRealModel(context: context)
        await XCTAssertThrowsErrorAsync(try await performReal(model, remote: fixture.remote)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Nothing was changed")); XCTAssertTrue(message.contains("~/.pensieve"))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: skillPath)), before)
    }

    func testRealGitPreOriginCrashLaunchNoopThenHeals() async throws {
        let fixture = try makeBareFixture()
        try writeRealScaffold()
        let git = TestPaths.git; try git.initRepository(at: root)
        let context = try makeContext()
        let launch = LaunchReconciler(
            migrationService: StoreMigrationService(skillStore: SkillStore(fileService: FileService(),
                baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot)),
            fileService: FileService(),
            manifestService: ManifestService(),
            root: root,
            lockPath: root + "-launch.lock",
            git: git
        ).reconcileOnLaunch(context: context, alreadyMigrated: true)
        XCTAssertFalse(launch.quarantined); XCTAssertEqual(try skillCount(context), 0)
        let (model, _) = try makeRealModel(context: context)
        try await performReal(model, remote: fixture.remote)
        XCTAssertTrue(try git.hasLocalBranches(at: root)); XCTAssertEqual(try skillCount(context), 1)
    }

    func testRealGitForeignBranchRepoUntouched() async throws {
        let fixture = try makeBareFixture()
        try writeRealScaffold()
        let userPath = root + "/user.txt"
        try "user bytes\n".write(toFile: userPath, atomically: true, encoding: .utf8)
        let git = TestPaths.git; try git.initRepository(at: root)
        XCTAssertTrue(try git.stageAllAndCommit(at: root, message: "user commit"))
        let original = try git.commitSHA(at: root)
        try fixtureGit(["-C", root, "symbolic-ref", "HEAD", "refs/heads/weird"])
        let (model, _) = try makeRealModel()
        try await performReal(model, remote: fixture.remote)
        let main = try fixtureGit(["-C", root, "rev-parse", "refs/heads/main"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(main, original)
        XCTAssertEqual(try String(contentsOfFile: userPath, encoding: .utf8), "user bytes\n")
    }
}

// MARK: - Native setup jobs and their UI/quit boundaries

extension SyncSetupModelTests {
    func testHeldConnectStepsKeepMainActorFreeAndRenderButtonProgress() async throws {
        let remote = "https://github.com/octocat/x.git"
        let checking = ["probe", "read-remote", "read-branches", "lsremote-symref:\(remote)", "lsremote-heads:\(remote)",
                        "read-tracking"]
        let writing = ["init:\(root)", "remote:\(remote)", "checkout-B:trunk", "fetch:trunk",
                       "restore-fetch-head", "born:trunk", "upstream:trunk"]
        let otherWrites = ["clone", "commit", "remoteHasCommits", "pull", "push", "abort"]
        for step in checking + writing + otherWrites {
            let git = heldConnectGit(step: step, remote: remote)
            let gate = TestWait.Gate(owner: self)
            defer { gate.open() }
            let entered = expectation(description: step)
            let cancelled = checking.contains(step) ? expectation(description: "Cancellation requested at \(step)") : nil
            holdConnectStep(git: git, step: step, gate: gate, entered: entered, cancelled: cancelled)
            let file = otherWrites.contains(step) ? (step == "clone" ? StubFileService() : existingUserFiles())
                : virginScaffold(gitDir: true)
            if step == "read-tracking" { file.listing[root]?.append("partial.txt") }
            let credentials = InMemoryCredentialStore()
            try credentials.store(token: "original", username: "old", forHost: "github.com")
            let before = file.contents
            let model = try makeModel(git: git, credentials: credentials,
                rebuilder: RecordingRebuilder(), fileService: file)
            let host = setupHost(AnyView(SyncSetupView(model: model)))
            defer { host.window.close() }
            model.connect(url: remote, username: "octocat", token: "secret")
            XCTAssertEqual(model.state, .working, "The button must publish progress before launching git")
            await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
            XCTAssertEqual(model.canCancel, checking.contains(step), step)
            await TestWait.until(failureMessage: "Connect's button did not render progress at \(step)") {
                RenderedViewTestSupport.hasButtonProgress(in: host.view)
            }
            if checking.contains(step) {
                await assertCheckingSheetDisappears(model: model, previous: host, gate: gate,
                    cancelled: try XCTUnwrap(cancelled), step: step)
                XCTAssertEqual(file.contents, before, step)
                XCTAssertEqual(credentials.credential(forHost: "github.com"),
                    .httpsToken(username: "old", token: "original"), step)
                continue
            }
            let reopened = await reopenHeldSetup(model: model, previous: host, step: step)
            defer { reopened.window.close() }
            gate.open()
            await TestWait.until(failureMessage: "Connect did not finish at \(step)") { model.state != .working }
            if step == "abort" {
                guard case .failed = model.state else { return XCTFail("Divergence must retain its failure") }
            } else { XCTAssertEqual(model.state, .done, step) }
        }
    }

    func testFailedAndCancelledChecksPreserveExistingCredentialAndStore() async throws {
        for failure in ["auth", "offline", "cancel", "cancel-tracking"] {
            let cancelling = failure.hasPrefix("cancel")
            let tracking = failure == "cancel-tracking"
            let file = virginScaffold(gitDir: tracking)
            let git = RecordingGitService()
            if tracking {
                file.listing[root]?.append("partial.txt")
                git.remoteURLFixture = remoteURL
                git.hasLocalBranchesFixture = .success(false)
            }
            let credentials = InMemoryCredentialStore()
            try credentials.store(token: "original", username: "old", forHost: "github.com")
            let before = file.contents
            let step = tracking ? "read-tracking" : "lsremote-heads:\(remoteURL)"
            let gate = TestWait.Gate(owner: self)
            defer { gate.open() }
            let entered = cancelling ? expectation(description: "remote check") : nil
            if failure == "auth" { git.throwAuthOn = step }
            if failure == "offline" { git.throwOn = step }
            git.beforeCall = { call in
                XCTAssertFalse(Thread.isMainThread)
                if cancelling, call == step {
                    entered?.fulfill()
                    if !Thread.isMainThread { try? gate.wait() }
                }
            }
            let model = try makeModel(git: git, credentials: credentials,
                rebuilder: RecordingRebuilder(), fileService: file)
            let firstSheet = setupHost(AnyView(SyncSetupView(model: model)))
            await assertSetupTitle(in: firstSheet.view)
            if cancelling {
                model.connect(url: remoteURL, username: "new", token: "replacement")
                await fulfillment(of: [try XCTUnwrap(entered)], timeout: TestWait.timeoutSeconds)
                model.cancel()
                gate.open()
                await TestWait.until(failureMessage: "Cancelled check did not return") { model.state != .working }
                XCTAssertEqual(model.state, .cancelled)
            } else {
                gate.open()
                await model.connectAndReport(url: remoteURL, username: "new", token: "replacement")
                guard case .failed = model.state else { return XCTFail("Check must fail: \(failure)") }
            }
            XCTAssertEqual(credentials.credential(forHost: "github.com"), .httpsToken(username: "old", token: "original"))
            XCTAssertEqual(file.contents, before)
            XCTAssertEqual(git.calls, ["lsremote-symref:\(remoteURL)", "lsremote-heads:\(remoteURL)"],
                           "No store/config write after a failed check")
            await assertFreshSetup(model: model, previous: firstSheet, context: failure)
        }
    }

    func testHeldDisconnectRendersProgressAndQuitWaitsForBothOperations() async throws {
        try FileService().createDirectory(at: root)
        try TestPaths.git.initRepository(at: root)
        try TestPaths.git.setRemote("https://github.com/octocat/x.git", at: root)
        for disconnect in [true, false] {
            for quitAnyway in [false, true] {
                let git = RecordingGitService()
                git.configuredRemoteURLFixture = .success("https://github.com/octocat/x.git")
                let gate = TestWait.Gate(owner: self)
                defer { gate.open() }
                let entered = expectation(description: "noncancellable step")
                git.beforeCall = { call in
                    XCTAssertFalse(Thread.isMainThread)
                    if call == (disconnect ? "config-remote:\(self.root)" : "init:\(self.root)") {
                        entered.fulfill()
                        if !Thread.isMainThread { try? gate.wait() }
                    }
                }
                let paths = AppRuntimePaths(storeRoot: root, appSupportDir: root + "-support")
                let steps = paths.syncSteps
                let model = try makeModel(git: git, credentials: InMemoryCredentialStore(),
                    rebuilder: RecordingRebuilder(), fileService: existingUserFiles(), steps: steps)
                let runtime = try await makeSettingsRuntime(setup: model, paths: paths)
                if !disconnect {
                    runtime.syncModel.applyConfiguration(.success(.init(remoteURL: nil, hasLocalBranches: false)),
                        order: runtime.syncModel.beginConfiguration())
                }
                let host = setupHost(settingsRoot(runtime))
                defer { host.window.close() }
                let operation = Task {
                    if disconnect { try await model.performDisconnect() } else {
                        await model.connectAndReport(url: "https://github.com/octocat/x.git", username: "octocat", token: "new")
                    }
                }
                await fulfillment(of: [entered], timeout: TestWait.timeoutSeconds)
                XCTAssertEqual(steps.pendingCount, 1)
                if disconnect {
                    await assertDisconnectProgress(in: host.view)
                    operation.cancel()
                }
                host.window.close()
                let reopened = setupHost(settingsRoot(runtime))
                defer { reopened.window.close() }
                try await assertSettingsRebuilds(in: reopened.view, runtime: runtime, disconnect: disconnect)
                try await assertQuitWaitsForHeldStep(steps: runtime.paths.syncSteps, quitAnyway: quitAnyway,
                    gate: gate, operation: operation)
                await assertSettingsFinished(in: reopened.view, runtime: runtime, disconnect: disconnect)
            }
        }
    }

    func testCategoryCreatedDuringAdoptionSurvivesRebuildAndQueuedSave() async throws {
        let fixture = try makeBareFixture()
        try writeRealScaffold()
        let context = try makeContext()
        let files = FileService()
        let ready = root + "-fetch-ready", release = root + "-fetch-release"
        let executable = root + "-held-git"
        defer { for path in [ready, release, executable] { try? files.deleteFile(at: path) } }
        try files.writeExecutableFile(at: executable, content: """
        #!/bin/sh
        case " $* " in
          *" fetch "*)
            echo ready > '\(ready)'
            while [ ! -f '\(release)' ]; do /bin/sleep 0.01; done ;;
        esac
        exec /usr/bin/git "$@"
        """)
        let lockPath = root + "-real.lock"
        let saves = ManifestSaveModel(manifest: ManifestService(), root: root, lockPath: lockPath, waitSeconds: 0.01)
        let model = SyncSetupModel(context: context,
            git: GitService(askpassHelperPath: root + "-askpass", executablePath: executable),
            credentials: InMemoryCredentialStore(), root: root, lockPath: lockPath, steps: SyncStepModel())
        let operation = Task { try await performReal(model, remote: fixture.remote) }
        await TestWait.until(failureMessage: "Adoption fetch was never held") { files.fileExists(at: ready) }
        let categories = CategoryStore(manifestSaves: saves)
        let local = try XCTUnwrap(categories.create(name: "Created while connecting", context: context))
        XCTAssertEqual(local.name, "Created while connecting")
        await TestWait.until(failureMessage: "Category save did not wait behind Connect") { saves.isWaiting }
        XCTAssertTrue(try ManifestService().read(fromRoot: root).categories.isEmpty)
        try files.writeFile(at: release, content: "finish")
        try await operation.value
        await saves.waitUntilIdle()
        XCTAssertEqual(try ManifestService().read(fromRoot: root).categories.map(\.name), ["Created while connecting"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<PensieveCategory>()).map(\.name), ["Created while connecting"])
        XCTAssertEqual(try ModelContext(context.container).fetch(FetchDescriptor<PensieveCategory>()).map(\.name),
            ["Created while connecting"])
        XCTAssertEqual(try skillCount(context), 1, "The remote skill must also survive")
    }

    private func heldConnectGit(step: String, remote: String) -> RecordingGitService {
        let git = RecordingGitService()
        git.hasLocalBranchesFixture = .success(false)
        git.defaultBranchFixture = "trunk"
        git.branchesFixture = ["trunk"]
        git.remoteHasCommitsResult = true
        git.remoteURLFixture = remote
        git.hasRemoteTrackingBranchFixture = true
        git.pullResult = step == "abort" ? .conflicted(["skills/conflict/SKILL.md"]) : .merged
        return git
    }

    private func holdConnectStep(git: RecordingGitService, step: String, gate: TestWait.Gate,
                                 entered: XCTestExpectation, cancelled: XCTestExpectation?) {
        git.beforeCall = { call in
            XCTAssertFalse(Thread.isMainThread, call)
            guard call == step else { return }
            entered.fulfill()
            guard !Thread.isMainThread else { return }
            if let cancelled {
                // Keep the worker held across rendering and disappearance until cancellation reaches its task.
                let deadline = Date().addingTimeInterval(2 * TestWait.timeoutSeconds)
                while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if Task.isCancelled { cancelled.fulfill() }
            }
            try? gate.wait()
        }
    }

    private func assertCheckingSheetDisappears(
        model: SyncSetupModel, previous: (view: NSHostingView<AnyView>, window: NSWindow),
        gate: TestWait.Gate, cancelled: XCTestExpectation, step: String
    ) async {
        removeSetup(previous)
        await fulfillment(of: [cancelled], timeout: TestWait.timeoutSeconds)
        gate.open()
        await TestWait.until(failureMessage: "Disappeared check did not finish at \(step)") { model.state != .working }
        XCTAssertEqual(model.state, .cancelled, "Sheet disappearance must cancel \(step)")
        await assertFreshSetup(model: model)
    }

    private func writeHeldRemoteGit(at path: String, parentPath: String, helperPath: String,
                                    checkingPoint: String) throws {
        try FileService().writeExecutableFile(at: path, content: """
        #!/usr/bin/python3
        import os, sys, time
        args = sys.argv[1:]
        point = '\(checkingPoint)'
        held = (point == 'probe' and '--version' in args
            or point == 'read-remote' and 'get-url' in args
            or point == 'read-branches' and 'for-each-ref' in args
            or point == 'symref' and '--symref' in args
            or point == 'heads' and '--heads' in args
            or point == 'read-tracking' and '--verify' in args)
        if not held:
            if 'ls-remote' in args:
                if '--symref' in args: print('ref: refs/heads/trunk\\tHEAD')
                else: print('0' * 40 + '\\trefs/heads/trunk')
                sys.exit(0)
            os.execv('/usr/bin/git', ['/usr/bin/git'] + sys.argv[1:])
        child = os.fork()
        if child == 0:
            with open('\(helperPath)', 'w') as f: f.write(str(os.getpid()))
        else:
            with open('\(parentPath)', 'w') as f: f.write(str(os.getpid()))
        while True: time.sleep(1)
        """)
    }

    private func assertFreshSetup(
        model: SyncSetupModel,
        previous firstSheet: (view: NSHostingView<AnyView>, window: NSWindow)? = nil,
        context: String = "cancelled check"
    ) async {
        let previousMessage: String
        if case let .failed(message) = model.state { previousMessage = message } else {
            previousMessage = "Connect was cancelled."
        }
        if let firstSheet {
            await TestWait.until(failureMessage: "The first sheet must show its result: \(context)") {
                self.renderedTexts(in: firstSheet.view).contains(previousMessage)
            }
            firstSheet.window.close()
        }
        let reopened = setupHost(AnyView(SyncSetupView(model: model)))
        defer { reopened.window.close() }
        await assertSetupTitle(in: reopened.view)
        XCTAssertEqual(model.state, .idle, "Reopening after \(context) must start fresh")
        let texts = renderedTexts(in: reopened.view)
        XCTAssertFalse(texts.contains(previousMessage), "A new sheet retained the old \(context) message")
        XCTAssertFalse(texts.contains("Connect was cancelled."))
        XCTAssertFalse(RenderedViewTestSupport.hasButtonProgress(in: reopened.view))
    }

    private func assertSettingsFinished(in host: NSHostingView<AnyView>, runtime: AppRuntime,
                                        disconnect: Bool) async {
        XCTAssertEqual(runtime.paths.syncSteps.pendingCount, 0)
        XCTAssertFalse(runtime.syncSetup.isDisconnecting)
        if !disconnect { XCTAssertEqual(runtime.syncSetup.state, .done) }
        await TestWait.until(failureMessage: "Completed sync settings still show progress") {
            !RenderedViewTestSupport.hasButtonProgress(in: host)
        }
        await assertButtonAvailability(in: host, runtime: runtime, expected: true)
    }

    private func assertSettingsRebuilds(
        in host: NSHostingView<AnyView>, runtime: AppRuntime, disconnect: Bool
    ) async throws {
        try await assertOperationProgress(in: host, runtime: runtime, disconnect: disconnect)
        host.rootView = settingsRoot(runtime)
        await Task.yield()
        try await assertOperationProgress(in: host, runtime: runtime, disconnect: disconnect,
            context: "tab rebuild")
        runtime.syncModel.applyConfiguration(.success(.init(
            remoteURL: disconnect ? nil : "https://github.com/octocat/x.git", hasLocalBranches: !disconnect)),
            order: runtime.syncModel.beginConfiguration())
        try await assertOperationProgress(in: host, runtime: runtime, disconnect: disconnect,
            context: "configuration refresh")
    }

    private func assertQuitWaitsForHeldStep(
        steps: SyncStepModel, quitAnyway: Bool, gate: TestWait.Gate, operation: Task<Void, Error>
    ) async throws {
        var choices: [(Bool) -> Void] = []
        let quit = PendingSaveTermination(delay: 0.05, presentStep: { choices.append($0); return {} })
        var replies: [Bool] = []
        let answer = PensieveAppDelegate.terminationReply(hasUnsavedChanges: false, questionOpen: false,
            confirm: { _ in XCTFail("No draft") }, reply: { replies.append($0) },
            saveTermination: quit, steps: steps)
        XCTAssertEqual(answer, .terminateLater)
        await TestWait.until(failureMessage: "Quit never asked about the held sync step") { !choices.isEmpty }
        XCTAssertTrue(replies.isEmpty)
        let choose = try XCTUnwrap(choices.first)
        choose(quitAnyway)
        XCTAssertEqual(replies, quitAnyway ? [true] : [])
        gate.open()
        try await operation.value
        await TestWait.until(failureMessage: "Quit did not finish after the sync step") { replies == [true] }
    }

    private func reopenHeldSetup(
        model: SyncSetupModel,
        previous: (view: NSHostingView<AnyView>, window: NSWindow),
        step: String
    ) async -> (view: NSHostingView<AnyView>, window: NSWindow) {
        removeSetup(previous)
        let reopened = setupHost(AnyView(SyncSetupView(model: model)))
        await assertSetupTitle(in: reopened.view)
        await TestWait.until(failureMessage: "Reopened Connect lost progress at \(step)") {
            RenderedViewTestSupport.hasButtonProgress(in: reopened.view)
        }
        XCTAssertFalse(pressCancel(in: reopened.view), "The writing phase must disable Cancel's native shortcut")
        model.cancel()
        return reopened
    }

    private func removeSetup(_ host: (view: NSHostingView<AnyView>, window: NSWindow)) {
        // Destroy the presentation graph, as closing Settings or rebuilding its pane does.
        host.view.rootView = AnyView(EmptyView())
        host.view.layoutSubtreeIfNeeded()
        host.window.close()
    }

    private func assertDisconnectProgress(in host: NSHostingView<AnyView>) async {
        await TestWait.until(failureMessage: "Disconnect button did not render its spinner") {
            RenderedViewTestSupport.hasButtonProgress(in: host)
        }
    }

    private func renderedTexts(in host: NSHostingView<AnyView>) -> [String] {
        RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap(RenderedViewTestSupport.strings)
    }

    private func assertSetupTitle(in host: NSHostingView<AnyView>) async {
        await TestWait.until(failureMessage: "The Connect sheet did not render") {
            self.renderedTexts(in: host).contains("Connect a sync remote")
        }
    }

    private func assertOperationProgress(
        in host: NSHostingView<AnyView>, runtime: AppRuntime,
        disconnect: Bool, context: String = "window reopen"
    ) async throws {
        let title = disconnect ? "Disconnect…" : "Connect…"
        await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                             failureMessage: "Settings lost \(title) progress after \(context)") {
            RenderedViewTestSupport.hasButtonProgress(in: host)
        }
        guard RenderedViewTestSupport.hasButtonProgress(in: host) else { throw StubBoom() }
        XCTAssertTrue(renderedTexts(in: host).contains(title))
        await assertButtonAvailability(in: host, runtime: runtime, expected: false)
    }

    private func assertButtonAvailability(in host: NSHostingView<AnyView>, runtime: AppRuntime, expected: Bool) async {
        var enabled: Bool?
        host.rootView = AnyView(SyncSettingsView().environment(runtime)
            .buttonStyle(RenderedViewTestSupport.AvailabilityStyle { enabled = $0 }))
        await TestWait.until(failureMessage: "The rendered Sync settings button did not report availability \(expected)") {
            enabled != nil
        }
        XCTAssertEqual(enabled, expected, "Sync settings must disable the button until its job finishes")
        host.rootView = settingsRoot(runtime)
    }

    private func settingsRoot(_ runtime: AppRuntime) -> AnyView {
        AnyView(SyncSettingsView().id(UUID()).environment(runtime))
    }

    private func makeSettingsRuntime(setup: SyncSetupModel, paths: AppRuntimePaths) async throws -> AppRuntime {
        let runtime = try AppRuntime(syncSetup: setup,
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(),
            paths: paths)
        await runtime.bootstrapTask.value
        runtime.syncModel.applyConfiguration(.success(.init(remoteURL: "https://github.com/octocat/x.git",
            hasLocalBranches: true)), order: runtime.syncModel.beginConfiguration())
        return runtime
    }

    private func setupHost(_ root: AnyView) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Native window transitions can retain closed test hosts and occupy dispatch workers.
        window.animationBehavior = .none
        hostedWindows.append(HostedWindow(window))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (host, window)
    }

    private func pressCancel(in root: NSView) -> Bool {
        guard let window = root.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return false }
        root.layoutSubtreeIfNeeded()
        return root.performKeyEquivalent(with: event) || window.performKeyEquivalent(with: event)
    }

}

extension SyncSetupModelTests {
    func testCancelRemoteReadJoinsRealGitGroupWithoutChangingStoreOrCredential() async throws {
        for point in ["escape", "probe", "read-remote", "read-branches", "symref", "heads", "read-tracking"] {
            try await assertReadCancellation(checkingPoint: point)
        }
    }

    private func assertReadCancellation(checkingPoint: String) async throws {
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        try writeRealScaffold()
        try TestPaths.git.initRepository(at: root)
        if checkingPoint == "read-tracking" {
            try files.writeFile(at: root + "/partial.txt", content: "interrupted adoption")
            try TestPaths.git.setRemote("https://github.com/octocat/x.git", at: root)
        }
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "original", username: "old", forHost: "github.com")
        let config = try files.readData(at: root + "/.git/config")
        let manifest = try ManifestSaveFixture.manifestBytes(root: root, files: files)
        let executable = root + "-cancel-git", parentPath = root + "-parent", helperPath = root + "-helper"
        defer {
            for path in [executable, parentPath, helperPath, root + "-askpass"] where files.fileExists(at: path) {
                try? files.deleteFile(at: path)
            }
        }
        try writeHeldRemoteGit(at: executable, parentPath: parentPath, helperPath: helperPath,
            checkingPoint: checkingPoint == "escape" ? "symref" : checkingPoint)
        let model = SyncSetupModel(context: try makeContext(),
            git: GitService(askpassHelperPath: root + "-askpass", executablePath: executable),
            credentials: credentials, root: root, lockPath: root + "-sync.lock", steps: SyncStepModel())
        model.connect(url: "https://github.com/octocat/x.git", username: "new", token: "replacement")
        await TestWait.until(failureMessage: "Remote check never started its helper") {
            (try? files.readFile(at: parentPath)).flatMap(Int32.init) != nil
                && (try? files.readFile(at: helperPath)).flatMap(Int32.init) != nil
        }
        let parent = try XCTUnwrap(Int32(try files.readFile(at: parentPath)))
        let helper = try XCTUnwrap(Int32(try files.readFile(at: helperPath)))
        defer { kill(-parent, SIGKILL); kill(helper, SIGKILL) }
        XCTAssertEqual(getpgid(helper), parent)
        let host = setupHost(AnyView(SyncSetupView(model: model)))
        defer { host.window.close() }
        try await cancelHeldRead(model: model, host: host, checkingPoint: checkingPoint)
        await TestWait.until(failureMessage: "Git's helper survived Cancel") { kill(helper, 0) == -1 }
        XCTAssertEqual(kill(parent, 0), -1)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(parent, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        XCTAssertEqual(try files.readData(at: root + "/.git/config"), config)
        XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: root, files: files), manifest)
        XCTAssertFalse(files.directoryExists(at: root + "/skills"))
        if checkingPoint == "read-tracking" {
            XCTAssertEqual(try files.readFile(at: root + "/partial.txt"), "interrupted adoption")
        }
        XCTAssertEqual(credentials.credential(forHost: "github.com"), .httpsToken(username: "old", token: "original"))
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: root + "-sync.lock"), "Cancel must release the whole-cycle lock")
        lock.release()
        if checkingPoint != "escape" { await assertFreshSetup(model: model) }
    }

    private func cancelHeldRead(
        model: SyncSetupModel, host: (view: NSHostingView<AnyView>, window: NSWindow), checkingPoint: String
    ) async throws {
        await TestWait.until(failureMessage: "Remote check did not render its progress") {
            RenderedViewTestSupport.hasButtonProgress(in: host.view)
        }
        if checkingPoint == "escape" {
            XCTAssertTrue(pressCancel(in: host.view), "The rendered Cancel shortcut must be enabled while checking")
        } else { removeSetup(host) }
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
            failureMessage: "Sheet disappearance/Cancel never joined git at \(checkingPoint)") { model.state == .cancelled }
        guard model.state == .cancelled else {
            model.cancel()
            await TestWait.until(failureMessage: "Failed-case cleanup did not cancel git") { model.state == .cancelled }
            throw StubBoom()
        }
    }
}
