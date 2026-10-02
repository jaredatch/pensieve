import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryCacheLifecycleTests: UpstreamHistoryCacheTestCase {
    /// Protects 39.1-g: removal completion is observable without a cache-only drain seam.
    func testRemoveAndRetainDeleteKeptFiles() async throws {
        let skill = installedHistorySkill()
        let disk = cache()
        let model = owner(cache: disk) { _, _, _ in self.result() }
        await model.request(skill: skill)
        XCTAssertTrue(fileService.isRegularFile(at: cachePath(skill.id)))

        model.remove(skillID: skill.id)
        let removedGeneration = disk.beginRequest(skillID: skill.id, superseding: false)
        XCTAssertNil(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: 1,
            generation: removedGeneration
        ))
        XCTAssertFalse(fileService.fileExists(at: cachePath(skill.id)))

        await model.request(skill: skill)
        XCTAssertTrue(fileService.isRegularFile(at: cachePath(skill.id)))
        model.retain(skillIDs: [])
        let retainedGeneration = disk.beginRequest(skillID: skill.id, superseding: false)
        XCTAssertNil(disk.load(
            skillID: skill.id,
            origin: try origin(for: skill),
            minimumWindow: 1,
            generation: retainedGeneration
        ))
        XCTAssertFalse(fileService.fileExists(at: cachePath(skill.id)))
    }

    func testManualInvalidationBypassesDiskOnceAndReplacesIt() async throws {
        let skill = installedHistorySkill()
        let disk = cache()
        let old = result(head: String(repeating: "1", count: 40), subject: "old")
        let new = result(head: String(repeating: "2", count: 40), subject: "new")
        let probe = LockedHistoryProbe()
        let model = owner(cache: disk) { _, _, _ in
            probe.recordCall()
            return probe.calls == 1 ? old : new
        }
        await model.request(skill: skill)

        model.invalidateForManualCheck(skillID: skill.id)
        await model.request(skill: skill, intent: .retry)

        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(model.state, .loaded(new))
        XCTAssertEqual(try storedEnvelope(skill.id).readHead, new.headCommit)
    }

    func testRetryAfterManualRefreshFailureBypassesTheOldDiskEntry() async {
        enum Failure: LocalizedError {
            case offline
            var errorDescription: String? { "The repository couldn't be reached." }
        }
        let skill = installedHistorySkill()
        let disk = cache()
        let old = result(head: String(repeating: "1", count: 40), subject: "old")
        let new = result(head: String(repeating: "2", count: 40), subject: "new")
        let probe = LockedHistoryProbe()
        let model = owner(cache: disk) { _, _, _ in
            probe.recordCall()
            if probe.calls == 2 { throw Failure.offline }
            return probe.calls == 1 ? old : new
        }
        await model.request(skill: skill)

        model.invalidateForManualCheck(skillID: skill.id)
        await model.request(skill: skill, intent: .retry)
        XCTAssertEqual(
            model.state,
            .loadedWithFailure(old, "History couldn't be refreshed. The repository couldn't be reached.")
        )

        await model.request(skill: skill, intent: .retry)

        XCTAssertEqual(probe.calls, 3)
        XCTAssertEqual(model.state, .loaded(new))
    }

    func testLateCompletionAfterDeleteCannotRecreateEntry() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let skill = installedHistorySkill()
        let disk = cache()
        let model = owner(cache: disk) { _, _, _ in
            started.signal()
            try release.wait()
            return self.result()
        }

        let request = Task { await model.request(skill: skill) }
        let didStart = await waitForHistorySemaphore(started)
        XCTAssertTrue(didStart)
        model.remove(skillID: skill.id)
        release.open()
        await request.value

        XCTAssertFalse(fileService.fileExists(at: cachePath(skill.id)))
    }

    func testLateCompletionAfterRetainDropCannotRecreateEntry() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let skill = installedHistorySkill()
        let disk = cache()
        let model = owner(cache: disk) { _, _, _ in
            started.signal()
            try release.wait()
            return self.result()
        }

        let request = Task { await model.request(skill: skill) }
        let didStart = await waitForHistorySemaphore(started)
        XCTAssertTrue(didStart)
        model.retain(skillIDs: [])
        release.open()
        await request.value

        XCTAssertFalse(fileService.fileExists(at: cachePath(skill.id)))
    }

    func testOriginChangeBeatsLateOldRead() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = TestWait.Gate(owner: self)
        let oldCommit = String(repeating: "a", count: 40)
        let newCommit = String(repeating: "c", count: 40)
        let oldResult = result(head: String(repeating: "1", count: 40), subject: "old")
        let newResult = result(head: String(repeating: "2", count: 40), subject: "new")
        let skill = installedHistorySkill(commit: oldCommit)
        let disk = cache()
        let model = owner(cache: disk) { origin, _, _ in
            if origin.installedCommit == oldCommit {
                started.signal()
                try release.wait()
                return oldResult
            }
            return newResult
        }

        let oldRequest = Task { await model.request(skill: skill) }
        let didStart = await waitForHistorySemaphore(started)
        XCTAssertTrue(didStart)
        var moved = try origin(for: skill)
        moved.installedCommit = newCommit
        skill.installedOrigin = moved
        await model.request(skill: skill)
        release.open()
        await oldRequest.value

        XCTAssertEqual(try storedEnvelope(skill.id).result.rows.first?.subject, "new")
        XCTAssertEqual(try storedEnvelope(skill.id).origin.installedCommit, newCommit)
    }

    func testOverlappingWindowsKeepTheWiderResultWhenItFinishesFirst() async throws {
        let narrowStarted = DispatchSemaphore(value: 0)
        let releaseNarrow = TestWait.Gate(owner: self)
        let skill = installedHistorySkill()
        let disk = cache()
        let model = owner(cache: disk) { _, _, window in
            if window == 1 {
                narrowStarted.signal()
                try releaseNarrow.wait()
            }
            return self.result(window: window, position: .olderThanRowsRead, subject: "window \(window)")
        }

        let narrow = Task { await model.request(skill: skill) }
        let didStart = await waitForHistorySemaphore(narrowStarted)
        XCTAssertTrue(didStart)
        await model.request(skill: skill, windowCount: 2)
        releaseNarrow.open()
        await narrow.value

        let kept = try storedEnvelope(skill.id)
        XCTAssertEqual(kept.result.windowCount, 2)
        XCTAssertEqual(kept.result.rows.first?.subject, "window 2")
    }

    /// Protects 39.1-j: an earlier-started wider completion at the same head still replaces a narrow one.
    func testEarlierWiderCompletionAtTheSameHeadReplacesLaterNarrowCompletion() async throws {
        let wideStarted = DispatchSemaphore(value: 0)
        let releaseWide = TestWait.Gate(owner: self)
        let skill = installedHistorySkill()
        let disk = cache()
        let model = owner(cache: disk) { _, _, window in
            if window == 2 {
                wideStarted.signal()
                try releaseWide.wait()
            }
            return self.result(window: window, position: .olderThanRowsRead, subject: "window \(window)")
        }

        let wide = Task { await model.request(skill: skill, windowCount: 2) }
        let wideDidStart = await waitForHistorySemaphore(wideStarted)
        XCTAssertTrue(wideDidStart)
        await model.request(skill: skill, windowCount: 1)
        releaseWide.open()
        await wide.value

        let kept = try storedEnvelope(skill.id)
        XCTAssertEqual(kept.result.windowCount, 2)
        XCTAssertEqual(kept.result.rows.first?.subject, "window 2")
    }

    func testNewRecordedHeadBeatsLateReadForPreviousQuestion() async throws {
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = TestWait.Gate(owner: self)
        let oldRecorded = String(repeating: "1", count: 40)
        let newRecorded = String(repeating: "2", count: 40)
        let skill = installedHistorySkill(recordedHead: oldRecorded)
        let disk = cache()
        let model = owner(cache: disk) { _, _, _ in
            if skill.lastCheckedHead == oldRecorded {
                oldStarted.signal()
                try releaseOld.wait()
                return self.result(head: oldRecorded, subject: "old")
            }
            return self.result(head: newRecorded, subject: "new")
        }

        let old = Task { await model.request(skill: skill) }
        let didStart = await waitForHistorySemaphore(oldStarted)
        XCTAssertTrue(didStart)
        skill.lastCheckedHead = newRecorded
        await model.request(skill: skill)
        releaseOld.open()
        await old.value

        XCTAssertEqual(try storedEnvelope(skill.id).readHead, newRecorded)
        XCTAssertEqual(try storedEnvelope(skill.id).result.rows.first?.subject, "new")
    }

    func testNewHeadReplacesAWiderEntryFromThePreviousQuestion() async throws {
        let oldHead = String(repeating: "1", count: 40)
        let newHead = String(repeating: "2", count: 40)
        let skill = installedHistorySkill(recordedHead: oldHead)
        let disk = cache()
        let model = owner(cache: disk) { _, _, window in
            if skill.lastCheckedHead == oldHead {
                return self.result(
                    head: oldHead,
                    window: window,
                    position: .olderThanRowsRead,
                    subject: "old"
                )
            }
            return self.result(head: newHead, window: window, subject: "new")
        }
        await model.request(skill: skill, windowCount: 2)

        skill.lastCheckedHead = newHead
        await model.request(skill: skill)

        let kept = try storedEnvelope(skill.id)
        XCTAssertEqual(kept.readHead, newHead)
        XCTAssertEqual(kept.result.windowCount, 1)
        XCTAssertEqual(kept.result.rows.first?.subject, "new")
    }

}
