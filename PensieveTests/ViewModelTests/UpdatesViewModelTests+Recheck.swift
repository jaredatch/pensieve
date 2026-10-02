import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension UpdatesViewModelTests {
    func testActiveRecheckBlocksDiffAndApplyUntilCompletion() async throws {
        let first = insertUpdateSkill(slug: "first-recheck")
        let second = insertUpdateSkill(slug: "second-recheck")
        try context.save()
        let rows = try [first, second].map {
            try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false)
        }
        let gate = TestWait.Gate(owner: self)
        let started = DispatchSemaphore(value: 0)
        let diffCalls = LockedCallRecorder()
        let applyCalls = LockedCallRecorder()
        let model = makeModel(
            rows: rows,
            diff: { id, _, _, _ in
                diffCalls.append(id)
                return PinnedSkillDiff(
                    currentSkillMarkdown: "current",
                    upstreamSkillMarkdown: "upstream"
                )
            },
            recheck: { id, _ in
                started.signal()
                try gate.wait()
                return Self.refreshedRecheckCompletion(row: rows[0], skillID: id)
            },
            apply: { id, _, _, _, _, _ in
                applyCalls.append(id)
                return try self.completion(for: first)
            }
        )
        await model.loadAndReport(context: context)

        model.recheck(rows[0], context: context)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart, "update recheck did not start")
        XCTAssertEqual(model.recheckingSkillID, rows[0].id)
        XCTAssertEqual(model.status(for: rows[0]), .updating)

        model.viewChanges(for: rows[1], context: context)
        await model.applySelectedAndReport(context: context)

        XCTAssertEqual(diffCalls.values, [])
        XCTAssertEqual(applyCalls.values, [])
        XCTAssertNil(model.diffLoadingSkillID)
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.status(for: rows[0]), .updating)

        gate.open()
        await TestWait.until(failureMessage: "update recheck did not finish") { model.recheckingSkillID == nil }
        XCTAssertNil(model.recheckingSkillID)
        XCTAssertEqual(model.status(for: rows[0]), .idle)
        XCTAssertEqual(model.rows.first, rows[0])
    }

    func testRecheckErrorStaysVisible() async throws {
        let skill = insertUpdateSkill(slug: "errored-recheck")
        try context.save()
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let model = makeModel(rows: [row], recheck: { id, _ in
            SkillUpdateRecheckCompletion(
                row: nil,
                skillID: id,
                updateAvailable: true,
                lastCheckedAt: Date(),
                lastCheckedHead: nil,
                upstreamTree: row.upstreamTree,
                upstreamCommit: row.upstreamCommit,
                upstreamCommitDate: row.updateDate,
                checkError: "Authentication failed"
            )
        })
        await model.loadAndReport(context: context)

        await model.recheckAndReport(row, context: context)

        XCTAssertEqual(model.rows, [row])
        XCTAssertEqual(
            model.status(for: row),
            .failed(message: "Authentication failed", offersRecheck: true)
        )
        XCTAssertEqual(skill.checkError, "Authentication failed")
    }

    func testCancelReleasesRecheckLockWithoutStaleTaskClearingNewLock() async throws {
        let skill = insertUpdateSkill(slug: "cancel-recheck")
        try context.save()
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let firstGate = TestWait.Gate(owner: self)
        let secondGate = TestWait.Gate(owner: self)
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let calls = LockedCallRecorder()
        let model = makeModel(rows: [row], recheck: { id, _ in
            calls.append(id)
            if calls.values.count == 1 {
                firstStarted.signal()
                try firstGate.wait()
                firstFinished.signal()
            } else {
                secondStarted.signal()
                try secondGate.wait()
            }
            return Self.refreshedRecheckCompletion(row: row, skillID: id)
        })
        await model.loadAndReport(context: context)

        model.recheck(row, context: context)
        let firstTask = try XCTUnwrap(model.operationTask)
        let didStartFirst = await TestWait.forSemaphore(firstStarted)
        XCTAssertTrue(didStartFirst, "first update recheck did not start")
        model.cancel()
        XCTAssertNil(model.recheckingSkillID)

        model.recheck(row, context: context)
        let didStartSecond = await TestWait.forSemaphore(secondStarted)
        XCTAssertTrue(didStartSecond, "second update recheck did not start")
        XCTAssertEqual(model.recheckingSkillID, row.id)

        firstGate.open()
        let didFinishFirst = await TestWait.forSemaphore(firstFinished)
        XCTAssertTrue(didFinishFirst, "first cancelled update recheck did not finish")
        await TestWait.forTask(firstTask, failureMessage: "cancelled recheck did not finish in the model")
        XCTAssertEqual(model.recheckingSkillID, row.id)
        XCTAssertEqual(model.status(for: row), .updating)

        secondGate.open()
        await TestWait.until(failureMessage: "second update recheck did not finish") {
            model.recheckingSkillID == nil
        }
        XCTAssertNil(model.recheckingSkillID)
        XCTAssertEqual(model.status(for: row), .idle)
    }

    func testActiveRecheckBlocksRecheckSupersessionUntilCompletion() async throws {
        let first = insertUpdateSkill(slug: "first-recheck-lock")
        let second = insertUpdateSkill(slug: "second-recheck-lock")
        try context.save()
        let rows = try [first, second].map {
            try UpdatesViewModel.makeRow(skill: $0, driftedLocally: false)
        }
        let gate = TestWait.Gate(owner: self)
        let started = DispatchSemaphore(value: 0)
        let calls = LockedCallRecorder()
        let model = makeModel(rows: rows, recheck: { id, _ in
            calls.append(id)
            if calls.values.count == 1 {
                started.signal()
                try gate.wait()
            }
            let refreshed = id == rows[0].id ? rows[0] : rows[1]
            return Self.refreshedRecheckCompletion(row: refreshed, skillID: id)
        })
        await model.loadAndReport(context: context)

        model.recheck(rows[0], context: context)
        let didStart = await TestWait.forSemaphore(started)
        XCTAssertTrue(didStart, "update recheck did not start")
        XCTAssertEqual(model.recheckingSkillID, rows[0].id)

        model.recheck(rows[1], context: context)
        await model.recheckAndReport(rows[1], context: context)

        XCTAssertEqual(calls.values, [rows[0].id])
        XCTAssertEqual(model.status(for: rows[0]), .updating)
        XCTAssertEqual(model.status(for: rows[1]), .idle)

        gate.open()
        await TestWait.until(failureMessage: "update recheck did not finish") {
            model.recheckingSkillID == nil
        }
        XCTAssertEqual(model.status(for: rows[0]), .idle)
        XCTAssertEqual(model.rows.first, rows[0])
    }
}
