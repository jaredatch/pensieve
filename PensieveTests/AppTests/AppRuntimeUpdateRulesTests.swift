import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeUpdateRulesTests: XCTestCase {
    private struct SaveFailure: LocalizedError {
        var errorDescription: String? { "Could not save answered skill results." }
    }

    func testLocalFailureDoesNotDeferAutomaticChecks() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let defaults = try isolatedDefaults()
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: defaults, paths: fixture.paths,
            updateCheckOperation: { _ in _ = calls.run(); throw SaveFailure() }, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        for _ in 0..<2 {
            runtime.checkForSkillUpdatesIfDue()
            await finished(runtime)
        }
        XCTAssertEqual(calls.count, 1, "local failures wait for the normal interval")
        XCTAssertNotNil(runtime.lastUpdateCheckStartedAt)
        defaults.set(0, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2, "the next due run is not deferred")
    }

    func testManualCheckClearsDeferralEvenIfItFailsLocally() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let calls = RuleProbe()
        let defaults = try isolatedDefaults()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: defaults, paths: fixture.paths,
            updateCheckOperation: { _ in
                _ = calls.run()
                if calls.count > 1 { throw SaveFailure() }
                return RuntimeUpdateCheckResult(
                    report: UpdateCheckReport(environmentError: SkillInstallError.networkUnavailable), skills: [:]
                )
            }, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2, "the manual local failure counts toward the interval")
        defaults.set(0, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 3, "manual check must clear the earlier deferral, independently of the interval")
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertEqual(calls.count, 4)
    }

    func testMixedEnvironmentFailureDoesNotDeferNextDueRun() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let defaults = try isolatedDefaults()
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: defaults, paths: fixture.paths,
            updateCheckOperation: { _ in
                _ = calls.run()
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(
                    reachedRemote: true, environmentError: SkillInstallError.networkUnavailable, gitUsability: .usable
                ), skills: [:])
            }, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        defaults.set(0, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2)
    }

    func testApplyFailureReportsBothErrorsAndDoesNotCountOrDefer() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let defaults = try isolatedDefaults()
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: defaults, paths: fixture.paths,
            updateCheckOperation: { _ in
                _ = calls.run()
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(
                    reachedRemote: true, environmentError: SkillInstallError.networkUnavailable, gitUsability: .usable
                ), skills: [:])
            }, updateCheckApply: { _ in throw SaveFailure() }, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertTrue(runtime.updateCheckError?.contains(SaveFailure().localizedDescription) == true)
        XCTAssertTrue(runtime.updateCheckError?.contains(SkillInstallError.networkUnavailable.localizedDescription) == true)
        XCTAssertNotNil(runtime.lastUpdateCheckStartedAt)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1, "the failed run counts despite the local error")
        defaults.set(0, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2, "the next due run is not deferred")
    }

    func testLocalFailureAfterGitKeepsEvidenceAndDoesNotCountOrDefer() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let defaults = try isolatedDefaults()
        let calls = RuleProbe()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: defaults, paths: fixture.paths,
            updateCheckOperation: { _ in
                _ = calls.run()
                return try UpdateCheckExecutionFailure.preservingReport(UpdateCheckReport(
                    reachedRemote: true, environmentError: SkillInstallError.networkUnavailable, gitUsability: .usable
                )) { throw SaveFailure() }
            }, gitUsabilityProbe: { .licenseNotAccepted }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(runtime.gitUsability, .usable)
        XCTAssertNil(runtime.syncModel.configurationError)
        XCTAssertNotNil(runtime.syncModel.remoteURL)
        XCTAssertTrue(runtime.updateCheckError?.contains(SaveFailure().localizedDescription) == true)
        XCTAssertTrue(runtime.updateCheckError?.contains(SkillInstallError.networkUnavailable.localizedDescription) == true)
        XCTAssertNotNil(runtime.lastUpdateCheckStartedAt)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 1, "the failed run counts despite the local error")
        defaults.set(0, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2, "the next due run is not deferred")
    }

    func testUpdateCompletionDoesNotSaveUnrelatedMainContextChanges() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            updateCheckOperation: { _ in RuntimeUpdateCheckResult(report: UpdateCheckReport(), skills: [:]) },
            gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        let context = runtime.container.mainContext
        context.autosaveEnabled = false
        let unrelated = Skill(name: "Unsaved draft", directoryName: "unsaved-draft")
        context.insert(unrelated)
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertNotNil(runtime.lastUpdateCheckStartedAt)
        XCTAssertNil(runtime.updateCheckError)
        XCTAssertTrue(context.hasChanges, "an update check must not save unrelated editing state")
        let saved = try ModelContext(runtime.container).fetch(FetchDescriptor<Skill>())
        XCTAssertFalse(saved.contains { $0.id == unrelated.id })
        runtime.checkForSkillUpdatesIfDue()
        XCTAssertFalse(runtime.updateCheckInFlight)
    }

    func testGenericOperationFailureUsesClassifiedAlert() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let failures: [(GitError, String)] = [
            (.commandFailed(args: ["ls-remote"], exitCode: 128, stderr: "Could not resolve host: github.com"),
             SkillInstallError.networkUnavailable.localizedDescription),
            (.commandFailed(args: ["ls-remote"], exitCode: 128, stderr: "Authentication failed"),
             SkillInstallError.authenticationFailed.localizedDescription),
            (.unusable(.licenseNotAccepted),
             GitError.unusable(.licenseNotAccepted).localizedDescription)
        ]
        for (index, failure) in failures.enumerated() {
            let (error, expected) = failure
            let probe = RuleProbe()
            probe.set { .usable }
            let runtime = try AppRuntime(
                scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults("failure-\(index)"),
                paths: fixture.paths,
                updateCheckOperation: { _ in throw error }, gitUsabilityProbe: probe.run
            )
            await runtime.bootstrapTask.value
            if case .unusable = error { probe.set { .licenseNotAccepted } }
            runtime.checkForSkillUpdatesNow()
            await finished(runtime)
            XCTAssertEqual(runtime.updateCheckError, expected)
            XCTAssertEqual(runtime.updateCheckAlertError, expected)
        }
    }

    func testCombinedUpdateErrorsAreSafeSingleLineText() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            updateCheckOperation: { _ in
                throw UpdateCheckExecutionFailure(
                    report: UpdateCheckReport(environmentError: SkillInstallError.networkUnavailable),
                    underlying: GitError.repositoryUnreadable(path: "fixture", detail: "save\n\u{1B}[31mfailed\u{1B}[0m")
                )
            }, gitUsabilityProbe: { .usable }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        let message = try XCTUnwrap(runtime.updateCheckError)
        XCTAssertTrue(message.contains(SkillInstallError.networkUnavailable.localizedDescription))
        XCTAssertTrue(message.contains("save failed"))
        XCTAssertFalse(message.unicodeScalars.contains { $0.properties.generalCategory == .control })
        XCTAssertEqual(runtime.updateCheckAlertError, message)
    }

    private func finished(_ runtime: AppRuntime) async {
        await TestWait.until(failureMessage: "update check did not finish") { !runtime.updateCheckInFlight }
    }
}
