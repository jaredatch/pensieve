import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryViewModelTests: XCTestCase {
    func testRequestPublishesLoadingReadsOffMainAndJoinsInFlightAsk() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let probe = LockedHistoryProbe()
        let expected = historyResult()
        let owner = historyOwner { _, _, _ in
            probe.recordCall()
            started.signal()
            try release.wait()
            return expected
        }
        let skill = installedHistorySkill()

        let first = Task { await owner.request(skill: skill) }
        let didStart = await waitForHistorySemaphore(started)
        XCTAssertTrue(didStart)
        XCTAssertEqual(owner.state, .loading)
        let second = Task { await owner.request(skill: skill) }
        await Task.yield()
        XCTAssertEqual(probe.calls, 1)

        release.open()
        await first.value
        await second.value

        XCTAssertEqual(owner.state, .loaded(expected))
        XCTAssertEqual(probe.calls, 1)
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testLoadedQuestionAnswersImmediatelyWithoutAnotherRead() async {
        let probe = LockedHistoryProbe()
        let expected = historyResult()
        let owner = historyOwner { _, _, _ in probe.recordCall(); return expected }
        let skill = installedHistorySkill()

        await owner.request(skill: skill)
        await owner.request(skill: skill)

        XCTAssertEqual(owner.state, .loaded(expected))
        XCTAssertEqual(probe.calls, 1)
    }

    func testLargerWindowReplacesHeldResultAndSmallerAskUsesIt() async {
        let lock = NSLock()
        var windows: [Int] = []
        let owner = historyOwner { _, _, windowCount in
            lock.lock()
            windows.append(windowCount)
            lock.unlock()
            let base = historyResult()
            return UpstreamHistoryResult(
                headCommit: base.headCommit,
                rows: base.rows,
                installedPosition: base.installedPosition,
                hasOlderHistory: windowCount < 2,
                installedBaseline: base.installedBaseline,
                localEdits: base.localEdits,
                windowCount: windowCount
            )
        }
        let skill = installedHistorySkill()

        await owner.request(skill: skill)
        await owner.request(skill: skill, windowCount: 2)
        await owner.request(skill: skill)

        guard case let .loaded(result) = owner.state else {
            return XCTFail("Expected a loaded result")
        }
        XCTAssertEqual(result.windowCount, 2)
        XCTAssertEqual(windows, [1, 2])
    }

    func testLocalRevisionRefreshesEditsWithoutAnotherRead() async {
        let readProbe = LockedHistoryProbe()
        let localProbe = LockedHistoryProbe()
        let changed = UpstreamHistoryLocalEdits.changed([UpstreamHistoryLocalChange(
            path: "SKILL.md",
            linesAdded: 1,
            linesRemoved: 0,
            installedText: "before",
            currentText: "after"
        )])
        let owner = historyOwner(
            read: { _, _, _ in readProbe.recordCall(); return historyResult() },
            localEdits: { _, _, _ in localProbe.recordCall(); return changed }
        )
        let skill = installedHistorySkill()

        await owner.request(skill: skill)
        await owner.request(
            skill: skill,
            localRevision: UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
        )

        guard case let .loaded(result) = owner.state else {
            return XCTFail("Expected a loaded result")
        }
        XCTAssertEqual(result.localEdits, changed)
        XCTAssertEqual(readProbe.calls, 1)
        XCTAssertEqual(localProbe.calls, 1)
        XCTAssertFalse(localProbe.ranOnMainThread)
    }

    func testFailureWaitsForAnotherAskThenRetriesOnce() async {
        enum Failure: LocalizedError {
            case offline
            var errorDescription: String? { "The repository couldn't be reached." }
        }
        let probe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in
            probe.recordCall()
            if probe.calls == 1 { throw Failure.offline }
            return historyResult()
        }
        let skill = installedHistorySkill()

        await owner.request(skill: skill)
        XCTAssertEqual(owner.state, .failed("The repository couldn't be reached."))
        await Task.yield()
        XCTAssertEqual(probe.calls, 1)

        await owner.request(skill: skill, intent: .retry)
        XCTAssertEqual(owner.state, .loaded(historyResult()))
        XCTAssertEqual(probe.calls, 2)
    }

    func testLoadedHeadRequestsOneUpdateCheckAndDoesNotWriteSkillState() async {
        let oldHead = String(repeating: "1", count: 40)
        let newHead = String(repeating: "2", count: 40)
        let skill = installedHistorySkill(recordedHead: oldHead)
        skill.updateAvailable = true
        skill.upstreamCommit = "upstream-before"
        skill.upstreamCommitDate = Date(timeIntervalSince1970: 1_600_000_000)
        let before = (
            skill.updateAvailable,
            skill.lastCheckedHead,
            skill.upstreamCommit,
            skill.upstreamCommitDate
        )
        let owner = historyOwner { _, _, _ in historyResult(head: newHead) }
        var checkRequests: [UUID] = []

        await owner.request(skill: skill, onUpdateCheck: { checkRequests.append($0) })
        await owner.request(skill: skill, onUpdateCheck: { checkRequests.append($0) })

        XCTAssertEqual(checkRequests, [skill.id])
        XCTAssertEqual(skill.updateAvailable, before.0)
        XCTAssertEqual(skill.lastCheckedHead, before.1)
        XCTAssertEqual(skill.upstreamCommit, before.2)
        XCTAssertEqual(skill.upstreamCommitDate, before.3)
    }

    func testRecordingTheHeadJustReadKeepsTheHeldResult() async {
        let newHead = String(repeating: "2", count: 40)
        let probe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in
            probe.recordCall()
            return historyResult(head: newHead)
        }
        let skill = installedHistorySkill(recordedHead: String(repeating: "1", count: 40))

        await owner.request(skill: skill)
        skill.lastCheckedHead = newHead
        await owner.request(skill: skill)

        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(owner.state, .loaded(historyResult(head: newHead)))
    }

    func testAuthoredAndImportedSkillsNeverReadUpstream() async {
        let probe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in probe.recordCall(); return historyResult() }
        let authored = Skill(name: "Authored", directoryName: "authored")
        let imported = Skill(name: "Imported", directoryName: "imported", importedFrom: "/tmp/source")

        await owner.request(skill: authored)
        await owner.request(skill: imported)

        XCTAssertEqual(owner.state, .idle)
        XCTAssertNil(owner.currentSkillID)
        XCTAssertEqual(probe.calls, 0)
    }
}
