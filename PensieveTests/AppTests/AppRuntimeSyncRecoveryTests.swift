import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeSyncRecoveryTests: XCTestCase {
    func testRecoveryDuringCycleQueuesCatchUpForEligibleOutcomes() async throws {
        let outcomes: [Result<SyncOutcome, Error>] = [
            .success(.synced(pushed: false, warnings: [])), .success(.noRemote),
            .failure(SyncError.syncInProgress), .failure(SyncError.storeUnreadable([])),
            .failure(GitError.unusable(.developerToolsMissing)),
            .success(.conflicted(["skills/example/SKILL.md"])), .success(.branchless)
        ]
        for (index, outcome) in outcomes.enumerated() {
            let h = try await makeSyncRecoveryHarness(outcomes: [outcome])
            h.runtime.scheduler.launchIngestCompleted()
            await h.waitForCycle(1)
            if index == outcomes.count - 1 {
                try h.fixture.files.deleteFile(at: h.fixture.root + "/.git/refs/heads/main")
            }
            await h.recover()
            h.release.open()
            let shouldRetry = index < outcomes.count - 2
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, shouldRetry ? 2 : 1, "outcome \(outcome)")
            if shouldRetry { h.release.open() }
            await h.finish()
            XCTAssertEqual(h.engine.count, shouldRetry ? 2 : 1, "no new recovery, no further cycle")
        }
    }

    func testQueuedRequestsAbsorbRecoveryAndRecoveryDuringCatchUpGetsOneMore() async throws {
        for queued in ["manual", "scheduled", "watcher", "none"] {
            let h = try await makeSyncRecoveryHarness()
            h.runtime.scheduler.launchIngestCompleted()
            await h.waitForCycle(1)
            switch queued {
            case "manual": await h.runtime.syncModel.syncNowAndReport()
            case "scheduled": h.runtime.scheduler.tick()
            case "watcher":
                h.runtime.scheduler.nudge()
                await TestWait.until(failureMessage: "watcher nudge was not queued") {
                    h.runtime.scheduler.hasPendingTrigger
                }
            default: break
            }
            await h.recover()
            h.release.open()
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, 2, "\(queued) must absorb recovery into one cycle")
            if h.engine.count == 2 {
                await h.recover()
                h.release.open()
                await h.waitForFollowUpOrIdle(after: 2)
                XCTAssertEqual(h.engine.count, 3, "a new recovery during catch-up gets one more")
                h.release.open()
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, 3, queued)
        }
    }

    func testRecoveryRetriesFailedManualSyncWithBackgroundOffButNotScheduledSync() async throws {
        let cases = [(true, false, true), (true, true, true), (true, false, false), (false, false, true)]
        for (manual, retryFails, unusableAtCompletion) in cases {
            let failure: GitError = unusableAtCompletion ? .unusable(.developerToolsMissing)
                : .repositoryUnreadable(path: "fixture", detail: "read failed")
            var outcomes: [Result<SyncOutcome, Error>] = [.failure(failure)]
            if retryFails { outcomes.append(.failure(GitError.unusable(.developerToolsMissing))) }
            let h = try await makeSyncRecoveryHarness(outcomes: outcomes)
            let cycle: Task<Void, Never>?
            if manual {
                h.preference.enabled = false
                h.runtime.scheduler.launchIngestCompleted()
                cycle = Task { await h.runtime.syncModel.syncNowAndReport() }
            } else {
                cycle = nil
                h.runtime.scheduler.launchIngestCompleted()
            }
            await h.waitForCycle(1)
            if unusableAtCompletion { h.probe.set { .developerToolsMissing } }
            h.release.open()
            await cycle?.value
            await h.waitForIdle()
            if !unusableAtCompletion {
                h.probe.set { .developerToolsMissing }
                await h.runtime.refreshGitUsability()
            }
            XCTAssertEqual(h.runtime.gitUsability, .developerToolsMissing)
            h.preference.enabled = false
            h.probe.set { .usable }
            await h.runtime.refreshGitUsability()
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, manual ? 2 : 1)
            if manual {
                if retryFails { h.probe.set { .developerToolsMissing } }
                h.release.open()
                await h.waitForIdle()
                if retryFails {
                    h.probe.set { .usable }
                    await h.runtime.refreshGitUsability()
                    await h.waitForFollowUpOrIdle(after: 2)
                }
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, manual ? 2 : 1, "one retry spends the manual request, even if it fails")
        }
        try await assertRetryExpiresWithUsableEvidence()
        try await assertRecoveryWhileIneligible()
        try await assertSpentRetryCannotRearmAfterDirectSync()
    }

    func testQueuedPrivilegedRequestKeepsStandingWhenItMeetsDirectCycle() async throws {
        for preflight in [false, true] {
            let h = try await makeSyncRecoveryHarness()
            h.preference.enabled = false
            h.runtime.scheduler.launchIngestCompleted()
            let direct = Task { await h.runtime.syncModel.syncNowAndReport() }
            await h.waitForCycle(1)
            if preflight { h.runtime.scheduler.enqueueLaunchPreflight() } else { h.runtime.scheduler.enqueueManualTrigger() }
            await TestWait.until(failureMessage: "scheduler request did not return from the busy model") {
                !h.runtime.scheduler.isSyncing
            }
            h.release.open()
            await direct.value
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, 2, "privileged request must survive background-off redispatch")
            if h.engine.count == 2 {
                XCTAssertEqual(h.engine.priorities.last,
                               preflight ? QOS_CLASS_DEFAULT : QOS_CLASS_USER_INITIATED)
                h.release.open()
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, 2)
            h.runtime.scheduler.tick()
            XCTAssertFalse(h.runtime.scheduler.isSyncing, "the bypass must be spent")
        }
        try await assertConcurrentProbeCannotSuppressStartupFailure()
        try await assertPrivilegedRequestsSurviveGitOutage()
        try await assertRefusedRetryPreservesAbsorbedStanding()
        try await assertRefusedRecoveryDoesNotCancelNudge()
    }

}

private extension AppRuntimeSyncRecoveryTests {
    func assertConcurrentProbeCannotSuppressStartupFailure() async throws {
        let started = expectation(description: "startup probe entered")
        let release = TestWait.Gate(owner: self)
        let probe = RuleProbe()
        probe.set {
            if probe.count == 1 {
                started.fulfill()
                try? release.wait()
            }
            return .usable
        }
        let startup = Task {
            try await makeSyncRecoveryHarness(probe: probe,
                initialProbeError: GitError.outputReadFailed(detail: "bootstrap EIO"))
        }
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        await TestWait.until(failureMessage: "startup probe did not block") { release.waiterCount == 1 }
        let concurrent = await BlockingWork.run(priority: .utility) { probe.run() }
        XCTAssertEqual(concurrent, .usable)
        XCTAssertEqual(probe.count, 2, "the other call must finish before startup resumes")
        release.open()
        let h = try await startup.value
        XCTAssertNil(h.runtime.gitUsability, "startup keeps its own failure despite the later shared count")
        XCTAssertEqual(h.runtime.syncModel.configurationError, "Pensieve couldn’t read git’s output: bootstrap EIO")
        await h.finish()
    }

    func assertPrivilegedRequestsSurviveGitOutage() async throws {
        for scenario in ["queued manual", "idle manual", "preflight", "first manual", "first preflight"] {
            let outcomes: [Result<SyncOutcome, Error>] = scenario == "queued manual"
                ? [.failure(GitError.unusable(.developerToolsMissing))] : []
            let probe = RuleProbe()
            let firstAnswer = scenario.hasPrefix("first")
            let h = try await makeSyncRecoveryHarness(outcomes: outcomes, probe: probe,
                initialProbeError: firstAnswer ? GitError.outputReadFailed(detail: "bootstrap EIO") : nil)
            h.preference.enabled = scenario == "queued manual"
            h.runtime.scheduler.launchIngestCompleted()
            if scenario == "queued manual" { await h.waitForCycle(1) }
            h.preference.enabled = false
            if firstAnswer {
                XCTAssertNil(h.runtime.gitUsability)
            } else {
                h.probe.set { .developerToolsMissing }
                await h.runtime.refreshGitUsability()
            }
            if scenario.hasSuffix("preflight") {
                h.runtime.scheduler.enqueueLaunchPreflight()
            } else if scenario == "queued manual" {
                await h.runtime.syncModel.syncNowAndReport()
            } else {
                h.runtime.scheduler.enqueueManualTrigger()
            }
            if scenario == "queued manual" { h.release.open() }
            await h.waitForIdle()
            let before = h.engine.count
            h.probe.set { .usable }
            await h.runtime.refreshGitUsability()
            await h.waitForFollowUpOrIdle(after: before)
            XCTAssertEqual(h.engine.count, before + 1, scenario + " must retain its background-off bypass")
            if h.engine.count == before + 1 {
                XCTAssertEqual(h.engine.priorities.last,
                               scenario.hasSuffix("preflight") ? QOS_CLASS_DEFAULT : QOS_CLASS_USER_INITIATED)
                h.probe.set { .usable }
                h.release.open()
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, before + 1)
        }
    }

    func assertRetryExpiresWithUsableEvidence() async throws {
        let h = try await makeSyncRecoveryHarness(outcomes: [
            .failure(GitError.repositoryUnreadable(path: "fixture", detail: "offline"))
        ])
        h.preference.enabled = false
        h.runtime.scheduler.launchIngestCompleted()
        let manual = Task { await h.runtime.syncModel.syncNowAndReport() }
        await h.waitForCycle(1)
        h.release.open()
        await manual.value
        await h.waitForIdle()
        await h.runtime.refreshGitUsability() // Usable evidence after the failed cycle answers its host question.
        await h.recover() // An unrelated later outage must not revive the failed manual request.
        await h.waitForFollowUpOrIdle()
        XCTAssertEqual(h.engine.count, 1, "usable evidence must retire an unrelated failed Sync Now")
        await h.finish()
        XCTAssertEqual(h.engine.count, 1)
    }

    func assertRecoveryWhileIneligible() async throws {
        for block in ["conflict", "branchless", "absent"] {
            let h = try await makeSyncRecoveryHarness(outcomes: [.failure(GitError.unusable(.developerToolsMissing))])
            h.preference.enabled = false
            h.runtime.scheduler.launchIngestCompleted()
            let manual = Task { await h.runtime.syncModel.syncNowAndReport() }
            await h.waitForCycle(1)
            h.probe.set { .developerToolsMissing }
            h.release.open()
            await manual.value
            await h.waitForIdle()
            let branch = try h.fixture.files.readFile(at: h.fixture.root + "/.git/refs/heads/main")
            switch block {
            case "conflict": h.runtime.syncModel.apply(.conflicted(["skills/example/SKILL.md"]))
            case "branchless": try h.fixture.files.deleteFile(at: h.fixture.root + "/.git/refs/heads/main")
            default: try TestPaths.git.removeRemote(at: h.fixture.root)
            }
            h.probe.set { .usable }
            await h.runtime.refreshGitUsability()
            await h.waitForIdle()
            XCTAssertEqual(h.engine.count, 1, block + " must refuse the recovery cycle")
            switch block {
            case "conflict":
                try h.runtime.beginConflictResolution()(.synced(pushed: true, warnings: [], completedAt: Date()))
            case "branchless": try h.fixture.files.writeFile(at: h.fixture.root + "/.git/refs/heads/main", content: branch)
            default: try TestPaths.git.setRemote("https://fixture.test/store.git", at: h.fixture.root)
            }
            await h.runtime.refreshGitConfiguration(probingGit: false)
            await h.waitForFollowUpOrIdle()
            let expected = block == "conflict" ? 1 : 2
            XCTAssertEqual(h.engine.count, expected,
                           block == "conflict" ? "production resolution's usable evidence retires the retry"
                           : block + " permits the retry after a configuration-only refresh")
            if h.engine.count == 2 { h.release.open() }
            await h.finish()
            XCTAssertEqual(h.engine.count, expected)
        }
    }
}

private extension AppRuntimeSyncRecoveryTests {
    func heldRecoveryBeforeIngest() async throws -> RecoveryHarness {
        let h = try await makeSyncRecoveryHarness(outcomes: [.failure(GitError.unusable(.developerToolsMissing))])
        h.preference.enabled = false
        XCTAssertFalse(h.runtime.scheduler.isLaunchIngestReady)
        let manual = Task { await h.runtime.syncModel.syncNowAndReport() }
        await h.waitForCycle(1)
        h.probe.set { .developerToolsMissing }
        h.release.open()
        await manual.value
        await h.waitForIdle()
        h.probe.set { .usable }
        await h.runtime.refreshGitUsability()
        XCTAssertTrue(h.runtime.scheduler.hasPendingTrigger, "ingest must hold the recovery request")
        XCTAssertFalse(h.runtime.scheduler.isSyncing)
        return h
    }

    func assertRefusedRetryPreservesAbsorbedStanding() async throws {
        for trigger in ["preflight", "tick", "branchless tick"] {
            let h = try await heldRecoveryBeforeIngest()
            if trigger == "branchless tick" {
                let branchPath = h.fixture.root + "/.git/refs/heads/main"
                let branch = try h.fixture.files.readFile(at: branchPath)
                try h.fixture.files.deleteFile(at: branchPath)
                await h.runtime.refreshGitConfiguration(probingGit: false)
                XCTAssertFalse(h.runtime.syncModel.canScheduleSync)
                // An external branch appears after the observation, before the queued tick re-checks it.
                try h.fixture.files.writeFile(at: branchPath, content: branch)
            } else {
                await h.runtime.refreshGitUsability() // A later usable probe invalidates the held retry.
            }
            h.preference.enabled = trigger != "preflight"
            if trigger == "preflight" {
                h.runtime.scheduler.enqueueLaunchPreflight()
            } else {
                h.runtime.scheduler.tick()
            }
            h.runtime.scheduler.launchIngestCompleted()
            await h.waitForFollowUpOrIdle()
            XCTAssertEqual(h.engine.count, 2, trigger + " must survive refusal of the retry it joined")
            if h.engine.count == 2 {
                XCTAssertEqual(h.engine.priorities.last, QOS_CLASS_DEFAULT,
                               "refused manual recovery cannot lend its priority to ordinary work")
                h.release.open()
            }
            await h.finish()
            XCTAssertEqual(h.engine.count, 2, trigger + " must run once")
        }
    }

    func assertRefusedRecoveryDoesNotCancelNudge() async throws {
        let h = try await makeSyncRecoveryHarness()
        h.runtime.scheduler.launchIngestCompleted()
        await h.waitForCycle(1)
        h.release.open()
        await h.waitForIdle()
        XCTAssertFalse(h.runtime.scheduler.hasPendingTrigger)
        // A stale recovery packet can reach the scheduler after usable evidence retired its retry.
        // Queue a real watcher nudge first. The refused packet cannot cover that mutation.
        h.runtime.scheduler.nudge()
        h.runtime.scheduler.enqueue(.manualRecovery)
        await h.waitForFollowUpOrIdle()
        XCTAssertEqual(h.engine.count, 2, "refusing a stale retry must leave the nudge able to start its own cycle")
        if h.engine.count == 2 {
            XCTAssertEqual(h.engine.priorities.last, QOS_CLASS_DEFAULT)
            h.release.open()
        }
        await h.finish()
        XCTAssertEqual(h.engine.count, 2, "the surviving nudge must run once")
    }

    func assertSpentRetryCannotRearmAfterDirectSync() async throws {
        let h = try await heldRecoveryBeforeIngest()
        let direct = Task { await h.runtime.syncModel.syncNowAndReport() }
        await h.waitForCycle(2)
        h.runtime.scheduler.launchIngestCompleted()
        await TestWait.until(failureMessage: "held recovery request did not return from the busy model") {
            !h.runtime.scheduler.isSyncing
        }
        h.release.open()
        await direct.value
        await h.waitForFollowUpOrIdle(after: 2)
        XCTAssertEqual(h.engine.count, 2, "direct Sync Now spent the retry before the busy-model hand-off")
        await h.finish()
        XCTAssertEqual(h.engine.count, 2, "a spent recovery request cannot re-arm itself")
    }
}
