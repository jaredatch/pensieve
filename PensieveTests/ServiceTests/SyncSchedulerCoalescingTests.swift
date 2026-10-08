import XCTest
@testable import Pensieve

extension SyncCoordinatorTests {
    func testLaunchPreflightBypassEndsAfterAdmissionOrRefusal() async {
        for (scenario, remote, conflicted) in [("started", true, false), ("no remote", false, false),
                                              ("conflicted", true, true)] {
            var hasRemote = remote
            var isConflicted = conflicted
            var cycles = 0
            let scheduler = SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false })
            scheduler.installDrain(hasRemote: { hasRemote }, isConflicted: { isConflicted }, action: { _ in cycles += 1 })
            scheduler.coordinatorBecameReady()
            scheduler.launchIngestCompleted()
            scheduler.enqueueLaunchPreflight()
            await TestWait.until(failureMessage: "\(scenario): preflight did not finish") { !scheduler.isSyncing }
            let expectedCycles = remote && !conflicted ? 1 : 0
            XCTAssertEqual(cycles, expectedCycles, scenario)
            XCTAssertFalse(scheduler.hasPendingTrigger, scenario)

            hasRemote = true
            isConflicted = false
            scheduler.tick()
            scheduler.wake()
            XCTAssertFalse(scheduler.isSyncing, "\(scenario): later background work must respect background sync off")
            await TestWait.until(failureMessage: "\(scenario): unexpected background cycle did not finish") {
                !scheduler.isSyncing
            }
            XCTAssertEqual(cycles, expectedCycles, "\(scenario): preflight must not leave a preference bypass")
        }
    }

    func testTriggersCoalesce() async {
        let firstStarted = expectation(description: "first started")
        let followupFinished = expectation(description: "one follow-up")
        let release = AsyncGate()
        var cycles = 0
        let scheduler = makeCoalescingScheduler(debounceSeconds: 0.2) { _ in
            cycles += 1
            if cycles == 1 {
                firstStarted.fulfill()
                await release.wait()
            } else if cycles == 2 {
                followupFinished.fulfill()
            }
        }
        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        await fulfillment(of: [firstStarted], timeout: TestWait.hostedActionTimeoutSeconds)
        scheduler.nudge()
        scheduler.tick()
        scheduler.wake()
        await release.open()
        await fulfillment(of: [followupFinished], timeout: TestWait.hostedActionTimeoutSeconds)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(cycles, 2)
    }

    func testManualSyncDuringScheduledCycleCoalesces() async {
        let firstStarted = expectation(description: "scheduled cycle started")
        let followupFinished = expectation(description: "queued follow-up finished")
        let release = AsyncGate()
        let model = SyncModel()
        let scheduler = makeCoalescingScheduler { await model.syncAndReport($0) }
        var cycles = 0
        var activeCycles = 0
        var maximumActiveCycles = 0
        var beginCount = 0
        var finishCount = 0
        model.installPendingSyncRequest { scheduler.enqueue($0) }
        model.installSyncRequest {
            cycles += 1
            activeCycles += 1
            beginCount += 1
            maximumActiveCycles = max(maximumActiveCycles, activeCycles)
            if cycles == 1 {
                firstStarted.fulfill()
                await release.wait()
            }
            activeCycles -= 1
            finishCount += 1
            if cycles == 2 { followupFinished.fulfill() }
        }

        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        await fulfillment(of: [firstStarted], timeout: TestWait.hostedActionTimeoutSeconds)
        await model.syncNowAndReport()
        await release.open()
        await fulfillment(of: [followupFinished], timeout: TestWait.hostedActionTimeoutSeconds)

        XCTAssertEqual(cycles, 2)
        XCTAssertEqual(maximumActiveCycles, 1)
        XCTAssertEqual(beginCount, 2)
        XCTAssertEqual(finishCount, 2)
    }

    func testQueuedManualSyncIgnoresBackgroundPreference() async {
        let firstStarted = expectation(description: "first manual cycle started")
        let followupFinished = expectation(description: "manual follow-up finished")
        let release = AsyncGate()
        let model = SyncModel()
        let scheduler = SyncScheduler(
            debounceSeconds: 0,
            startAutomatically: false,
            backgroundSyncEnabled: { false }
        )
        scheduler.installDrain { await model.syncAndReport($0) }
        model.installPendingSyncRequest { scheduler.enqueue($0) }
        var cycles = 0
        model.installSyncRequest {
            cycles += 1
            if cycles == 1 {
                firstStarted.fulfill()
                await release.wait()
            } else if cycles == 2 {
                followupFinished.fulfill()
            }
        }

        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        let first = Task { await model.syncNowAndReport() }
        await fulfillment(of: [firstStarted], timeout: TestWait.hostedActionTimeoutSeconds)
        await model.syncNowAndReport()
        await release.open()
        await first.value
        await fulfillment(of: [followupFinished], timeout: TestWait.hostedActionTimeoutSeconds)

        XCTAssertEqual(cycles, 2)
    }

    private func makeCoalescingScheduler(
        debounceSeconds: TimeInterval = 0,
        action: @escaping (SyncRequest) async -> Void
    ) -> SyncScheduler {
        let scheduler = SyncScheduler(
            debounceSeconds: debounceSeconds,
            startAutomatically: false,
            backgroundSyncEnabled: { true }
        )
        scheduler.installDrain(action: action)
        return scheduler
    }
}
