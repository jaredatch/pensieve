import XCTest
@testable import Pensieve

@MainActor
extension UpstreamHistoryRefreshTests {
    /// Protects 39.2-c: every appearance ask keeps the Updating note while its refresh is in flight.
    func testAppearanceDuringRefreshKeepsRefreshingState() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let newHead = String(repeating: "2", count: 40)
        let old = historyResult(head: oldHead)
        let new = historyResult(head: newHead)
        let skill = installedHistorySkill(recordedHead: oldHead)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let owner = historyOwner(
            read: { _, _, _ in
                readStarted.signal()
                try releaseRead.wait()
                return new
            },
            head: { _ in newHead }
        )
        try hold(old, for: skill, in: owner)

        let refresh = Task { await owner.request(skill: skill) }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        await owner.request(skill: skill, intent: .appearance)

        XCTAssertEqual(owner.state, .refreshing(old))
        releaseRead.open()
        await refresh.value
        XCTAssertEqual(owner.state, .loaded(new))
    }

    /// Protects 39.2-f: a manual refresh and a recorded-head remount join one History fetch.
    func testManualRefreshJoinsRecordedHeadRemountAndFetchesOnce() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let newHead = String(repeating: "2", count: 40)
        let old = historyResult(head: oldHead)
        let new = historyResult(head: newHead)
        let skill = installedHistorySkill(recordedHead: oldHead)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let readProbe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in
            readProbe.recordCall()
            readStarted.signal()
            try releaseRead.wait()
            return new
        }
        try hold(old, for: skill, in: owner)
        owner.invalidateForManualCheck(skillID: skill.id)

        let manual = Task { await owner.request(skill: skill, intent: .appearance) }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        skill.lastCheckedHead = newHead
        let remount = Task { await owner.request(skill: skill, intent: .mountedRefresh) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(readProbe.calls, 1)
        XCTAssertEqual(owner.state, .refreshing(old))
        releaseRead.open()
        await manual.value
        await remount.value
        XCTAssertEqual(readProbe.calls, 1)
        XCTAssertEqual(owner.state, .loaded(new))
    }
}
