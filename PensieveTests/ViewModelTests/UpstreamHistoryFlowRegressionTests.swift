import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryFlowRegressionTests: UpstreamHistoryCacheTestCase {
    func testJoinedReadCompletionBeforeDiskMissDoesNotReadAgainOrHideFailure() async throws {
        for fails in [false, true] {
            let fixture = try sequenceFixture(.empty, fails: fails)
            let flow = fixture.flow
            fixture.enqueue("A")
            try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume", "read1.start"])
            fixture.enqueue("B", intent: .mountedRefresh)
            try await flow.run(["B.request", "disk2.start", "disk2.finish", "read1.finish", "read1.resume"])
            let settledRead = fixture.model.state
            try await flow.release("disk2.resume")
            try await flow.drain()
            XCTAssertEqual(fixture.model.state, settledRead)
            XCTAssertEqual(fixture.calls.values, ["read"])
            XCTAssertEqual(flow.work.values.filter { $0.kind == .read }.count, 1)
            if fails { guard case .failed = settledRead else { return XCTFail("Lost the joined failure") } }
            try flow.validateApplications()
            await flow.close()
        }
    }

    func testJoinedFailureSurvivesALaterDiskHitAndReopen() async throws {
        let fixture = try sequenceFixture(.empty, fails: true)
        let flow = fixture.flow
        fixture.enqueue("A")
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume", "read1.start"])
        try seedHistoryDisk(fixture.kept, for: fixture.skill, in: fixture.disk)
        fixture.enqueue("B", intent: .mountedRefresh)
        try await flow.run(["B.request", "disk2.start", "disk2.finish", "read1.finish", "read1.resume", "disk2.resume"])
        try await assertFailureAndReopen(fixture)
    }

    func testJoinedFailureSurvivesLocalMeasurementAndReopen() async throws {
        let fixture = try sequenceFixture(.memory, fails: true, edits: .countsUnknown)
        let flow = fixture.flow
        fixture.enqueue("A", intent: .retry)
        try await flow.run(["A.request", "read1.start"])
        fixture.enqueue("B", changed: true, intent: .mountedRefresh)
        try await flow.run(["B.request", "localEdits1.start", "read1.finish", "read1.resume",
                            "localEdits1.finish", "localEdits1.resume"])
        try await assertFailureAndReopen(fixture, edits: .countsUnknown)
    }

    func testMemoryArrivingDuringDiskWaitRefreshesRevisionChecksHeadAndConsumesManualAsk() async throws {
        let fixture = try sequenceFixture(.empty, edits: .countsUnknown)
        let flow = fixture.flow
        var checks: [UUID] = []
        fixture.enqueue("A")
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume", "read1.start"])
        flow.enqueue("B") {
            await fixture.model.request(skill: fixture.skill,
                                        localRevision: UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0),
                                        onUpdateCheck: { checks.append($0) })
        }
        try await flow.run(["B.request", "disk2.start", "disk2.finish", "read1.finish", "read1.resume"])
        flow.enqueue("check") { fixture.model.invalidateForManualCheck(skillID: fixture.skill.id) }
        try await flow.run(["check.request", "disk2.resume", "localEdits1.start", "localEdits1.finish", "localEdits1.resume"])
        XCTAssertEqual(checks, [fixture.skill.id])
        XCTAssertEqual(fixture.model.state, .refreshing(fixture.fresh.replacing(localEdits: .countsUnknown)))
        XCTAssertFalse(fixture.model.flows[fixture.skill.id]?.manualPending ?? true)
        try await flow.release("read2.start")
        XCTAssertEqual(fixture.calls.values, ["read", "read"])
        try await flow.drain()
        try flow.validateApplications()
        await flow.close()
    }

    func testReadStarterWaitsForPersistAfterItsKeptJoinReturns() async throws {
        let fixture = try sequenceFixture(.empty)
        let flow = fixture.flow
        fixture.enqueue("A")
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume", "read1.start"])
        try seedHistoryDisk(fixture.kept, for: fixture.skill, in: fixture.disk)
        fixture.enqueue("B")
        try await flow.run(["B.request", "disk2.start", "disk2.finish", "disk2.resume"])
        XCTAssertEqual(flow.lanes["B"], .done, "The kept-row join returns before the read finishes")
        try await flow.run(["read1.finish", "read1.resume"])
        XCTAssertEqual(flow.enabled, ["persist1.start"])
        XCTAssertEqual(flow.lanes["A"], .parked, "The read starter must still await its owned persistence")
        try await flow.drain()
        XCTAssertEqual(flow.lanes["A"], .done)
        await flow.close()
    }

    private func assertFailureAndReopen(_ fixture: UpstreamHistorySequenceFixture,
                                        edits: UpstreamHistoryLocalEdits = .none) async throws {
        let flow = fixture.flow
        try await flow.drain()
        guard case let .loadedWithFailure(result, message) = fixture.model.state else {
            return XCTFail("The completed wait hid the held refresh failure")
        }
        XCTAssertEqual(result, fixture.kept.replacing(localEdits: edits))
        XCTAssertTrue(message.contains("sequence offline"))
        fixture.enqueue("C", changed: edits != .none)
        try await flow.drain()
        XCTAssertEqual(fixture.model.state, .loadedWithFailure(result, message))
        XCTAssertEqual(fixture.calls.values, ["read"])
        try flow.validateApplications()
        await flow.close()
    }
}
