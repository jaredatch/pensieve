import Observation
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeFinalReviewTests: XCTestCase {
    private struct LocalFailure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    func testBranchlessCycleCannotAdvertiseAnAbsentRemote() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try GitService().initRepository(at: fixture.root)
        try GitService().setRemote("https://fixture.test/store.git", at: fixture.root)
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        let model = runtime.syncModel
        for _ in 0..<2 {
            model.apply(.noRemote)
            XCTAssertEqual(model.remoteURL, "https://fixture.test/store.git")
            XCTAssertFalse(model.canConnect, "a branchless cycle has no answer about origin")
            XCTAssertNotEqual(model.configurationDescription, "Not connected")
            XCTAssertNotEqual(model.state, .unconfigured)
            await runtime.refreshGitConfiguration(probingGit: false)
        }
        try GitService().removeRemote(at: fixture.root)
        model.apply(.noRemote)
        XCTAssertFalse(model.canConnect, "only the completed read can establish absence")
        await runtime.refreshGitConfiguration(probingGit: false)
        XCTAssertTrue(model.canConnect)
        XCTAssertNil(model.remoteURL)
    }

    func testLocalAutomaticFailureWaitsForIntervalAndManualStillRuns() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let calls = RuleProbe()
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            updateCheckOperation: { _ in _ = calls.run(); throw LocalFailure(text: "scratch unavailable") },
            now: { date }, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(runtime.lastUpdateCheckStartedAt, date)
        XCTAssertEqual(runtime.updateCheckAlertError, "scratch unavailable")
        runtime.clearUpdateCheckAlert()
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(runtime.updateCheckAlertError)
        date = date.addingTimeInterval(8 * 24 * 60 * 60)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2, "a local failure is counted, not deferred for the session")
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(runtime.updateCheckAlertError, "scratch unavailable")
    }

    func testConfigurationReadRunsOffMainActor() async throws {
        let git = IngestRecordingGit()
        git.remoteRead = {
            XCTAssertFalse(Thread.isMainThread, "configuration reads must not run git on the UI thread")
            return "https://fixture.test/store.git"
        }
        let model = SyncModel(git: git, root: "/unused-test-root")
        let modelConfiguration = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? modelConfiguration.remove() }
        await modelConfiguration.refresh()
        XCTAssertEqual(model.remoteURL, "https://fixture.test/store.git")
    }

    func testSuccessfulCycleKeepsNewerPendingConfigurationAnswer() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = IngestRecordingGit()
        git.remoteRead = { throw LocalFailure(text: "old read failed") }
        let model = SyncModel(git: git, root: fixture.root)
        let runtime = try AppRuntime(syncModel: model,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(), paths: fixture.paths, gitUsabilityProbe: { .usable })
        await runtime.bootstrapTask.value
        let started = expectation(description: "new read started")
        let release = DispatchSemaphore(value: 0)
        git.remoteRead = {
            started.fulfill()
            release.wait()
            return "https://fixture.test/new.git"
        }
        let read = Task { await runtime.refreshGitConfiguration(probingGit: false) }
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        model.apply(.synced(pushed: false, warnings: [], completedAt: Date()))
        release.signal()
        await read.value
        XCTAssertEqual(model.remoteURL, "https://fixture.test/new.git")
        XCTAssertNil(model.configurationError)
        XCTAssertFalse(model.canConnect)
    }

    func testUsabilityFailureIsSafeInConfigurationAndStatus() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let raw = "failed\n\u{1B}]8;;hidden\u{7}repo\u{202E}"
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            gitUsabilityProbe: { .failed(GitFailureDetail(raw)) }
        )
        await runtime.bootstrapTask.value
        let expected = DisplayTextSanitizer.singleLine(try XCTUnwrap(GitUsability.failed(GitFailureDetail(raw)).message))
        XCTAssertEqual(runtime.syncModel.configurationError, expected)
        XCTAssertEqual(runtime.syncModel.configurationDescription, expected)
        XCTAssertEqual(runtime.syncModel.state, .error(expected))
    }

    func testSingleUpdateFailureIsSafeInStatusAndAlert() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            updateCheckOperation: { _ in throw LocalFailure(text: "save\n\u{1B}]8;;hidden\u{7}failed\u{202E}") },
            gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(runtime.updateCheckError, "save failed")
        XCTAssertEqual(runtime.updateCheckAlertError, "save failed")
    }

    func testSlowConfigurationReadCannotReleaseNewerEnvironmentDeferral() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let probe = RuleProbe()
        probe.set { .licenseNotAccepted }
        let git = IngestRecordingGit()
        let calls = RuleProbe()
        let runtime = try AppRuntime(syncModel: SyncModel(git: git, root: fixture.root),
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(), paths: fixture.paths, updateCheckOperation: { _ in
                _ = calls.run()
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(
                    environmentError: GitError.unusable(.licenseNotAccepted), gitUsability: .licenseNotAccepted
                ), skills: [:])
            }, gitUsabilityProbe: probe.run)
        await runtime.bootstrapTask.value
        let started = expectation(description: "older usable probe waits for configuration")
        let release = DispatchSemaphore(value: 0)
        git.remoteRead = {
            started.fulfill()
            release.wait()
            return "https://fixture.test/store.git"
        }
        probe.set { .usable }
        let old = Task { await runtime.refreshGitUsability() }
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        probe.set { .licenseNotAccepted }
        await runtime.refreshGitUsability()
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1)
        release.signal()
        await old.value
        await finished(runtime)
        XCTAssertEqual(runtime.gitUsability, .licenseNotAccepted)
        XCTAssertEqual(calls.count, 1, "an older refresh must not release a newer failure's retry deferral")
    }

    func testUsableProbeCannotReleaseOfflineAutomaticDeferral() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(), paths: fixture.paths, updateCheckOperation: { _ in
                _ = calls.run()
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(
                    environmentError: SkillInstallError.networkUnavailable, gitUsability: .usable
                ), skills: [:])
            }, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        XCTAssertEqual(runtime.gitUsability, .usable)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1)
        XCTAssertNotNil(runtime.updateCheckAlertError)
        runtime.clearUpdateCheckAlert()
        await runtime.refreshGitUsability()
        await finished(runtime)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1, "usable after usable is not recovery from the offline failure")
        XCTAssertNil(runtime.updateCheckAlertError, "an ordinary usable probe must not repeat the automatic alert")
        XCTAssertNil(runtime.lastUpdateCheckStartedAt)
    }

    func testManualOfflineFailureDefersFollowingActivations() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: isolatedDefaults(), paths: fixture.paths, updateCheckOperation: { _ in
                _ = calls.run()
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(
                    environmentError: SkillInstallError.networkUnavailable, gitUsability: .usable
                ), skills: [:])
            }, gitUsabilityProbe: { .usable })
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1)
        XCTAssertNotNil(runtime.updateCheckAlertError)
        runtime.clearUpdateCheckAlert()
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1, "the latest manual environment failure also defers automatic checks")
        XCTAssertNil(runtime.updateCheckAlertError)
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2, "manual checks always run")
    }

    func testCycleFailureMessagesAreSafeForStatus() {
        let text = "failed\n\u{1B}]8;;hidden\u{7}repo\u{202E}"
        let model = SyncModel(git: IngestRecordingGit(), root: "/unused-test-root")
        for result in [SyncCycleResult.failed(text), .storeUnreadable(text)] {
            model.apply(result)
            XCTAssertEqual(model.state, .error("failed repo"))
        }
    }

    func testUsabilityFailureDetailIsSanitizedWhenCreated() throws {
        let raw = "failed\n\u{1B}]8;;hidden\u{7}repo\u{202E}"
        let value = GitUsability.failed(GitFailureDetail(raw))
        guard case let .failed(detail) = value else { return XCTFail("expected failed detail") }
        XCTAssertEqual(detail.text, "failed repo")
        XCTAssertEqual(value.message, "Git isn't working on this Mac. failed repo")
    }

}

extension AppRuntimeFinalReviewTests {
    func testWindowRefreshCallSitesUseConfigurationOnly() async throws {
        let git = IngestRecordingGit()
        git.remoteRead = { "https://fixture.test/old.git" }
        let fixture = try RuntimeConfigurationFixture(SyncModel(git: git, root: "/unused-test-root"),
            defaults: isolatedDefaults("configuration"))
        defer { try? fixture.remove() }
        await fixture.runtime.bootstrapTask.value
        let probes = fixture.probe.count
        for (index, refresh) in [fixture.runtime.mainWindowAppeared,
                                 fixture.runtime.conflictResolutionDismissed].enumerated() {
            let expected = "https://fixture.test/changed-\(index).git"
            git.remoteRead = {
                XCTAssertFalse(Thread.isMainThread)
                return expected
            }
            await refresh()
            XCTAssertEqual(fixture.runtime.syncModel.remoteURL, expected)
            XCTAssertEqual(fixture.probe.count, probes, "window callbacks must not probe git")
        }
    }

    func testConfigurationOnlyRefreshReadsChangedRemoteWithoutProbe() async throws {
        let git = IngestRecordingGit()
        git.remoteRead = { "https://fixture.test/old.git" }
        let model = SyncModel(git: git, root: "/unused-test-root")
        let fixture = try RuntimeConfigurationFixture(model, defaults: isolatedDefaults("configuration"))
        defer { try? fixture.remove() }
        await fixture.runtime.bootstrapTask.value
        XCTAssertEqual(model.remoteURL, "https://fixture.test/old.git")
        let probes = fixture.probe.count
        git.remoteRead = { "https://fixture.test/new.git" }
        await fixture.refresh()
        XCTAssertEqual(model.remoteURL, "https://fixture.test/new.git")
        XCTAssertEqual(fixture.probe.count, probes)
    }

    func testConfigurationFixtureDoesNotClearAnotherRuntimesDefaults() async throws {
        let first = try RuntimeConfigurationFixture(SyncModel(git: IngestRecordingGit(), root: "/unused-first"),
            defaults: isolatedDefaults("first"))
        defer { try? first.remove() }
        await first.runtime.bootstrapTask.value
        first.defaults.set(UpdateCheckFrequency.daily.rawValue, forKey: UpdateCheckSchedule.frequencyKey)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        first.defaults.set(date.timeIntervalSince1970, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        XCTAssertEqual(first.runtime.lastUpdateCheckStartedAt, date)
        let second = try RuntimeConfigurationFixture(SyncModel(git: IngestRecordingGit(), root: "/unused-second"),
            defaults: isolatedDefaults("second"))
        defer { try? second.remove() }
        await second.runtime.bootstrapTask.value
        XCTAssertEqual(first.defaults.string(forKey: UpdateCheckSchedule.frequencyKey), UpdateCheckFrequency.daily.rawValue)
        XCTAssertEqual(first.runtime.lastUpdateCheckStartedAt, date, "another fixture must not reset a live runtime")
        XCTAssertNil(second.runtime.lastUpdateCheckStartedAt)
        XCTAssertNil(second.defaults.string(forKey: UpdateCheckSchedule.frequencyKey))
    }

    func testDirectUsabilityFailureIsSafeInConfigurationAndStatus() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            gitUsabilityProbe: { .failed(GitFailureDetail("failed\n\u{1B}]8;;hidden\u{7}repo\u{202E}")) }
        )
        await runtime.bootstrapTask.value
        let expected = "Git isn't working on this Mac. failed repo"
        XCTAssertEqual(runtime.syncModel.configurationError, expected)
        XCTAssertEqual(runtime.syncModel.configurationDescription, expected)
        XCTAssertEqual(runtime.syncModel.state, .error(expected))
    }

    func testGenericForgedHintUsesUsableProbeAndRemainsOrdinaryFailure() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let probe = RuleProbe()
        probe.set { .licenseNotAccepted }
        let git = try fixture.executable("""
            if [ "$1" = '--version' ]; then echo 'git version fixture'; exit 0; fi
            printf '%s' 'checkout failed for xcrun: error: invalid active developer path' >&2
            exit 128
            """)
        let failure = GitError.commandFailed(args: ["clone"], exitCode: 128,
            stderr: "checkout failed for xcrun: error: invalid active developer path")
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            updateCheckOperation: { _ in
                try git.runOrThrow(["clone"], in: nil)
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(), skills: [:])
            }, gitUsabilityProbe: probe.run
        )
        await runtime.bootstrapTask.value
        let before = probe.count
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(probe.count, before, "the runner already confirmed the command hint")
        XCTAssertEqual(runtime.gitUsability, .usable)
        XCTAssertEqual(runtime.updateCheckError, failure.localizedDescription)
        XCTAssertEqual(runtime.updateCheckAlertError, failure.localizedDescription)
        XCTAssertNotNil(runtime.lastUpdateCheckStartedAt)
    }

    func testManualCheckDuringRunningCheckIsDroppedAndFailureStillDefers() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let started = expectation(description: "automatic operation started")
        let release = DispatchSemaphore(value: 0)
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            updateCheckOperation: { _ in
                _ = calls.run()
                if calls.count == 1 {
                    started.fulfill()
                    release.wait()
                }
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(
                    environmentError: SkillInstallError.networkUnavailable
                ), skills: [:])
            }, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        runtime.checkForSkillUpdatesNow()
        XCTAssertTrue(runtime.updateCheckInFlight)
        XCTAssertEqual(calls.count, 1)
        var requestedDuringFailure = false
        withObservationTracking { _ = runtime.updateCheckError } onChange: {
            MainActor.assumeIsolated {
                requestedDuringFailure = true
                runtime.checkForSkillUpdatesNow()
            }
        }
        release.signal()
        await finished(runtime)
        XCTAssertTrue(requestedDuringFailure, "request while deferral is set and the failure is being published")
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1, "a dropped manual request does not authorize another automatic attempt")
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2)
    }

    private func finished(_ runtime: AppRuntime) async {
        await TestWait.until(failureMessage: "update check did not finish") { !runtime.updateCheckInFlight }
    }
}
