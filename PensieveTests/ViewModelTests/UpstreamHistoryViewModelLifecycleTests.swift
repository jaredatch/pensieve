import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryViewModelLifecycleTests: XCTestCase {
    func testManualCheckDuringReadDiscardsItAndNextAskStartsFreshRead() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = TestWait.Gate(owner: self)
        let probe = LockedHistoryProbe()
        let firstResult = historyResult(head: String(repeating: "1", count: 40))
        let secondResult = historyResult(head: String(repeating: "2", count: 40))
        let owner = historyOwner { _, _, _ in
            probe.recordCall()
            if probe.calls == 1 {
                firstStarted.signal()
                try releaseFirst.wait()
                return firstResult
            }
            return secondResult
        }
        let skill = installedHistorySkill()

        let first = Task { await owner.request(skill: skill) }
        let didStart = await waitForHistorySemaphore(firstStarted)
        XCTAssertTrue(didStart)
        owner.invalidateForManualCheck(skillID: skill.id)
        await owner.request(skill: skill)
        XCTAssertEqual(owner.state, .loaded(secondResult))

        releaseFirst.open()
        await first.value

        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(owner.state, .loaded(secondResult))
    }

    func testEveryQuestionChangingInputAndExplicitEvictionRunsANewRead() async throws {
        let probe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in
            probe.recordCall()
            return historyResult(head: String(format: "%040x", probe.calls))
        }
        let skill = installedHistorySkill(recordedHead: String(format: "%040x", 1))

        await owner.request(skill: skill)

        var origin = try XCTUnwrap(skill.installedOrigin)
        origin.installedCommit = String(repeating: "c", count: 40)
        skill.installedOrigin = origin
        await owner.request(skill: skill)

        origin.repo = "https://github.com/example/other"
        origin.path = "skills/other"
        origin.ref = "stable"
        skill.installedOrigin = origin
        await owner.request(skill: skill)

        skill.lastCheckedHead = String(repeating: "d", count: 40)
        await owner.request(skill: skill)

        owner.invalidateForManualCheck(skillID: skill.id)
        await owner.request(skill: skill)

        owner.remove(skillID: skill.id)
        await owner.request(skill: skill)

        XCTAssertEqual(probe.calls, 6)
    }

    func testCompletionAfterMovingToAnotherSkillIsDiscarded() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = TestWait.Gate(owner: self)
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let firstResult = historyResult(head: String(repeating: "1", count: 40))
        let secondResult = historyResult(head: String(repeating: "2", count: 40))
        let owner = historyOwner { origin, _, _ in
            if origin.installedCommit == first.installedOrigin?.installedCommit {
                firstStarted.signal()
                try releaseFirst.wait()
                return firstResult
            }
            return secondResult
        }

        let pendingFirst = Task { await owner.request(skill: first) }
        let didStartFirst = await waitForHistorySemaphore(firstStarted)
        XCTAssertTrue(didStartFirst)
        await owner.request(skill: second)
        XCTAssertEqual(owner.state, .loaded(secondResult))

        releaseFirst.open()
        await pendingFirst.value

        XCTAssertEqual(owner.currentSkillID, second.id)
        XCTAssertEqual(owner.state, .loaded(secondResult))
    }

    func testCompletionAfterMovingToAuthoredSkillIsDiscarded() async {
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let probe = LockedHistoryProbe()
        let installed = installedHistorySkill()
        let authored = Skill(name: "Authored", directoryName: "authored")
        let owner = historyOwner { _, _, _ in
            probe.recordCall()
            readStarted.signal()
            try releaseRead.wait()
            return historyResult()
        }

        let pending = Task { await owner.request(skill: installed) }
        let didStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(didStart)
        await owner.request(skill: authored)
        XCTAssertEqual(owner.state, .idle)

        releaseRead.open()
        await pending.value

        XCTAssertEqual(probe.calls, 1)
        XCTAssertNil(owner.currentSkillID)
        XCTAssertEqual(owner.state, .idle)
    }

    func testCompletionAfterOriginMovesIsDiscarded() async throws {
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = TestWait.Gate(owner: self)
        let oldCommit = String(repeating: "a", count: 40)
        let newCommit = String(repeating: "c", count: 40)
        let oldResult = historyResult(head: String(repeating: "1", count: 40))
        let newResult = historyResult(head: String(repeating: "2", count: 40))
        let skill = installedHistorySkill(commit: oldCommit)
        let owner = historyOwner { origin, _, _ in
            if origin.installedCommit == oldCommit {
                oldStarted.signal()
                try releaseOld.wait()
                return oldResult
            }
            return newResult
        }

        let pendingOld = Task { await owner.request(skill: skill) }
        let didStartOld = await waitForHistorySemaphore(oldStarted)
        XCTAssertTrue(didStartOld)
        var moved = try XCTUnwrap(skill.installedOrigin)
        moved.installedCommit = newCommit
        skill.installedOrigin = moved
        await owner.request(skill: skill)
        XCTAssertEqual(owner.state, .loaded(newResult))

        releaseOld.open()
        await pendingOld.value

        XCTAssertEqual(owner.state, .loaded(newResult))
    }
}
