import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryManualCheckTests: UpstreamHistoryCacheTestCase {
    /// Protects 39.2-g: a manual ask during a pending first disk miss starts one normal first read.
    func testManualCheckDuringPendingFirstDiskMissCannotLeaveLoadingWithoutARead() async throws {
        let skill = installedHistorySkill()
        let blocking = BlockingReadHistoryFileService(base: fileService, owner: self)
        try fileService.writeFile(at: cachePath(skill.id), content: "not json")
        blocking.blockNextRead(at: cachePath(skill.id))
        let reads = LockedHistoryProbe()
        let loaded = result(subject: "loaded")
        let model = owner(cache: cache(fileService: blocking)) { _, _, _ in
            reads.recordCall()
            return loaded
        }

        let firstOpen = Task { await model.request(skill: skill) }
        let diskReadDidStart = await waitForHistorySemaphore(blocking.readStarted)
        XCTAssertTrue(diskReadDidStart)
        model.invalidateForManualCheck(skillID: skill.id)
        let manualRetry = Task { await model.request(skill: skill, intent: .retry) }
        blocking.releaseRead.open()
        await firstOpen.value
        await manualRetry.value

        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(model.state, .loaded(loaded))
    }

    /// Protects 39.1-a and 39.2-f: a hidden manual ask advances a pending disk flow before it stores.
    func testHiddenManualCheckDuringDiskLoadPersistsTheReadUnderTheCurrentGeneration() async throws {
        let skill = installedHistorySkill()
        let blocking = BlockingReadHistoryFileService(base: fileService, owner: self)
        try fileService.writeFile(at: cachePath(skill.id), content: "not json")
        blocking.blockNextRead(at: cachePath(skill.id))
        let loaded = result(subject: "loaded")
        let reads = LockedHistoryProbe()
        let model = owner(cache: cache(fileService: blocking)) { _, _, _ in
            reads.recordCall()
            return loaded
        }

        let firstOpen = Task { await model.request(skill: skill) }
        let diskReadDidStart = await waitForHistorySemaphore(blocking.readStarted)
        XCTAssertTrue(diskReadDidStart)
        model.invalidateForManualCheck(skillID: skill.id)
        blocking.releaseRead.open()
        await firstOpen.value

        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(try storedEnvelope(skill.id).result.headCommit, loaded.headCommit)
    }

    /// Protects 39.1-a: a manual ask superseding a disk hit keeps the refresh on the active generation.
    func testManualCheckDuringDiskHitPersistsRefreshForTheNextLaunch() async throws {
        let old = result(head: String(repeating: "1", count: 40), subject: "old")
        let refreshed = result(head: String(repeating: "2", count: 40), subject: "refreshed")
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        let writer = cache()
        let initialGeneration = writer.beginRequest(skillID: skill.id, superseding: false)
        writer.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: skill.lastCheckedHead,
            result: old,
            generation: initialGeneration,
            ordinal: 1
        )
        let blocking = BlockingReadHistoryFileService(base: fileService, owner: self)
        blocking.blockNextRead(at: cachePath(skill.id))
        let reads = LockedHistoryProbe()
        let disk = cache(fileService: blocking)
        let model = owner(cache: disk) { _, _, _ in
            reads.recordCall()
            return refreshed
        }

        let firstOpen = Task { await model.request(skill: skill) }
        let diskReadDidStart = await waitForHistorySemaphore(blocking.readStarted)
        XCTAssertTrue(diskReadDidStart)
        model.invalidateForManualCheck(skillID: skill.id)
        blocking.releaseRead.open()
        await firstOpen.value

        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(try storedEnvelope(skill.id).readHead, refreshed.headCommit)

        let relaunchedReads = LockedHistoryProbe()
        let relaunched = owner(cache: cache()) { _, _, _ in
            relaunchedReads.recordCall()
            return old
        }
        await relaunched.request(skill: skill)

        XCTAssertEqual(relaunched.state, .loaded(refreshed))
        XCTAssertEqual(relaunchedReads.calls, 0)
    }

    /// Protects 39.1-j: removal still fences a refresh moved onto a superseding generation.
    func testRemovalDuringManualDiskHitStillPreventsRefreshAndPersistence() async throws {
        let old = result(head: String(repeating: "1", count: 40), subject: "old")
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        let writer = cache()
        let initialGeneration = writer.beginRequest(skillID: skill.id, superseding: false)
        writer.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: skill.lastCheckedHead,
            result: old,
            generation: initialGeneration,
            ordinal: 1
        )
        let blocking = BlockingReadHistoryFileService(base: fileService, owner: self)
        blocking.blockNextRead(at: cachePath(skill.id))
        let reads = LockedHistoryProbe()
        let disk = cache(fileService: blocking)
        let model = owner(cache: disk) { _, _, _ in
            reads.recordCall()
            return self.result(subject: "unexpected")
        }

        let firstOpen = Task { await model.request(skill: skill) }
        let diskReadDidStart = await waitForHistorySemaphore(blocking.readStarted)
        XCTAssertTrue(diskReadDidStart)
        model.invalidateForManualCheck(skillID: skill.id)
        model.remove(skillID: skill.id)
        blocking.releaseRead.open()
        await firstOpen.value
        let postRemovalGeneration = disk.beginRequest(skillID: skill.id, superseding: false)
        XCTAssertNil(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: 1,
            generation: postRemovalGeneration
        ))

        XCTAssertEqual(reads.calls, 0)
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(fileService.fileExists(at: cachePath(skill.id)))
    }

    /// Protects 39.2-k: switching away during a manual disk load does not leak the ask on reopen.
    func testManualCheckSwitchDuringDiskLoadIsConsumedByTheNextDecision() async throws {
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let secondResult = result(head: String(repeating: "d", count: 40), subject: "second")
        let firstResult = result(subject: "first")
        let blocking = BlockingReadHistoryFileService(base: fileService, owner: self)
        try fileService.writeFile(at: cachePath(first.id), content: "not json")
        blocking.blockNextRead(at: cachePath(first.id))
        let reads = LockedHistoryProbe()
        let model = owner(cache: cache(fileService: blocking)) { origin, _, _ in
            reads.recordCall()
            return origin.installedCommit == first.installedOrigin?.installedCommit ? firstResult : secondResult
        }
        try holdMemory(secondResult, for: second, in: model)
        model.probedSkillIDs.insert(second.id)
        model.invalidateForManualCheck(skillID: first.id)

        let pendingFirst = Task { await model.request(skill: first, intent: .retry) }
        let diskReadDidStart = await waitForHistorySemaphore(blocking.readStarted)
        XCTAssertTrue(diskReadDidStart)
        await model.request(skill: second)
        blocking.releaseRead.open()
        await pendingFirst.value
        await model.request(skill: first)

        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(model.state, .loaded(firstResult))
    }

    /// Protects 39.2-k: the manual disk path clears another skill's rows before doing I/O.
    func testManualCheckClearsPreviousSkillPresentationBeforeDiskIO() async throws {
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let secondResult = result(head: String(repeating: "d", count: 40), subject: "second")
        let blocking = BlockingReadHistoryFileService(base: fileService, owner: self)
        try fileService.writeFile(at: cachePath(first.id), content: "not json")
        blocking.blockNextRead(at: cachePath(first.id))
        let model = owner(cache: cache(fileService: blocking)) { _, _, _ in self.result(subject: "first") }
        try holdMemory(secondResult, for: second, in: model)
        model.probedSkillIDs.insert(second.id)
        await model.request(skill: second)
        model.invalidateForManualCheck(skillID: first.id)

        let pendingFirst = Task { await model.request(skill: first, intent: .retry) }
        let diskReadDidStart = await waitForHistorySemaphore(blocking.readStarted)
        XCTAssertTrue(diskReadDidStart)

        XCTAssertEqual(model.currentSkillID, first.id)
        XCTAssertEqual(model.state, .loading)
        blocking.releaseRead.open()
        await pendingFirst.value
    }

    /// Protects 39.2-c: a joined completion is held and persisted under the question its fetch asked.
    func testJoinedRefreshPersistsItsOwnQuestionBeforeRefreshingTheRemount() async throws {
        let originalHead = String(repeating: "1", count: 40)
        let recordedHead = String(repeating: "2", count: 40)
        let staleReadHead = String(repeating: "3", count: 40)
        let old = result(head: originalHead, subject: "old")
        let stale = result(head: staleReadHead, subject: "stale")
        let current = result(head: recordedHead, subject: "current")
        let skill = installedHistorySkill(recordedHead: originalHead)
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = TestWait.Gate(owner: self)
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseSecond = TestWait.Gate(owner: self)
        let reads = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in
            reads.recordCall()
            if reads.calls == 1 {
                firstStarted.signal()
                try releaseFirst.wait()
                return stale
            }
            secondStarted.signal()
            try releaseSecond.wait()
            return current
        }
        try holdMemory(old, for: skill, in: model)
        model.invalidateForManualCheck(skillID: skill.id)

        let refresh = Task { await model.request(skill: skill, intent: .retry) }
        let firstDidStart = await waitForHistorySemaphore(firstStarted)
        XCTAssertTrue(firstDidStart)
        skill.lastCheckedHead = recordedHead
        let remount = Task { await model.request(skill: skill, intent: .mountedRefresh) }
        releaseFirst.open()
        let secondDidStart = await waitForHistorySemaphore(secondStarted)
        XCTAssertTrue(secondDidStart)

        let stored = try storedEnvelope(skill.id)
        XCTAssertEqual(stored.recordedHeadAtRead, originalHead)
        XCTAssertEqual(stored.readHead, staleReadHead)
        releaseSecond.open()
        await refresh.value
        await remount.value

        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(model.state, .loaded(current))
    }

    private func holdMemory(
        _ result: UpstreamHistoryResult,
        for skill: Skill,
        in owner: UpstreamHistoryViewModel
    ) throws {
        let origin = try XCTUnwrap(skill.installedOrigin)
        let request = UpstreamHistoryViewModel.RequestKey(
            skillID: skill.id,
            origin: UpstreamHistoryViewModel.OriginKey(origin: origin),
            recordedHead: skill.lastCheckedHead
        )
        owner.hold(
            UpstreamHistoryViewModel.HeldResult(
                origin: request.origin,
                recordedHeadAtRead: skill.lastCheckedHead,
                readHead: result.headCommit,
                result: result,
                localRevision: .initial
            ),
            for: UpstreamHistoryViewModel.ReadKey(request: request, windowCount: result.windowCount)
        )
    }
}
