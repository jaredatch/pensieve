import XCTest
@testable import Pensieve

extension AppRuntimeGitUsabilityTests {
    func testTickAndWakeRecoverUnknownGitWithoutUserAction() async throws {
        for wake in [false, true] {
            let h = try await makeSyncRecoveryHarness(initialProbeError: GitError.outputReadFailed(detail: "launch EIO"))
            XCTAssertNil(h.runtime.gitUsability)
            h.runtime.scheduler.launchIngestCompleted()
            XCTAssertFalse(h.runtime.scheduler.hasPendingTrigger, "unknown git drops the launch trigger")
            h.probe.set {
                XCTAssertFalse(Thread.isMainThread, "scheduled rechecks must not freeze the window")
                return .usable
            }
            if wake { h.runtime.scheduler.wake() } else { h.runtime.scheduler.tick() }
            await h.waitForCycle(1)
            XCTAssertEqual(h.probe.count, 2, "one scheduled event earns one recheck")
            XCTAssertEqual(h.runtime.gitUsability, .usable)
            h.release.open()
            await h.finish()
            XCTAssertEqual(h.engine.count, 1, "the trigger and recovery must coalesce")
        }
    }

    func testUnknownRecoveryFromSettingsUpdatesAndSyncCatchesUpOnce() async throws {
        for source in ["settings", "updates", "sync"] {
            let h = try await makeSyncRecoveryHarness(
                initialProbeError: GitError.outputReadFailed(detail: "launch EIO"),
                updateCheckOperation: { _ in RuntimeUpdateCheckResult(
                    report: UpdateCheckReport(reachedRemote: true, gitUsability: .usable), skills: [:]) })
            h.runtime.scheduler.launchIngestCompleted()
            for _ in 0..<5 { h.runtime.scheduler.enqueueTrigger() }
            XCTAssertEqual(h.engine.count, 0, "unknown git drops scheduled work")
            switch source {
            case "settings": await h.runtime.refreshGitUsability()
            case "updates":
                h.runtime.checkForSkillUpdatesNow()
                await TestWait.until(failureMessage: "update check did not finish") { !h.runtime.updateCheckInFlight }
            default:
                let manual = Task { await h.runtime.syncModel.syncNowAndReport() }
                await h.waitForCycle(1)
                h.release.open()
                await manual.value
            }
            let expected = source == "sync" ? 2 : 1
            await h.waitForCycle(expected)
            XCTAssertEqual(h.runtime.gitUsability, .usable, source)
            h.release.open()
            await h.waitForIdle()
            await h.runtime.refreshGitUsability()
            await h.finish()
            XCTAssertEqual(h.engine.count, expected, "\(source): repeated usable evidence earns no extra catch-up")
        }
    }

    func testUnknownRechecksCoalesceAndStopAfterKnownAnswer() async throws {
        for answer in [GitUsability.usable, .developerToolsMissing] {
            let h = try await makeSyncRecoveryHarness(initialProbeError: GitError.outputReadFailed(detail: "launch EIO"))
            h.runtime.scheduler.launchIngestCompleted()
            let started = expectation(description: "scheduled probe started")
            let release = TestWait.Gate(owner: self)
            h.probe.set {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                try? release.wait()
                return answer
            }
            h.runtime.scheduler.tick()
            await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
            for _ in 0..<5 { h.runtime.scheduler.tick(); h.runtime.scheduler.wake() }
            var settingsEntered = false
            let settings = Task {
                settingsEntered = true
                await h.runtime.refreshGitUsability()
            }
            await TestWait.until(failureMessage: "Settings did not join the held probe") { settingsEntered }
            // A configuration-only read joins neither the held probe nor its evidence clock.
            await h.runtime.mainWindowAppeared()
            XCTAssertEqual(h.probe.count, 2, "tick, wake and Settings share the in-flight probe")
            XCTAssertNil(h.runtime.gitUsability)
            XCTAssertEqual(h.engine.count, 0, "no cycle may start before the probe answers")
            release.open()
            await settings.value
            await TestWait.until(failureMessage: "git answer was not accepted") { h.runtime.gitUsability == answer }
            if answer == .usable {
                await h.waitForCycle(1)
                h.release.open()
            }
            await h.waitForIdle()
            for (index, trigger) in [h.runtime.scheduler.tick, h.runtime.scheduler.wake].enumerated() {
                trigger()
                if answer == .usable {
                    await h.waitForCycle(index + 2)
                    h.release.open()
                    await h.waitForIdle()
                }
            }
            await h.finish()
            XCTAssertEqual(h.probe.count, 2, "known usable and known unusable answers stop scheduled rechecks")
            XCTAssertEqual(h.engine.count, answer == .usable ? 3 : 0)
        }
    }
}
