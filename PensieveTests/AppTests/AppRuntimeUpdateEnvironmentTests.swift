import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeUpdateEnvironmentTests: XCTestCase {
    func testOfflineRunStaysDueAcrossLaunchAndMixedRunCounts() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let defaults = try isolatedDefaults()
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let git = RecordingUpdateGitService()
        let offline = GitError.commandFailed(args: ["ls-remote"], exitCode: 128, stderr: "Could not resolve host: github.com")
        let service = UpdateCheckService(
            gitService: git, credentialStore: InMemoryCredentialStore(),
            scratchRoot: fixture.base + "/scratch", storeRoot: fixture.root,
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
        let ids = try seedSkills(container)
        git.remoteHeadErrors = ["fixture://first": offline, "fixture://second": offline]
        let runtime = try makeRuntime(fixture, defaults: defaults, container: container, service: service)
        await runtime.bootstrapTask.value
        runtime.backgroundSyncEnabled = false
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertNil(runtime.lastUpdateCheckStartedAt)
        XCTAssertEqual(runtime.updateCheckError, SkillInstallError.networkUnavailable.localizedDescription)
        XCTAssertEqual(runtime.updateCheckAlertError, runtime.updateCheckError)
        for skill in try ModelContext(container).fetch(FetchDescriptor<Skill>()) {
            XCTAssertEqual(skill.checkError, "old error")
            XCTAssertEqual(skill.lastCheckedAt, Date(timeIntervalSince1970: 10))
        }
        // Bootstrap and the check are complete. This fixture never starts launch ingestion, retries or its timer.
        XCTAssertEqual(runtime.launchWorkInvocationCount, 0)
        XCTAssertFalse(runtime.scheduler.isSyncing)
        XCTAssertFalse(runtime.syncModel.isCycleInFlight)
        let relaunched = try makeRuntime(fixture, defaults: defaults,
        container: container, service: service)
        await relaunched.bootstrapTask.value
        XCTAssertFalse(relaunched.backgroundSyncEnabled, "relaunch must read the first session persisted defaults")
        git.remoteHeadErrors.removeValue(forKey: "fixture://first")
        git.heads["fixture://first"] = "new-head"
        git.trees["skills/first"] = "new-tree"
        relaunched.checkForSkillUpdatesIfDue()
        await finished(relaunched)
        XCTAssertEqual(git.remoteHeadCalls.count, 4, "second launch retried both sources")
        XCTAssertEqual(relaunched.lastUpdateCheckStartedAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(relaunched.updateCheckError, SkillInstallError.networkUnavailable.localizedDescription)
        let saved = try ModelContext(container).fetch(FetchDescriptor<Skill>())
        XCTAssertNil(saved.first { $0.id == ids[0] }?.checkError)
        XCTAssertEqual(saved.first { $0.id == ids[1] }?.checkError, "old error")
        relaunched.checkForSkillUpdatesIfDue()
        XCTAssertFalse(relaunched.updateCheckInFlight, "a partial answered run is no longer due")
        XCTAssertFalse(runtime.updateCheckInFlight, "the completed first session may still be retained")
    }

    func testUnusableRunDoesNotOverwritePreviousAutomaticDate() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let defaults = try isolatedDefaults()
        defaults.set(123.0, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        let git = RecordingUpdateGitService()
        git.usability = .licenseNotAccepted
        let service = UpdateCheckService(gitService: git, credentialStore: InMemoryCredentialStore(),
                                         scratchRoot: fixture.base + "/scratch", storeRoot: fixture.root,
                                         remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) })
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        _ = try seedSkills(container)
        let runtime = try makeRuntime(fixture, defaults: defaults, container: container, service: service)
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertEqual(runtime.lastUpdateCheckStartedAt, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(runtime.updateCheckError, GitUsability.licenseNotAccepted.message)
        XCTAssertEqual(runtime.updateCheckAlertError, runtime.updateCheckError)
        XCTAssertTrue(git.remoteHeadCalls.isEmpty)
    }

    func testAutomaticEnvironmentFailureAlertsOncePerSessionAndManualStillRuns() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let defaults = try isolatedDefaults()
        let probes = EnvironmentProbeCounter()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: defaults, paths: fixture.paths,
            updateCheckOperation: { _ in
                RuntimeUpdateCheckResult(
                    report: UpdateCheckReport(environmentError: SkillInstallError.networkUnavailable), skills: [:]
                )
            }, gitUsabilityProbe: { probes.increment(); return .usable }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        XCTAssertNotNil(runtime.updateCheckAlertError)
        XCTAssertEqual(probes.count, 1, "network failure must not probe git again")
        runtime.clearUpdateCheckAlert()
        for _ in 0..<3 {
            runtime.checkForSkillUpdatesIfDue()
            XCTAssertFalse(runtime.updateCheckInFlight, "activation must not repeat the failed automatic run")
            await finished(runtime)
            XCTAssertNil(runtime.updateCheckAlertError)
        }
        runtime.checkForSkillUpdatesNow()
        await finished(runtime)
        XCTAssertNotNil(runtime.updateCheckAlertError, "manual checks always report")
        XCTAssertNil(runtime.lastUpdateCheckStartedAt)
    }

    func testEmptyAndAllAuthenticationRunsAdvanceAutomaticDate() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        for empty in [true, false] {
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let git = RecordingUpdateGitService()
            if empty { git.usability = .developerToolsMissing } else {
                _ = try seedSkills(container)
                for repo in ["fixture://first", "fixture://second"] {
                    git.remoteHeadErrors[repo] = .authenticationFailed(remote: repo, detail: "denied")
                }
            }
            let service = UpdateCheckService(
                gitService: git, credentialStore: InMemoryCredentialStore(),
                scratchRoot: fixture.base + "/scratch", storeRoot: fixture.root,
                remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
            )
            let runtime = try makeRuntime(fixture, defaults: isolatedDefaults("empty-\(empty)"),
            container: container, service: service)
            await runtime.bootstrapTask.value
            runtime.checkForSkillUpdatesIfDue()
            await finished(runtime)
            XCTAssertNil(runtime.updateCheckError)
            XCTAssertEqual(runtime.lastUpdateCheckStartedAt, Date(timeIntervalSince1970: 2_000_000_000))
            runtime.checkForSkillUpdatesIfDue()
            XCTAssertFalse(runtime.updateCheckInFlight)
            await finished(runtime)
        }
    }

    func testGitRecoveryRetriesAutomaticCheckInSameSession() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = RecordingUpdateGitService()
        git.usability = .licenseNotAccepted
        let calls = EnvironmentProbeCounter()
        let runtime = try AppRuntime(
            scheduler: SyncScheduler(startAutomatically: false), defaults: isolatedDefaults(), paths: fixture.paths,
            updateCheckOperation: { _ in
                calls.increment()
                return RuntimeUpdateCheckResult(
                    report: UpdateCheckReport(
                        environmentError: GitError.unusable(.licenseNotAccepted), gitUsability: .licenseNotAccepted
                    ), skills: [:]
                )
            }, gitUsabilityProbe: { git.usability }
        )
        await runtime.bootstrapTask.value
        runtime.checkForSkillUpdatesIfDue()
        await finished(runtime)
        runtime.clearUpdateCheckAlert()
        runtime.checkForSkillUpdatesIfDue()
        XCTAssertFalse(runtime.updateCheckInFlight)
        await finished(runtime)
        XCTAssertEqual(calls.count, 1)
        git.usability = .usable
        await runtime.refreshGitUsability()
        await finished(runtime)
        XCTAssertEqual(calls.count, 2, "a usability recovery retries the due automatic check")
    }

    private func finished(_ runtime: AppRuntime) async {
        await TestWait.until(failureMessage: "check did not finish") { !runtime.updateCheckInFlight }
    }

    private func makeRuntime(_ fixture: GitFailureFixture, defaults: UserDefaults,
                             container: ModelContainer, service: UpdateCheckService) throws -> AppRuntime {
        try AppRuntime(container: container, scheduler: SyncScheduler(startAutomatically: false),
                       defaults: defaults, paths: fixture.paths,
                       updateCheckOperation: fixture.paths.makeUpdateCheckOperation(service: service),
                       now: { Date(timeIntervalSince1970: 2_000_000_000) }, gitUsabilityProbe: { .usable })
    }

    private func seedSkills(_ container: ModelContainer) throws -> [UUID] {
        let context = container.mainContext
        var ids: [UUID] = []
        for slug in ["first", "second"] {
            let skill = Skill(name: slug, directoryName: slug)
            skill.installedOrigin = InstalledOrigin(
                repo: "fixture://\(slug)", path: "skills/\(slug)", ref: "main",
                installedCommit: "installed", installedTree: "tree", contentHash: "hash",
                installedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
            )
            skill.checkError = "old error"
            skill.lastCheckedAt = Date(timeIntervalSince1970: 10)
            context.insert(skill)
            ids.append(skill.id)
        }
        try context.save()
        return ids
    }
}

/// Counts invocations from detached runtime operations without sharing mutable actor state.
private final class EnvironmentProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
