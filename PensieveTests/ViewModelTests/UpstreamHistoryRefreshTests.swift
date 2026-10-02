import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryRefreshTests: XCTestCase {
    private enum Failure: LocalizedError {
        case offline
        var errorDescription: String? { "The repository couldn't be reached." }
    }

    func testHeldRowsShowBeforeOneProbeFinishesAndSecondOpenDoesNoNetworkWork() async throws {
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = TestWait.Gate(owner: self)
        let headProbe = LockedHistoryProbe()
        let readProbe = LockedHistoryProbe()
        let kept = historyResult()
        let skill = installedHistorySkill(recordedHead: kept.headCommit)
        let owner = historyOwner(
            read: { _, _, _ in readProbe.recordCall(); return kept },
            head: { _ in
                headProbe.recordCall()
                probeStarted.signal()
                try releaseProbe.wait()
                return kept.headCommit
            }
        )
        try hold(kept, for: skill, in: owner)

        let firstOpen = Task { await owner.request(skill: skill) }
        let probeDidStart = await waitForHistorySemaphore(probeStarted)
        XCTAssertTrue(probeDidStart)
        XCTAssertEqual(owner.state, .loaded(kept))
        XCTAssertEqual(readProbe.calls, 0)

        releaseProbe.open()
        await firstOpen.value
        await owner.request(skill: skill)

        XCTAssertEqual(owner.state, .loaded(kept))
        XCTAssertEqual(headProbe.calls, 1)
        XCTAssertEqual(readProbe.calls, 0)
    }

    func testNewProbeHeadKeepsRowsDuringRefreshAndRequestsOneUpdateCheck() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let newHead = String(repeating: "2", count: 40)
        let old = historyResult(head: oldHead)
        let new = historyResult(head: newHead)
        let skill = installedHistorySkill(recordedHead: oldHead)
        skill.updateAvailable = false
        skill.upstreamCommit = "before"
        let before = (skill.updateAvailable, skill.lastCheckedHead, skill.upstreamCommit)
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
        var updateChecks: [UUID] = []

        let request = Task {
            await owner.request(skill: skill, onUpdateCheck: { updateChecks.append($0) })
        }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        XCTAssertEqual(owner.state, .refreshing(old))

        releaseRead.open()
        await request.value

        XCTAssertEqual(owner.state, .loaded(new))
        XCTAssertEqual(updateChecks, [skill.id])
        XCTAssertEqual(skill.updateAvailable, before.0)
        XCTAssertEqual(skill.lastCheckedHead, before.1)
        XCTAssertEqual(skill.upstreamCommit, before.2)
    }

    /// Protects 39.2-c: a head already recorded by the skill requests no redundant update check.
    func testRecordedNewHeadRefreshesWithoutAProbe() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let newHead = String(repeating: "2", count: 40)
        let old = historyResult(head: oldHead)
        let new = historyResult(head: newHead)
        let skill = installedHistorySkill(recordedHead: newHead)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let headProbe = LockedHistoryProbe()
        let owner = historyOwner(
            read: { _, _, _ in
                readStarted.signal()
                try releaseRead.wait()
                return new
            },
            head: { _ in headProbe.recordCall(); return newHead }
        )
        try hold(old, for: skill, recordedHeadAtRead: oldHead, in: owner)

        var updateChecks: [UUID] = []
        let request = Task {
            await owner.request(skill: skill, onUpdateCheck: { updateChecks.append($0) })
        }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart, "recorded-head refresh did not start")
        XCTAssertEqual(owner.state, .refreshing(old))
        XCTAssertEqual(headProbe.calls, 0)

        releaseRead.open()
        await request.value
        XCTAssertEqual(owner.state, .loaded(new))
        XCTAssertTrue(updateChecks.isEmpty, "recorded current head requested \(updateChecks.count) update checks")
    }

    func testProbeFailureKeepsRowsAndRetryStartsRefreshWithoutAnotherProbe() async throws {
        let old = historyResult(head: String(repeating: "1", count: 40))
        let new = historyResult(head: String(repeating: "2", count: 40))
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let headProbe = LockedHistoryProbe()
        let owner = historyOwner(
            read: { _, _, _ in
                readStarted.signal()
                try releaseRead.wait()
                return new
            },
            head: { _ in headProbe.recordCall(); throw Failure.offline }
        )
        try hold(old, for: skill, in: owner)

        await owner.request(skill: skill)

        XCTAssertEqual(
            owner.state,
            .loadedWithFailure(old, "History couldn't be refreshed. The repository couldn't be reached.")
        )
        let retry = Task { await owner.request(skill: skill, intent: .retry) }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        XCTAssertEqual(owner.state, .refreshing(old))

        releaseRead.open()
        await retry.value
        XCTAssertEqual(owner.state, .loaded(new))
        XCTAssertEqual(headProbe.calls, 1)
    }

    func testWiderReadKeepsNarrowRowsUntilItFinishes() async throws {
        let narrow = historyResultWithWindow(1)
        let wide = historyResultWithWindow(2)
        let skill = installedHistorySkill(recordedHead: narrow.headCommit)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let owner = historyOwner { _, _, window in
            XCTAssertEqual(window, 2)
            readStarted.signal()
            try releaseRead.wait()
            return wide
        }
        try hold(narrow, for: skill, in: owner)
        owner.probedSkillIDs.insert(skill.id)

        let request = Task { await owner.request(skill: skill, windowCount: 2) }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        XCTAssertEqual(owner.state, .refreshing(narrow))

        releaseRead.open()
        await request.value
        XCTAssertEqual(owner.state, .loaded(wide))
    }

    func testManualCheckKeepsRowsWhileItRefreshes() async throws {
        let old = historyResult(head: String(repeating: "1", count: 40))
        let new = historyResult(head: String(repeating: "2", count: 40))
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let owner = historyOwner { _, _, _ in
            readStarted.signal()
            try releaseRead.wait()
            return new
        }
        try hold(old, for: skill, in: owner)
        owner.invalidateForManualCheck(skillID: skill.id)

        let request = Task { await owner.request(skill: skill, intent: .retry) }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        XCTAssertEqual(owner.state, .refreshing(old))

        releaseRead.open()
        await request.value
        XCTAssertEqual(owner.state, .loaded(new))
    }

    /// Protects 39.2-c: a fresh narrow head replaces every wider row set held for the old head.
    func testFreshNarrowHeadStillAnswersTheThirdRequestAfterAWiderOldHead() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let newHead = String(repeating: "2", count: 40)
        let old = historyResultWithWindow(2, head: oldHead)
        let new = historyResultWithWindow(1, head: newHead)
        let skill = installedHistorySkill(recordedHead: oldHead)
        let readProbe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in readProbe.recordCall(); return new }
        try hold(old, for: skill, in: owner)
        owner.probedSkillIDs.insert(skill.id)

        skill.lastCheckedHead = newHead
        await owner.request(skill: skill)
        await owner.request(skill: skill)

        XCTAssertEqual(readProbe.calls, 1)
        XCTAssertEqual(owner.state, .loaded(new))
    }
}

@MainActor
extension UpstreamHistoryRefreshTests {
    func hold(
        _ result: UpstreamHistoryResult,
        for skill: Skill,
        recordedHeadAtRead: String? = nil,
        in owner: UpstreamHistoryViewModel
    ) throws {
        let origin = try XCTUnwrap(skill.installedOrigin)
        let originKey = UpstreamHistoryViewModel.OriginKey(origin: origin)
        let recordedHead = recordedHeadAtRead ?? skill.lastCheckedHead
        let request = UpstreamHistoryViewModel.RequestKey(
            skillID: skill.id,
            origin: originKey,
            recordedHead: recordedHead
        )
        owner.held[UpstreamHistoryViewModel.ReadKey(
            request: request,
            windowCount: result.windowCount
        )] = UpstreamHistoryViewModel.HeldResult(
            origin: originKey,
            recordedHeadAtRead: recordedHead,
            readHead: result.headCommit,
            result: result,
            localRevision: .initial
        )
    }

    func historyResultWithWindow(
        _ window: Int,
        head: String = String(repeating: "b", count: 40)
    ) -> UpstreamHistoryResult {
        let base = historyResult(head: head)
        return UpstreamHistoryResult(
            headCommit: base.headCommit,
            rows: base.rows,
            installedPosition: base.installedPosition,
            hasOlderHistory: window == 1,
            installedBaseline: base.installedBaseline,
            localEdits: base.localEdits,
            windowCount: window
        )
    }
}
