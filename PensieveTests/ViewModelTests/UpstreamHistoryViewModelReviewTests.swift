import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryViewModelReviewTests: XCTestCase {
    private enum Failure: LocalizedError {
        case offline
        var errorDescription: String? { "The repository couldn't be reached." }
    }

    func testLocalRevisionOnlyReaskKeepsFailureWithoutRetrying() async {
        let probe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in
            probe.recordCall()
            throw Failure.offline
        }
        let skill = installedHistorySkill()
        let changed = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)

        await owner.request(skill: skill)
        await owner.request(skill: skill, localRevision: changed, intent: .mountedRefresh)

        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(owner.state, .failed("The repository couldn't be reached."))

        await owner.request(skill: skill, localRevision: changed, intent: .mountedRefresh)
        XCTAssertEqual(probe.calls, 1)
    }

    func testAppearanceRetriesHeldFailureAfterRevisionChanged() async {
        let probe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in
            probe.recordCall()
            if probe.calls == 1 { throw Failure.offline }
            return historyResult()
        }
        let skill = installedHistorySkill()

        await owner.request(skill: skill, intent: .appearance)
        let changed = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
        await owner.request(skill: skill, localRevision: changed, intent: .appearance)

        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(owner.state, .loaded(historyResult()))
    }

    func testFailedWiderReadKeepsNarrowRowsAndLocalRevisionDoesNotRetry() async {
        let probe = LockedHistoryProbe()
        let first = historyResult()
        let owner = historyOwner { _, _, windowCount in
            probe.recordCall()
            if windowCount > 1 { throw Failure.offline }
            return first
        }
        let skill = installedHistorySkill()

        await owner.request(skill: skill)
        await owner.request(skill: skill, windowCount: 2)

        XCTAssertEqual(
            owner.state,
            .loadedWithFailure(first, "History couldn't be refreshed. The repository couldn't be reached.")
        )
        let changed = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
        await owner.request(
            skill: skill,
            windowCount: 2,
            localRevision: changed,
            intent: .mountedRefresh
        )
        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(
            owner.state,
            .loadedWithFailure(first, "History couldn't be refreshed. The repository couldn't be reached.")
        )
    }

    func testSuccessfulCompletionAfterSkillSwitchIsHeldForReturn() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = TestWait.Gate(owner: self)
        let probe = LockedHistoryProbe()
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let firstResult = historyResult(head: String(repeating: "1", count: 40))
        let secondResult = historyResult(head: String(repeating: "2", count: 40))
        let owner = historyOwner { origin, _, _ in
            probe.recordCall()
            if origin.installedCommit == first.installedOrigin?.installedCommit {
                firstStarted.signal()
                try releaseFirst.wait()
                return firstResult
            }
            return secondResult
        }

        let pendingFirst = Task { await owner.request(skill: first) }
        let didStart = await waitForHistorySemaphore(firstStarted)
        XCTAssertTrue(didStart)
        await owner.request(skill: second)
        releaseFirst.open()
        await pendingFirst.value

        await owner.request(skill: first)

        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(owner.state, .loaded(firstResult))
    }
}
