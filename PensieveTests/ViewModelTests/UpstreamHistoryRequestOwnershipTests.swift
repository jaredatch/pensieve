import XCTest
@testable import Pensieve

private enum RequestOwnershipFailure: LocalizedError {
    case offline

    var errorDescription: String? { "The repository couldn't be reached." }
}

@MainActor
final class UpstreamHistoryRequestOwnershipTests: UpstreamHistoryCacheTestCase {
    /// Protects 39.1-a and 39.2-d (R6-1/R6-4): a hidden manual ask keeps a pending disk hit.
    func testHiddenManualCheckDuringQueuedDiskHitKeepsRowsWhenRefreshFails() async throws {
        let old = result(head: String(repeating: "1", count: 40), subject: "kept")
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        try seedHistoryDisk(old, for: skill, in: cache())
        let blockerID = UUID()
        let blockerPath = cachePath(blockerID)
        try fileService.writeFile(at: blockerPath, content: "block maintenance")
        let blocking = BlockingDeleteHistoryFileService(base: fileService, owner: self)
        blocking.blockNextDelete(at: blockerPath)
        let disk = cache(fileService: blocking)
        disk.remove(skillID: blockerID)
        let deleteStarted = await waitForHistorySemaphore(blocking.deleteStarted)
        XCTAssertTrue(deleteStarted)
        let reads = LockedHistoryProbe()
        let model = owner(cache: disk) { _, _, _ in
            reads.recordCall()
            throw RequestOwnershipFailure.offline
        }

        let pending = Task { await model.request(skill: skill) }
        for _ in 0..<100 where model.currentRequest == nil { await Task.yield() }
        XCTAssertNotNil(model.currentRequest)
        model.invalidateForManualCheck(skillID: skill.id)
        blocking.releaseDelete.open()
        await pending.value

        XCTAssertEqual(
            model.state,
            .loadedWithFailure(old, "History couldn't be refreshed. The repository couldn't be reached.")
        )
        await model.request(skill: skill)
        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(
            model.state,
            .loadedWithFailure(old, "History couldn't be refreshed. The repository couldn't be reached.")
        )
    }

    /// Protects 39.2-b (R6-3): an unpublished failure cannot bypass a later disk answer.
    func testNextOpenUsesDiskAfterAnUnpublishedFailure() async throws {
        let first = installedHistorySkill(name: "First")
        let second = installedHistorySkill(name: "Second", commit: String(repeating: "c", count: 40))
        let kept = result(subject: "kept")
        let secondResult = result(head: String(repeating: "d", count: 40), subject: "second")
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let reads = LockedHistoryProbe()
        let model = owner(cache: cache()) { origin, _, _ in
            if origin.installedCommit == first.installedOrigin?.installedCommit {
                reads.recordCall()
                if reads.calls == 1 {
                    readStarted.signal()
                    try releaseRead.wait()
                }
                throw RequestOwnershipFailure.offline
            }
            return secondResult
        }
        try seedHistoryMemory(secondResult, for: second, in: model)
        model.probedSkillIDs.insert(second.id)

        let failed = Task { await model.request(skill: first) }
        let firstReadStarted = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(firstReadStarted)
        try seedHistoryDisk(kept, for: first, in: cache())
        await model.request(skill: second)
        releaseRead.open()
        await failed.value
        await model.request(skill: first)

        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(model.state, .loaded(kept))
    }

    /// Protects 39.2-b and 39.2-c (R6-2): success cannot drive a current question that never joined.
    func testSuccessfulRefreshDoesNotStartAReadForAnAnsweredNonwaiter() async throws {
        let originalHead = String(repeating: "1", count: 40)
        let refreshingHead = String(repeating: "2", count: 40)
        let keptHead = String(repeating: "3", count: 40)
        let kept = result(head: keptHead, subject: "kept")
        let refreshed = result(head: refreshingHead, subject: "refresh")
        let skill = installedHistorySkill(recordedHead: originalHead)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let reads = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in
            reads.recordCall()
            if reads.calls == 1 {
                readStarted.signal()
                try releaseRead.wait()
            }
            return refreshed
        }
        try seedHistoryMemory(kept, for: skill, recordedHeadAtRead: originalHead, in: model)
        skill.lastCheckedHead = refreshingHead

        let refresh = Task { await model.request(skill: skill, intent: .retry) }
        let refreshStarted = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(refreshStarted)
        skill.lastCheckedHead = keptHead
        await model.request(skill: skill, intent: .mountedRefresh)
        releaseRead.open()
        await refresh.value

        XCTAssertEqual(reads.calls, 1)
        XCTAssertEqual(model.state, .loaded(kept))
    }

    /// Protects 39.2-b and 39.2-k (R6-5): an older request stack cannot drive a newer request.
    func testOlderHeldResultStackCannotRetryForANewerRequestIdentity() async throws {
        let kept = result(subject: "kept")
        let skill = installedHistorySkill(recordedHead: kept.headCommit)
        let editsStarted = DispatchSemaphore(value: 0)
        let releaseEdits = TestWait.Gate(owner: self)
        let reads = LockedHistoryProbe()
        let model = owner(
            cache: cache(),
            read: { _, _, _ in reads.recordCall(); return self.result(subject: "unexpected") },
            localEdits: { _, _, _ in
                editsStarted.signal()
                try releaseEdits.wait()
                return .none
            }
        )
        try seedHistoryMemory(kept, for: skill, in: model)
        model.probedSkillIDs.insert(skill.id)
        let changed = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)

        let older = Task {
            await model.request(skill: skill, localRevision: changed, intent: .retry)
        }
        let localEditsStarted = await waitForHistorySemaphore(editsStarted)
        XCTAssertTrue(localEditsStarted)
        await model.request(skill: skill)
        releaseEdits.open()
        await older.value

        XCTAssertEqual(reads.calls, 0)
        XCTAssertEqual(model.state, .loaded(kept))
    }

    /// Protects 39.2-b and 39.2-k (R6-5): an older success cannot publish for a newer request identity.
    func testOlderReadSuccessCannotPublishForANewerNonwaiterIdentity() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let refreshedHead = String(repeating: "2", count: 40)
        let kept = result(head: refreshedHead, subject: "kept")
        let refreshed = result(head: refreshedHead, subject: "older success")
        let skill = installedHistorySkill(recordedHead: oldHead)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let model = owner(cache: cache()) { _, _, _ in
            readStarted.signal()
            try releaseRead.wait()
            return refreshed
        }
        try seedHistoryMemory(kept, for: skill, in: model)
        model.probedSkillIDs.insert(skill.id)

        let older = Task { await model.request(skill: skill, intent: .retry) }
        let refreshStarted = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(refreshStarted)
        skill.lastCheckedHead = refreshedHead
        await model.request(skill: skill)
        XCTAssertEqual(model.state, .loaded(kept))
        releaseRead.open()
        await older.value

        XCTAssertEqual(model.state, .loaded(kept))
    }

    /// Protects 39.2-c and 39.2-d (R6-7): a shared read owns its registered waiter set.
    func testSharedReadOperationOwnsItsJoinedWaiters() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let nextHead = String(repeating: "2", count: 40)
        let kept = result(head: oldHead)
        let skill = installedHistorySkill(recordedHead: oldHead)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let model = owner(cache: cache()) { _, _, _ in
            readStarted.signal()
            try releaseRead.wait()
            return self.result(head: nextHead)
        }
        try seedHistoryMemory(kept, for: skill, in: model)

        let first = Task { await model.request(skill: skill, intent: .retry) }
        let refreshStarted = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(refreshStarted)
        skill.lastCheckedHead = nextHead
        let second = Task { await model.request(skill: skill, intent: .mountedRefresh) }
        let joined = await waitForHistoryCondition {
            model.reads.values.first?.waiters.count == 2
        }
        let operation = try XCTUnwrap(model.reads.values.first)

        XCTAssertTrue(joined)
        XCTAssertEqual(operation.waiters.count, 2)
        releaseRead.open()
        await first.value
        await second.value
    }

    /// Request identity alone identifies the current question.
    func testCurrentQuestionMatchingUsesRequestIdentityAlone() throws {
        let skill = installedHistorySkill()
        let origin = try XCTUnwrap(skill.installedOrigin)
        let firstKey = historyRequestKey(skill: skill, origin: origin, recordedHead: nil)
        let secondKey = historyRequestKey(skill: skill, origin: origin, recordedHead: "new-head")
        let identity = UUID()
        let current = UpstreamHistoryViewModel.CurrentRequest(
            id: identity,
            key: firstKey,
            localRevision: .initial,
            windowCount: 1,
            cacheGeneration: 0
        )
        let sameQuestion = UpstreamHistoryViewModel.CurrentRequest(
            id: identity,
            key: secondKey,
            localRevision: UpstreamHistoryLocalRevision(appWriteRevision: 2, watcherEventSequence: 3),
            windowCount: 4,
            cacheGeneration: 9
        )
        let model = owner(cache: cache()) { _, _, _ in self.result() }
        model.currentRequest = current

        XCTAssertEqual(model.currentQuestion(matching: sameQuestion)?.id, identity)
    }

}

@MainActor
extension UpstreamHistoryCacheTestCase {
    func seedHistoryDisk(_ result: UpstreamHistoryResult, for skill: Skill, in cache: UpstreamHistoryCache) throws {
        let generation = cache.beginRequest(skillID: skill.id, superseding: false)
        cache.store(
            skillID: skill.id,
            origin: try origin(for: skill),
            recordedHeadAtRead: skill.lastCheckedHead,
            result: result,
            generation: generation,
            ordinal: 1
        )
    }

    func seedHistoryMemory(
        _ result: UpstreamHistoryResult,
        for skill: Skill,
        recordedHeadAtRead: String? = nil,
        in model: UpstreamHistoryViewModel
    ) throws {
        let origin = try XCTUnwrap(skill.installedOrigin)
        let key = historyRequestKey(skill: skill, origin: origin, recordedHead: skill.lastCheckedHead)
        model.hold(
            UpstreamHistoryViewModel.HeldResult(
                origin: key.origin,
                recordedHeadAtRead: recordedHeadAtRead ?? skill.lastCheckedHead,
                readHead: result.headCommit,
                result: result,
                localRevision: .initial
            ),
            for: UpstreamHistoryViewModel.ReadKey(request: key, windowCount: result.windowCount)
        )
    }

    func historyRequestKey(
        skill: Skill,
        origin: InstalledOrigin,
        recordedHead: String?
    ) -> UpstreamHistoryViewModel.RequestKey {
        UpstreamHistoryViewModel.RequestKey(
            skillID: skill.id,
            origin: UpstreamHistoryViewModel.OriginKey(origin: origin),
            recordedHead: recordedHead
        )
    }
}
