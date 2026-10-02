import XCTest
@testable import Pensieve

extension SyncCoordinatorTests {
    func testTriggersCoalesce() async {
        let firstStarted = expectation(description: "first started")
        let followupFinished = expectation(description: "one follow-up")
        let release = AsyncGate()
        var cycles = 0
        let scheduler = makeCoalescingScheduler(debounceSeconds: 0.2) {
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
        await fulfillment(of: [firstStarted], timeout: 1)
        scheduler.nudge()
        scheduler.tick()
        scheduler.wake()
        await release.open()
        await fulfillment(of: [followupFinished], timeout: 1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(cycles, 2)
    }

    func testManualSyncDuringScheduledCycleCoalesces() async {
        let firstStarted = expectation(description: "scheduled cycle started")
        let followupFinished = expectation(description: "queued follow-up finished")
        let release = AsyncGate()
        let model = SyncModel()
        let scheduler = makeCoalescingScheduler { await model.syncScheduledAndReport() }
        var cycles = 0
        var activeCycles = 0
        var maximumActiveCycles = 0
        var beginCount = 0
        var finishCount = 0
        model.installPendingSyncRequest { scheduler.enqueueManualTrigger() }
        model.installPendingScheduledSyncRequest { scheduler.enqueueTrigger() }
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
        await fulfillment(of: [firstStarted], timeout: 1)
        await model.syncNowAndReport()
        await release.open()
        await fulfillment(of: [followupFinished], timeout: 1)

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
        scheduler.installDrain { await model.syncScheduledAndReport() }
        model.installPendingSyncRequest { scheduler.enqueueManualTrigger() }
        model.installPendingScheduledSyncRequest { scheduler.enqueueTrigger() }
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
        await fulfillment(of: [firstStarted], timeout: 1)
        await model.syncNowAndReport()
        await release.open()
        await first.value
        await fulfillment(of: [followupFinished], timeout: 1)

        XCTAssertEqual(cycles, 2)
    }

    private func makeCoalescingScheduler(
        debounceSeconds: TimeInterval = 0,
        action: @escaping () async -> Void
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
