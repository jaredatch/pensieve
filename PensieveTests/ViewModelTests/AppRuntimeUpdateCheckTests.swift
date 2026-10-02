import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeUpdateCheckTests: XCTestCase {
    private struct ExpectedFailure: LocalizedError {
        var errorDescription: String? { "The check failed as expected." }
    }

    /// The injected operation runs on a detached task, so test call counts need their own lock.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func read() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func makeRuntime(
        defaults: UserDefaults,
        now: @escaping () -> Date,
        operation: @escaping AppRuntime.UpdateCheckOperation
    ) throws -> AppRuntime {
        let paths = try AppRuntimePaths.temporary(named: "AppRuntimeUpdateCheckTests")
        return try AppRuntime(
            defaults: defaults,
            hostName: { nil },
            paths: paths,
            updateCheckOperation: operation,
            now: now,
            gitUsabilityProbe: { .usable }
        )
    }

    func testManualCheckRunsWhenOffAndWhenNotDueAndStampsStart() async throws {
        let defaults = try isolatedDefaults()
        let counter = LockedCounter()
        var current = Date(timeIntervalSince1970: 2_000_000)
        defaults.set(UpdateCheckFrequency.off.rawValue, forKey: UpdateCheckSchedule.frequencyKey)
        defaults.set(current.addingTimeInterval(-60).timeIntervalSince1970,
                     forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        let runtime = try makeRuntime(
            defaults: defaults,
            now: { current },
            operation: { _ in
                counter.increment()
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(reachedRemote: true), skills: [:])
            }
        )

        runtime.checkForSkillUpdatesNow()
        await TestWait.until(failureMessage: "update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertEqual(counter.read(), 1)
        XCTAssertEqual(runtime.lastUpdateCheckStartedAt, current)

        current = current.addingTimeInterval(60)
        defaults.set(UpdateCheckFrequency.daily.rawValue, forKey: UpdateCheckSchedule.frequencyKey)
        runtime.checkForSkillUpdatesNow()
        await TestWait.until(failureMessage: "update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertEqual(counter.read(), 2)
        XCTAssertEqual(runtime.lastUpdateCheckStartedAt, current)
    }

    func testSecondStartWhileCheckIsRunningIsNoOp() async throws {
        let defaults = try isolatedDefaults()
        let counter = LockedCounter()
        let started = expectation(description: "first check started")
        let release = DispatchSemaphore(value: 0)
        let runtime = try makeRuntime(defaults: defaults, now: Date.init) { _ in
            counter.increment()
            started.fulfill()
            release.wait()
            return RuntimeUpdateCheckResult(report: UpdateCheckReport(reachedRemote: true), skills: [:])
        }

        runtime.checkForSkillUpdatesNow()
        await fulfillment(of: [started], timeout: TestWait.timeoutSeconds)
        runtime.checkForSkillUpdatesNow()

        XCTAssertTrue(runtime.updateCheckInFlight)
        XCTAssertEqual(counter.read(), 1)

        release.signal()
        release.signal()
        await TestWait.until(failureMessage: "update check did not finish") { !runtime.updateCheckInFlight }
        XCTAssertEqual(counter.read(), 1)
    }

    func testAutomaticCheckSkipsWhenNotDueAndRunsWhenDue() async throws {
        let defaults = try isolatedDefaults()
        let counter = LockedCounter()
        let current = Date(timeIntervalSince1970: 3_000_000)
        defaults.set(UpdateCheckFrequency.daily.rawValue, forKey: UpdateCheckSchedule.frequencyKey)
        defaults.set(current.addingTimeInterval(-60).timeIntervalSince1970,
                     forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        let runtime = try makeRuntime(
            defaults: defaults,
            now: { current },
            operation: { _ in
                counter.increment()
                return RuntimeUpdateCheckResult(report: UpdateCheckReport(reachedRemote: true), skills: [:])
            }
        )

        runtime.checkForSkillUpdatesIfDue()
        await Task.yield()
        XCTAssertEqual(counter.read(), 0)
        XCTAssertFalse(runtime.updateCheckInFlight)

        defaults.set(current.addingTimeInterval(-(24 * 60 * 60)).timeIntervalSince1970,
                     forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        runtime.checkForSkillUpdatesIfDue()
        await TestWait.until(failureMessage: "automatic update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertEqual(counter.read(), 1)
        XCTAssertEqual(runtime.lastUpdateCheckStartedAt, current)
    }

    func testFailedCheckRoutesAlertByTriggerAndClearsInFlightState() async throws {
        let defaults = try isolatedDefaults()
        let runtime = try makeRuntime(defaults: defaults, now: Date.init) { _ in
            throw ExpectedFailure()
        }

        runtime.checkForSkillUpdatesFromSettings()
        await TestWait.until(failureMessage: "settings update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertFalse(runtime.updateCheckInFlight)
        XCTAssertEqual(runtime.updateCheckError, "The check failed as expected.")
        XCTAssertNil(runtime.updateCheckAlertError)

        runtime.checkForSkillUpdatesNow()
        await TestWait.until(failureMessage: "manual update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertFalse(runtime.updateCheckInFlight)
        XCTAssertEqual(runtime.updateCheckError, "The check failed as expected.")
        XCTAssertEqual(runtime.updateCheckAlertError, "The check failed as expected.")

        runtime.clearUpdateCheckAlert()
        defaults.set(UpdateCheckFrequency.daily.rawValue, forKey: UpdateCheckSchedule.frequencyKey)
        defaults.set(1, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        runtime.checkForSkillUpdatesIfDue()
        await TestWait.until(failureMessage: "automatic update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertFalse(runtime.updateCheckInFlight)
        XCTAssertEqual(runtime.updateCheckError, "The check failed as expected.")
        XCTAssertEqual(runtime.updateCheckAlertError, "The check failed as expected.")
    }

    func testSettingsCheckPreservesPendingAlert() async throws {
        let defaults = try isolatedDefaults()
        let runtime = try makeRuntime(defaults: defaults, now: Date.init) { _ in
            throw ExpectedFailure()
        }

        runtime.checkForSkillUpdatesNow()
        await TestWait.until(failureMessage: "manual update check did not finish") { !runtime.updateCheckInFlight }
        XCTAssertEqual(runtime.updateCheckAlertError, "The check failed as expected.")

        runtime.checkForSkillUpdatesFromSettings()
        await TestWait.until(failureMessage: "settings update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertEqual(runtime.updateCheckError, "The check failed as expected.")
        XCTAssertEqual(runtime.updateCheckAlertError, "The check failed as expected.")
    }

    func testSuccessfulSettingsCheckPreservesPendingAlert() async throws {
        let defaults = try isolatedDefaults()
        let attempts = LockedCounter()
        let runtime = try makeRuntime(defaults: defaults, now: Date.init) { _ in
            attempts.increment()
            if attempts.read() == 1 { throw ExpectedFailure() }
            return RuntimeUpdateCheckResult(report: UpdateCheckReport(reachedRemote: true), skills: [:])
        }

        runtime.checkForSkillUpdatesNow()
        await TestWait.until(failureMessage: "manual update check did not finish") { !runtime.updateCheckInFlight }
        XCTAssertEqual(runtime.updateCheckAlertError, "The check failed as expected.")

        runtime.checkForSkillUpdatesFromSettings()
        await TestWait.until(failureMessage: "settings update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertNil(runtime.updateCheckError)
        XCTAssertEqual(runtime.updateCheckAlertError, "The check failed as expected.")
    }

    func testTemporaryRuntimeProvenanceReadsTemporaryStore() async throws {
        let paths = try AppRuntimePaths.temporary(named: "AppRuntimeProvenancePaths")
        let runtime = try AppRuntime(
            defaults: isolatedDefaults(), hostName: { nil }, paths: paths,
            gitUsabilityProbe: { .usable }
        )
        let slug = "runtime-only-\(UUID().uuidString.lowercased())"
        let skill = Skill(name: "Runtime Only", directoryName: slug)
        skill.installedOrigin = InstalledOrigin(
            repo: "https://github.com/example/skills",
            path: "skills/\(slug)",
            ref: "main",
            installedCommit: "installed",
            installedTree: "tree",
            contentHash: "sha256:not-the-temporary-file",
            installedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        runtime.container.mainContext.insert(skill)
        try runtime.container.mainContext.save()
        try FileService().writeFile(
            at: paths.skillsDir + "/\(slug)/SKILL.md",
            content: "temporary runtime content"
        )

        await runtime.provenanceVM.present(
            skillID: skill.id,
            context: runtime.container.mainContext
        )

        XCTAssertEqual(
            runtime.provenanceVM.provenance(for: skill)?.localEditNote,
            "This copy has local edits"
        )
        XCTAssertNil(runtime.provenanceVM.driftError(for: skill.id))
    }

    func testResultsLandWithoutAWindowAndClearTransientSkillError() async throws {
        let defaults = try isolatedDefaults()
        let skill = Skill(name: "PDF", directoryName: "pdf")
        skill.installedOrigin = InstalledOrigin(
            repo: "https://github.com/example/skills",
            path: "skills/pdf",
            ref: "main",
            installedCommit: "installed",
            installedTree: "tree",
            contentHash: "hash",
            installedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let provenance = SkillProvenanceViewModel(
            driftOperation: { _, _ in false },
            checkOperation: { _, _ in throw ExpectedFailure() }
        )
        let runtime = try AppRuntime(
            defaults: defaults,
            hostName: { nil },
            paths: try AppRuntimePaths.temporary(named: "AppRuntimeUpdateCheckResults"),
            provenanceVM: provenance,
            updateCheckOperation: { _ in
                RuntimeUpdateCheckResult(report: UpdateCheckReport(reachedRemote: true),
                                         skills: [skill.id: SkillUpdateCheckResult(updateAvailable: true, checkError: nil)])
            },
            gitUsabilityProbe: { .usable }
        )
        runtime.container.mainContext.insert(skill)
        try runtime.container.mainContext.save()
        provenance.checkForUpdates(skillID: skill.id, context: runtime.container.mainContext)
        await TestWait.until(failureMessage: "skill provenance check did not finish") {
            !provenance.isChecking(skillID: skill.id)
        }
        XCTAssertEqual(provenance.provenance(for: skill)?.checkError,
                       "The check failed as expected.")

        runtime.checkForSkillUpdatesNow()
        await TestWait.until(failureMessage: "runtime update check did not finish") { !runtime.updateCheckInFlight }

        XCTAssertTrue(skill.updateAvailable)
        XCTAssertNil(provenance.provenance(for: skill)?.checkError)
    }

}
