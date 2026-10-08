import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class GitReviewRegressionTests: XCTestCase {
    func testAbsentGitEntryIsKnownAbsentBeforeAnyGitCall() async throws {
        for (index, state) in [GitUsability.licenseNotAccepted, .developerToolsMissing].enumerated() {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            let git = try fixture.broken(state)
            XCTAssertNil(try git.remoteURL(at: fixture.root))
            XCTAssertFalse(fixture.paths.hasRemoteConfigured(git: git))
            let model = SyncModel(git: git, root: fixture.root)
            let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration-\(index)"))
            defer { try? modelConfiguration.remove() }
            await modelConfiguration.refresh()
            XCTAssertEqual(model.state, .unconfigured)
            XCTAssertFalse(model.isConfigured)
            XCTAssertFalse(fixture.files.fileExists(at: fixture.trace), "known absence must not run the broken shim")
        }
    }

    func testLocalOnlyLaunchBackfillsAndConvergesWithUnusableGit() async throws {
        for (index, state) in [GitUsability.licenseNotAccepted, .developerToolsMissing].enumerated() {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            let git = try fixture.broken(state)
            let convergence = ReviewConvergence()
            var backfills = 0
            let runtime = try AppRuntime(
                scheduler: SyncScheduler(backgroundSyncEnabled: { false }),
                defaults: isolatedDefaults("launch-\(index)"),
                launchReconcile: { _, _ in LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false) },
                launchBackfill: { _ in backfills += 1 },
                hasRemoteConfigured: { fixture.paths.hasRemoteConfigured(git: git) },
                postSyncConvergence: convergence, paths: fixture.paths, gitUsabilityProbe: git.probeUsability
            )
            await runtime.bootstrapTask.value
            XCTAssertTrue(runtime.performLaunchWorkIfNeeded(context: runtime.container.mainContext))
            runtime.library.stopWatching()
            XCTAssertEqual(runtime.gitUsability, state)
            XCTAssertEqual(backfills, 1, "local backfill must not wait for a sync that has no remote")
            XCTAssertEqual(convergence.launches, 1)
        }
    }

    func testNeverInstalledDeveloperToolsReportsInstallFix() throws {
        let messages = [
            "xcode-select: note: No developer tools were found, requesting install.",
            "xcode-select: note: no developer tools were found at '/Applications/Xcode.app', requesting install."
        ]
        for message in messages {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            let git = try fixture.executable("""
                cat >&2 <<'MESSAGE'
                \(message)
                Use sudo xcode-select --switch to specify the developer directory.
                See man xcode-select for more details.
                MESSAGE
                exit 1
                """)
            XCTAssertEqual(try git.probeUsability(), .developerToolsMissing)
            XCTAssertTrue(try git.probeUsability().message?.contains("xcode-select --install") == true)
        }
    }

    func testMissingRootIsUnknown() async throws {
        for dangling in [false, true] {
            for (index, state) in [GitUsability.usable, .licenseNotAccepted, .developerToolsMissing].enumerated() {
                try await assertUnavailableRoot(dangling: dangling, state: state, label: "missing-\(dangling)-\(index)")
            }
        }
    }

    private func assertUnavailableRoot(dangling: Bool, state: GitUsability, label: String) async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = try fixture.broken(state)
        var backfills = 0
        let convergence = ReviewConvergence()
        let model = SyncModel(git: git, root: fixture.root)
        let runtime = try AppRuntime(
            syncModel: model, scheduler: SyncScheduler(backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(label),
            launchReconcile: { _, _ in LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false) },
            launchBackfill: { _ in backfills += 1 },
            hasRemoteConfigured: { fixture.paths.hasRemoteConfigured(git: git) },
            postSyncConvergence: convergence, paths: fixture.paths,
            gitUsabilityProbe: git.probeUsability
        )
        await runtime.bootstrapTask.value
        try fixture.files.deleteDirectory(at: fixture.root)
        if dangling { try fixture.files.createSymlink(at: fixture.root, pointingTo: fixture.base + "/unmounted") }
        XCTAssertThrowsError(try git.remoteURL(at: fixture.root)) { error in
            if state == .usable {
                guard case GitError.repositoryUnreadable = error else { return XCTFail("\(error)") }
            } else {
                guard case let GitError.unusable(actual) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(actual, state)
            }
        }
        XCTAssertTrue(fixture.paths.hasRemoteConfigured(git: git))
        let callsBeforeRead = try fixture.files.readFile(at: fixture.trace)
        model.applyConfiguration(model.configurationRead()(), order: model.beginConfiguration())
        XCTAssertNotEqual(try fixture.files.readFile(at: fixture.trace), callsBeforeRead,
                          "the configuration refresh must actually read the missing root")
        XCTAssertNotNil(model.configurationError)
        XCTAssertNotEqual(model.state, .unconfigured)
        XCTAssertTrue(runtime.performLaunchWorkIfNeeded(context: runtime.container.mainContext))
        runtime.library.stopWatching()
        XCTAssertEqual(runtime.gitUsability, state, "launch assertions retain the unusable host")
        XCTAssertEqual(backfills, 0)
        XCTAssertEqual(convergence.launches, 0)
        let daemon = SyncDaemon(root: fixture.root, appSupport: fixture.support, git: git,
                                hasLocalBranches: git.hasLocalBranches,
                                credentials: InMemoryCredentialStore(), reconciler: ReviewReconciler(), now: Date.init)
        XCTAssertEqual(daemon.runOnce().category, "failed")
    }

    func testRootDirectoryRequirementMaintainsLinksAndRejectsFiles() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let target = fixture.base + "/target"
        try fixture.files.deleteDirectory(at: fixture.root)
        try fixture.files.createDirectory(at: target)
        try fixture.files.createSymlink(at: fixture.root, pointingTo: target)
        let git = try fixture.broken(.licenseNotAccepted)
        XCTAssertNil(try git.remoteURL(at: fixture.root))
        XCTAssertFalse(fixture.files.fileExists(at: fixture.trace))
        try fixture.files.deleteDirectory(at: target)
        try fixture.files.writeFile(at: target, content: "not a directory")
        XCTAssertThrowsError(try GitService().remoteURL(at: fixture.root)) { error in
            guard case GitError.repositoryUnreadable = error else { return XCTFail("\(error)") }
        }
        try fixture.files.deleteFile(at: fixture.root)
        try fixture.files.writeFile(at: fixture.root, content: "not a directory")
        XCTAssertThrowsError(try GitService().remoteURL(at: fixture.root)) { error in
            guard case GitError.repositoryUnreadable = error else { return XCTFail("\(error)") }
        }
    }

    func testCaseVariantGitEntryAgreesWithFileSystem() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        try FileManager.default.moveItem(atPath: fixture.root + "/.git", toPath: fixture.root + "/metadata")
        try FileManager.default.moveItem(atPath: fixture.root + "/metadata", toPath: fixture.root + "/.GIT")
        XCTAssertTrue(try fixture.files.listDirectory(at: fixture.root).contains(".GIT"))
        let expected = fixture.files.directoryExists(at: fixture.root + "/.git") ? "https://fixture.test/store.git" : nil
        XCTAssertEqual(try GitService().remoteURL(at: fixture.root), expected)
    }

    func testDeniedRootLookupRemainsUnknown() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.root)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root) }
        XCTAssertThrowsError(try GitService().remoteURL(at: fixture.root)) { error in
            guard case let GitError.repositoryUnreadable(path, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, fixture.root)
        }
        XCTAssertTrue(fixture.paths.hasRemoteConfigured())
    }

    func testMultilinePreflightFailureWritesOneStatusAndLogLine() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let git = try fixture.broken(.failed(GitFailureDetail("first line\nsecond line\r\nthird line\u{2028}last line")))
        let daemon = SyncDaemon(root: fixture.root, appSupport: fixture.support, git: git,
                                hasLocalBranches: git.hasLocalBranches,
                                credentials: InMemoryCredentialStore(), reconciler: ReviewReconciler(), now: Date.init)
        let output = DaemonCLI.execute(["run"], appSupport: fixture.support,
                                       readFile: { try? fixture.files.readData(at: $0) },
                                       runCycle: { daemon.runOnce() }, now: Date.init)
        XCTAssertEqual(output.exitCode, 1)
        let status = try JSONDecoder().decode(
            DaemonStatus.self, from: fixture.files.readData(at: fixture.support + "/daemon-status.json")
        )
        let expected = "Git isn't working on this Mac. first line second line third line last line"
        XCTAssertEqual(status.detail, expected)
        XCTAssertEqual(output.stdout, "pensieve-daemon failed \(expected)\n")
        let log = try fixture.files.readFile(at: fixture.support + "/daemon.log")
        XCTAssertEqual(log, "\(status.timestamp) failed \(expected)\n")
        XCTAssertEqual(log.components(separatedBy: .newlines).filter { !$0.isEmpty }.count, 1)
    }

    func testAuthFailuresSurviveUnknownRemoteLabels() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let git = try fixture.executable("""
            if [ "$1" = '--version' ]; then echo 'git version fixture'; exit 0; fi
            case "$3" in
              fetch|pull|push) echo 'Authentication failed' >&2; exit 128 ;;
              remote) echo 'repository config unreadable' >&2; exit 128 ;;
            esac
            exec /usr/bin/git "$@"
            """)
        let operations: [() throws -> Void] = [
            { try git.fetch(at: fixture.root, credential: nil) },
            { _ = try git.pullRebase(at: fixture.root, credential: nil) },
            { try git.push(at: fixture.root, credential: nil) },
            { _ = try git.collapseToSingleCommit(at: fixture.root, message: "test", credential: nil) }
        ]
        for operation in operations {
            XCTAssertThrowsError(try operation()) { error in
                guard case let GitError.authenticationFailed(remote, detail) = error else {
                    return XCTFail("auth classification was replaced by \(error)")
                }
                XCTAssertEqual(remote, "origin")
                XCTAssertTrue(detail.contains("Authentication failed"))
            }
        }
    }
}

@MainActor
private final class ReviewConvergence: PostSyncConverging {
    var launches = 0
    func run(after result: SyncCycleResult) {}
    func runAfterLaunchIngest() { launches += 1 }
}

private struct ReviewReconciler: DeployReconciling {
    func reconcile(root: String) throws -> ReconcileOutcome {
        XCTFail("failed preflight must not reconcile")
        return ReconcileOutcome()
    }
}
