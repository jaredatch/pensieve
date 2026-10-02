import XCTest
@testable import Pensieve

private enum RefreshConcurrencyFailure: LocalizedError {
    case offline
    var errorDescription: String? { "The repository couldn't be reached." }
}

@MainActor
extension UpstreamHistoryRefreshTests {
    /// Protects PLAN-35's lifecycle contract: a manual check replaces a running first read immediately.
    func testManualCheckDuringVisibleFirstReadStartsOneFreshReadImmediately() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = TestWait.Gate(owner: self)
        let secondStarted = DispatchSemaphore(value: 0)
        let readProbe = LockedHistoryProbe()
        let firstResult = historyResult(head: String(repeating: "1", count: 40))
        let secondResult = historyResult(head: String(repeating: "2", count: 40))
        let owner = historyOwner { _, _, _ in
            readProbe.recordCall()
            if readProbe.calls == 1 {
                firstStarted.signal()
                try releaseFirst.wait()
                return firstResult
            }
            secondStarted.signal()
            return secondResult
        }
        let skill = installedHistorySkill()

        let first = Task { await owner.request(skill: skill) }
        let firstDidStart = await waitForHistorySemaphore(firstStarted)
        XCTAssertTrue(firstDidStart)
        XCTAssertEqual(owner.state, .loading)

        owner.invalidateForManualCheck(skillID: skill.id)
        let manual = Task { await owner.request(skill: skill, intent: .retry) }
        let freshReadDidStart = await waitForHistorySemaphore(secondStarted)
        XCTAssertTrue(freshReadDidStart)
        await manual.value

        XCTAssertEqual(readProbe.calls, 2)
        XCTAssertEqual(owner.state, .loaded(secondResult))
        releaseFirst.open()
        await first.value
        XCTAssertEqual(owner.state, .loaded(secondResult))
    }

    /// Protects 39.2-f: Check for Updates adds no first History fetch when nothing is kept.
    func testManualCheckWithNoKeptResultDoesNotStartAHistoryFetchOrLeak() async {
        let readProbe = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in readProbe.recordCall(); return historyResult() }
        let skill = installedHistorySkill()

        owner.invalidateForManualCheck(skillID: skill.id)

        XCTAssertEqual(readProbe.calls, 0)
        await owner.request(skill: skill, intent: .appearance)
        XCTAssertEqual(readProbe.calls, 1)
        XCTAssertEqual(owner.state, .loaded(historyResult()))
    }

    /// Protects 39.2-f: Check for Updates keeps the widest open window and paging can advance afterward.
    func testManualCheckPreservesExpandedWindowAndShowOlderStillAdvances() async throws {
        let old = historyResultWithWindow(3, head: String(repeating: "1", count: 40))
        let refreshed = historyResultWithWindow(3, head: String(repeating: "2", count: 40))
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        let readProbe = LockedHistoryProbe()
        let owner = historyOwner { _, _, window in
            readProbe.recordCall()
            XCTAssertEqual(window, 3)
            return refreshed
        }
        try hold(old, for: skill, in: owner)

        owner.invalidateForManualCheck(skillID: skill.id)
        await owner.request(skill: skill, windowCount: 3, intent: .retry)

        XCTAssertEqual(readProbe.calls, 1)
        XCTAssertEqual(owner.state, .loaded(refreshed))
        let session = InstalledSkillHistorySession()
        session.requestedWindow = 3
        session.showOlder(.readNextWindow, currentWindow: refreshed.windowCount)
        XCTAssertEqual(session.requestedWindow, 4)
    }

    /// Protects 39.2-k and 39.2-b: a switched-away probe is reusable and never duplicates in flight.
    func testSwitchDuringProbeReopensAndRefreshesTheFirstSkill() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let newHead = String(repeating: "2", count: 40)
        let first = installedHistorySkill(name: "First", recordedHead: oldHead)
        let second = installedHistorySkill(
            name: "Second",
            commit: String(repeating: "c", count: 40),
            recordedHead: String(repeating: "3", count: 40)
        )
        let firstOld = historyResult(head: oldHead)
        let secondResult = historyResult(head: String(repeating: "3", count: 40))
        let firstNew = historyResult(head: newHead)
        let firstProbeStarted = DispatchSemaphore(value: 0)
        let releaseFirstProbe = TestWait.Gate(owner: self)
        let firstHeadProbe = LockedHistoryProbe()
        let readProbe = LockedHistoryProbe()
        let owner = historyOwner(
            read: { origin, _, _ in
                readProbe.recordCall()
                return origin.installedCommit == first.installedOrigin?.installedCommit ? firstNew : secondResult
            },
            head: { origin in
                if origin.installedCommit == first.installedOrigin?.installedCommit {
                    firstHeadProbe.recordCall()
                    if firstHeadProbe.calls == 1 {
                        firstProbeStarted.signal()
                        try releaseFirstProbe.wait()
                    }
                    return newHead
                }
                return secondResult.headCommit
            }
        )
        try hold(firstOld, for: first, in: owner)
        try hold(secondResult, for: second, in: owner)

        let pendingFirst = Task { await owner.request(skill: first) }
        let firstProbeDidStart = await waitForHistorySemaphore(firstProbeStarted)
        XCTAssertTrue(firstProbeDidStart)
        await owner.request(skill: second)
        XCTAssertEqual(owner.state, .loaded(secondResult))
        releaseFirstProbe.open()
        await pendingFirst.value

        await owner.request(skill: first)

        XCTAssertEqual(firstHeadProbe.calls, 1)
        XCTAssertEqual(readProbe.calls, 1)
        XCTAssertEqual(owner.state, .loaded(firstNew))
    }

    /// Protects 39.2-c and 39.2-d: a probe failure publishes the latest local-edit measurement.
    func testProbeFailureDoesNotUndoLocalEditsMeasuredWhileProbeWasRunning() async throws {
        let old = historyResult(head: String(repeating: "1", count: 40))
        let changed = historyResult(
            head: old.headCommit,
            localEdits: .changed([UpstreamHistoryLocalChange(
                path: "SKILL.md",
                linesAdded: 1,
                linesRemoved: 0,
                installedText: "before",
                currentText: "after"
            )])
        )
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = TestWait.Gate(owner: self)
        let owner = historyOwner(
            read: { _, _, _ in old },
            head: { _ in
                probeStarted.signal()
                try releaseProbe.wait()
                throw RefreshConcurrencyFailure.offline
            },
            localEdits: { _, _, _ in changed.localEdits }
        )
        try hold(old, for: skill, in: owner)

        let first = Task { await owner.request(skill: skill) }
        let probeDidStart = await waitForHistorySemaphore(probeStarted)
        XCTAssertTrue(probeDidStart)
        let localRefresh = Task {
            await owner.request(
                skill: skill,
                localRevision: UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        releaseProbe.open()
        await first.value
        await localRefresh.value

        guard case let .loadedWithFailure(result, _) = owner.state else {
            return XCTFail("Expected kept rows with refresh failure")
        }
        XCTAssertEqual(result.localEdits, changed.localEdits)
    }

    /// Protects 39.2-c: a joined read that did not ask the remounted question refreshes again.
    func testJoinedRefreshUsesItsOwnQuestionAndRefreshesTheRecordedRemountHead() async throws {
        let originalHead = String(repeating: "1", count: 40)
        let recordedHead = String(repeating: "2", count: 40)
        let staleReadHead = String(repeating: "3", count: 40)
        let old = historyResult(head: originalHead)
        let stale = historyResult(head: staleReadHead)
        let refreshed = historyResult(head: recordedHead)
        let skill = installedHistorySkill(recordedHead: originalHead)
        let firstReadStarted = DispatchSemaphore(value: 0)
        let releaseFirstRead = TestWait.Gate(owner: self)
        let secondReadStarted = DispatchSemaphore(value: 0)
        let releaseSecondRead = TestWait.Gate(owner: self)
        let reads = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in
            reads.recordCall()
            if reads.calls == 1 {
                firstReadStarted.signal()
                try releaseFirstRead.wait()
                return stale
            }
            secondReadStarted.signal()
            try releaseSecondRead.wait()
            return refreshed
        }
        try hold(old, for: skill, in: owner)
        owner.invalidateForManualCheck(skillID: skill.id)

        let refresh = Task { await owner.request(skill: skill, intent: .retry) }
        let readDidStart = await waitForHistorySemaphore(firstReadStarted)
        XCTAssertTrue(readDidStart)
        skill.lastCheckedHead = recordedHead
        let remount = Task { await owner.request(skill: skill, intent: .mountedRefresh) }

        XCTAssertEqual(owner.state, .refreshing(old))
        releaseFirstRead.open()
        let secondDidStart = await waitForHistorySemaphore(secondReadStarted)
        XCTAssertTrue(secondDidStart)
        XCTAssertTrue(owner.held.values.contains {
            $0.recordedHeadAtRead == originalHead && $0.readHead == staleReadHead
        })
        XCTAssertFalse(owner.held.values.contains {
            $0.recordedHeadAtRead == recordedHead && $0.readHead == staleReadHead
        })
        XCTAssertEqual(owner.state, .refreshing(stale))
        releaseSecondRead.open()
        await refresh.value
        await remount.value

        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(owner.state, .loaded(refreshed))
    }

    /// Protects 39.2-d: every request joined to a failed refresh publishes the failure it awaited.
    func testJoinedRefreshFailurePublishesForTheRecordedHeadRemount() async throws {
        let originalHead = String(repeating: "1", count: 40)
        let recordedHead = String(repeating: "2", count: 40)
        let old = historyResult(head: originalHead)
        let skill = installedHistorySkill(recordedHead: originalHead)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let reads = LockedHistoryProbe()
        let owner = historyOwner { _, _, _ in
            reads.recordCall()
            readStarted.signal()
            try releaseRead.wait()
            throw RefreshConcurrencyFailure.offline
        }
        try hold(old, for: skill, in: owner)
        owner.invalidateForManualCheck(skillID: skill.id)

        let refresh = Task { await owner.request(skill: skill, intent: .retry) }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        skill.lastCheckedHead = recordedHead
        let remount = Task { await owner.request(skill: skill, intent: .mountedRefresh) }

        XCTAssertEqual(owner.state, .refreshing(old))
        releaseRead.open()
        await refresh.value
        await remount.value

        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(
            owner.state,
            .loadedWithFailure(old, "History couldn't be refreshed. The repository couldn't be reached.")
        )
        XCTAssertTrue(owner.failures.keys.contains {
            $0.request.recordedHead == recordedHead && $0.windowCount == 1
        })
    }

    /// Protects 39.2-d: a failure cannot attach to a current question that never joined its read.
    func testRefreshFailureDoesNotReplaceRowsThatAlreadyAnswerTheCurrentHead() async throws {
        let originalHead = String(repeating: "1", count: 40)
        let refreshingHead = String(repeating: "2", count: 40)
        let keptHead = String(repeating: "3", count: 40)
        let kept = historyResult(head: keptHead)
        let skill = installedHistorySkill(recordedHead: originalHead)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let owner = historyOwner { _, _, _ in
            readStarted.signal()
            try releaseRead.wait()
            throw RefreshConcurrencyFailure.offline
        }
        try hold(kept, for: skill, recordedHeadAtRead: originalHead, in: owner)
        skill.lastCheckedHead = refreshingHead

        let refresh = Task { await owner.request(skill: skill, intent: .retry) }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        skill.lastCheckedHead = keptHead
        await owner.request(skill: skill, intent: .mountedRefresh)

        XCTAssertEqual(owner.state, .loaded(kept))
        releaseRead.open()
        await refresh.value

        XCTAssertEqual(owner.state, .loaded(kept))
        XCTAssertFalse(owner.failures.keys.contains { $0.request.recordedHead == keptHead })
        XCTAssertTrue(owner.failures.keys.contains { $0.request.recordedHead == refreshingHead })
    }

    /// Protects 39.2-d and 39.2-k: a failed read is held and shown only for its originating skill.
    func testFailedReadAfterSkillSwitchDoesNotAttachToTheCurrentSkill() async throws {
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(
            name: "Second",
            commit: String(repeating: "c", count: 40),
            recordedHead: String(repeating: "d", count: 40)
        )
        let secondResult = historyResult(head: String(repeating: "d", count: 40))
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = TestWait.Gate(owner: self)
        let owner = historyOwner { origin, _, _ in
            if origin.installedCommit == first.installedOrigin?.installedCommit {
                firstStarted.signal()
                try releaseFirst.wait()
                throw RefreshConcurrencyFailure.offline
            }
            return secondResult
        }
        try hold(secondResult, for: second, in: owner)
        owner.probedSkillIDs.insert(second.id)

        let pendingFirst = Task { await owner.request(skill: first) }
        let firstDidStart = await waitForHistorySemaphore(firstStarted)
        XCTAssertTrue(firstDidStart)
        await owner.request(skill: second)
        releaseFirst.open()
        await pendingFirst.value

        XCTAssertEqual(owner.state, .loaded(secondResult))
        XCTAssertTrue(owner.failures.keys.allSatisfy { $0.request.skillID == first.id })
    }
}
