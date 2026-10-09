import XCTest
@testable import Pensieve

extension AppRuntimeGitUsabilityTests {
    func testTickAndWakeRecoverUnknownGitWithoutUserAction() async throws {
        try await assertIneligibleEventsDoNotRecheck()
        for (event, launchReady) in [("tick", true), ("wake", true), ("nudge", true),
                                     ("tick", false), ("wake", false)] {
            try await assertScheduledEventRechecks(event, launchReady: launchReady)
        }
        for event in ["tick", "wake", "nudge"] {
            for request in [SyncRequest.launchPreflight, .manual] {
                try await assertScheduledEventRechecks(event, request: request)
            }
        }
    }

    private func assertScheduledEventRechecks(_ event: String, launchReady: Bool = true,
                                              request: SyncRequest? = nil) async throws {
        let h = try await makeSyncRecoveryHarness(initialProbeError: GitError.outputReadFailed(detail: "launch EIO"))
        XCTAssertNil(h.runtime.gitUsability)
        if let request {
            h.preference.enabled = false
            h.runtime.scheduler.enqueue(request)
        }
        if launchReady {
            h.runtime.scheduler.launchIngestCompleted()
            XCTAssertEqual(h.runtime.scheduler.hasPendingTrigger, request != nil,
                           "unknown git holds privileged requests and drops scheduled-only work")
        }
        h.probe.set {
            XCTAssertFalse(Thread.isMainThread, "scheduled rechecks must not freeze the window")
            return .usable
        }
        fireScheduledEvent(event, on: h.runtime.scheduler)
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "\(event), \(String(describing: request)): eligible request must recheck git") {
            h.runtime.gitUsability == .usable
        }
        let usability = try XCTUnwrap(h.runtime.gitUsability)
        XCTAssertEqual(usability, .usable)
        if !launchReady {
            XCTAssertEqual(h.engine.count, 0, "ingestion still gates cycles")
            h.runtime.scheduler.launchIngestCompleted()
        }
        await h.waitForCycle(1)
        XCTAssertEqual(h.probe.count, 2, "one scheduled event earns one recheck")
        XCTAssertEqual(h.runtime.gitUsability, .usable)
        h.release.open()
        await h.finish()
        XCTAssertEqual(h.engine.count, 1, "the trigger and recovery must coalesce")
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
        for (source, configurationHeld, request) in [
            ("updates", false, SyncRequest.manual), ("updates", true, .launchPreflight),
            ("sync", false, .scheduled), ("sync", true, .manual)
        ] {
            try await assertNewEvidenceDrainsHeldRecheck(source, configurationHeld: configurationHeld, request: request)
        }
    }

    func testUnknownRechecksCoalesceAndStopAfterKnownAnswer() async throws {
        for answer in [GitUsability.usable, .developerToolsMissing] {
            let h = try await makeSyncRecoveryHarness(initialProbeError: GitError.outputReadFailed(detail: "launch EIO"))
            h.runtime.scheduler.launchIngestCompleted()
            let release = TestWait.Gate(owner: self)
            h.probe.set {
                XCTAssertFalse(Thread.isMainThread)
                try? release.wait()
                return answer
            }
            h.runtime.scheduler.tick()
            await TestWait.until(failureMessage: "scheduled probe did not start") { release.waiterCount > 0 }
            for _ in 0..<5 { h.runtime.scheduler.tick(); h.runtime.scheduler.wake() }
            // Keep the existing worker held, but let an erroneous window probe return promptly.
            h.probe.set { XCTAssertFalse(Thread.isMainThread); return answer }
            // A configuration-only read joins neither the held probe nor its evidence clock.
            await h.runtime.mainWindowAppeared()
            XCTAssertNil(h.runtime.gitUsability)
            XCTAssertEqual(h.engine.count, 0, "no cycle may start before the probe answers")
            // Release unexpected probes too so a coalescing failure cannot strand their workers.
            for _ in 0..<11 { release.open() }
            await TestWait.until(failureMessage: "git answer was not accepted") { h.runtime.gitUsability == answer }
            if answer == .usable {
                await h.waitForCycle(1)
                h.release.open()
            }
            await h.waitForDrain()
            // Judge the overlap batch after its asynchronous work drains, before any known-state event.
            XCTAssertEqual(h.probe.count, 2, "overlapping ticks and wakes share the in-flight probe")
            await assertKnownAnswerStopsRechecks(h, answer: answer)
            await h.finish()
            XCTAssertEqual(h.probe.count, 2, "known usable and known unusable answers stop scheduled rechecks")
            XCTAssertEqual(h.engine.count, answer == .usable ? 3 : 0)
        }
    }

    private func assertKnownAnswerStopsRechecks(_ h: RecoveryHarness, answer: GitUsability) async {
        // An erroneous recheck must return so the probe-count assertion catches it, without a gate timeout.
        h.probe.set { XCTAssertFalse(Thread.isMainThread); return answer }
        await h.waitForDrain()
        for (index, trigger) in [h.runtime.scheduler.tick, h.runtime.scheduler.wake].enumerated() {
            trigger()
            if answer == .usable {
                await h.waitForCycle(index + 2)
                h.release.open()
            }
            // A recheck keeps the scheduled request pending even when no sync cycle is in flight.
            await h.waitForDrain()
            XCTAssertEqual(h.probe.count, 2, "known \(answer): event \(index) must not probe git again")
        }
    }

    private func fireScheduledEvent(_ event: String, on scheduler: SyncScheduler) {
        switch event {
        case "tick": scheduler.tick()
        case "wake": scheduler.wake()
        default: scheduler.nudge()
        }
    }

    private func assertIneligibleEventsDoNotRecheck() async throws {
        for refusal in ["background off", "unconfigured", "conflicted"] {
            let h = try await makeSyncRecoveryHarness(initialProbeError: GitError.outputReadFailed(detail: "launch EIO"))
            switch refusal {
            case "background off": h.preference.enabled = false
            case "unconfigured":
                h.runtime.syncModel.applyConfiguration(.success(.init(remoteURL: nil, hasLocalBranches: true)),
                                                       order: h.runtime.syncModel.beginConfiguration())
            default: h.runtime.syncModel.apply(.conflicted(["skills/example/SKILL.md"]))
            }
            h.runtime.scheduler.launchIngestCompleted()
            let before = h.runtime.syncModel.configurationDescription
            h.probe.set {
                XCTAssertFalse(Thread.isMainThread)
                XCTFail("\(refusal): ineligible event probed git")
                return .developerToolsMissing
            }
            for event in ["tick", "wake", "nudge"] { fireScheduledEvent(event, on: h.runtime.scheduler) }
            // Tick and wake decide refusal inline; give the zero-delay nudge its actor turn.
            await Task.yield()
            XCTAssertEqual(h.probe.count, 1, refusal)
            XCTAssertNil(h.runtime.gitUsability, refusal)
            XCTAssertEqual(h.runtime.syncModel.configurationDescription, before, refusal)
            XCTAssertEqual(h.engine.count, 0, refusal)
            await h.finish()
        }
    }

    private func assertNewEvidenceDrainsHeldRecheck(_ source: String, configurationHeld: Bool,
                                                    request: SyncRequest) async throws {
        let held = TestWait.Gate(owner: self)
        let git = IngestRecordingGit()
        let reads = RuleProbe()
        git.remoteRead = {
            _ = reads.run()
            if configurationHeld && reads.count == 1 { try held.wait() }
            return "https://fixture.test/store.git"
        }
        let h = try await makeSyncRecoveryHarness(initialProbeError: GitError.outputReadFailed(detail: "launch EIO"),
            updateCheckOperation: { _ in RuntimeUpdateCheckResult(
                report: UpdateCheckReport(reachedRemote: true, gitUsability: .usable), skills: [:]) },
            configurationGit: git)
        h.runtime.scheduler.launchIngestCompleted()
        h.probe.set {
            XCTAssertFalse(Thread.isMainThread)
            if !configurationHeld { try? held.wait(); return .licenseNotAccepted }
            return .usable
        }
        h.runtime.scheduler.tick()
        await TestWait.until(failureMessage: "recheck did not reach its held step") { held.waiterCount == 1 }
        h.runtime.scheduler.enqueue(request)
        if source == "updates" {
            h.runtime.checkForSkillUpdatesNow()
            await TestWait.until(failureMessage: "update evidence did not finish") { !h.runtime.updateCheckInFlight }
        } else {
            let manual = Task { await h.runtime.syncModel.syncNowAndReport() }
            await h.waitForCycle(1)
            h.release.open()
            await manual.value
        }
        let expected = source == "sync" ? 2 : 1
        await h.waitForCycle(expected, timeout: .seconds(TestWait.hostedActionTimeoutSeconds))
        XCTAssertEqual(h.engine.count, expected, "\(source): newer usable evidence must drain before the old recheck returns")
        XCTAssertEqual(held.waiterCount, 1, "the old probe or configuration read is still held")
        held.open()
        h.release.open()
        await h.waitForDrain()
        await h.finish()
        XCTAssertEqual(h.engine.count, expected, "the old recheck must not add a catch-up")
        XCTAssertEqual(h.runtime.gitUsability, .usable, "old unusable evidence must stay retired")
    }
}
