import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistorySequenceReviewTests: UpstreamHistoryCacheTestCase {
    func testWrongOperationResumeCannotMasqueradeAsScheduledPath() async throws {
        let fixture = try sequenceFixture(.memory)
        let flow = fixture.flow
        let wrongID = UUID()
        flow.hooks.started(.read, wrongID)
        flow.work[wrongID]?.phase = .finished
        let realResume = flow.hooks.resume
        fixture.model.sequenceHooks?.resume = { id in
            flow.lanes[flow.name(id)] = .parked
            await realResume(wrongID)
        }
        fixture.enqueue("A")
        try await flow.run(["A.request", "probe1.start", "probe1.finish"])
        do {
            try await flow.release("read1.resume")
            XCTFail("A wrong operation resumed without rejecting the scheduled path")
        } catch {
            XCTAssertTrue(String(describing: error).contains("order"))
        }
        await flow.close()
    }

    func testFrontierTimeoutStopsBeforeAnyLaterRelease() async throws {
        let fixture = try sequenceFixture(.empty)
        let flow = fixture.flow
        flow.frontierTimeout = .milliseconds(20) // upper-bound: Prove a timed-out frontier refuses later releases.
        var sampleCalls = 0
        flow.timeoutThreadSample = {
            sampleCalls += 1
            XCTAssertFalse(flow.draining, "Sample before abort releases the gates")
            XCTAssertNotNil(flow.gates["A.request"], "The held continuation must still be present")
            return nil // This test deliberately times out; no real sampler or artifacts on success.
        }
        fixture.enqueue("A")
        flow.lanes["stuck"] = .running
        do {
            try await flow.run(["A.request", "disk1.start"])
            XCTFail("A timed-out frontier continued the schedule")
        } catch {
            XCTAssertTrue(String(describing: error).contains("frontier"))
            XCTAssertTrue(String(describing: error).contains("schedule"))
        }
        XCTAssertEqual(sampleCalls, 1)
        XCTAssertTrue(flow.scheduled.isEmpty)
        let waits = flow.frontierWaits
        do {
            try await flow.release("A.request")
            XCTFail("A failed run accepted another release")
        } catch {
            XCTAssertTrue(String(describing: error).contains("frontier"))
        }
        XCTAssertEqual(flow.frontierWaits, waits, "A failed run must not wait for another deadline")
        await flow.close()
    }

    func testDuplicateGateIsNamedAndNeitherContinuationLeaks() async throws {
        let flow = UpstreamHistorySequenceHarness()
        let hooks = flow.hooks
        let id = UUID()
        hooks.started(.probe, id)
        let first = Task { await hooks.enter(id) }
        await TestWait.until(failureMessage: "First gate never parked") { flow.gateAttempts == 1 }
        let firstContinuation = try XCTUnwrap(flow.gates["probe1.start"])
        let second = Task { await hooks.enter(id) }
        await TestWait.until(failureMessage: "Second gate never arrived") { flow.gateAttempts == 2 }
        do {
            try await flow.settle()
            XCTFail("Duplicate gate was accepted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Duplicate gate: probe1.start"))
        }
        // On the unfixed harness, recover the overwritten continuation so the red test terminates.
        if flow.failure == nil { firstContinuation.resume() }
        await flow.close()
        await first.value
        await second.value
    }

    func testStartDependenciesAreExplicitAndLabelsDoNotImposeOrder() async throws {
        let fixture = try sequenceFixture(.memory)
        fixture.enqueue("A")
        fixture.enqueue("B")
        try await fixture.flow.settle()
        XCTAssertEqual(fixture.flow.enabled, ["A.request", "B.request"])
        await fixture.flow.close()

        let renamed = try sequenceFixture(.memory)
        renamed.enqueue("first", after: "second")
        renamed.enqueue("second")
        try await renamed.flow.settle()
        XCTAssertEqual(renamed.flow.enabled, ["second.request"])
        try await renamed.flow.release("second.request")
        XCTAssertTrue(renamed.flow.enabled.contains("first.request"))
        await renamed.flow.close()
    }

    func testFrontierSleepsUntilStateChanges() async throws {
        let flow = UpstreamHistorySequenceHarness()
        flow.lanes["waiting"] = .running
        let waiter = Task { try await flow.settle() }
        await TestWait.until(failureMessage: "Frontier wait did not register") { flow.frontierChecks > 0 }
        let initialChecks = flow.frontierChecks
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(flow.frontierChecks, initialChecks, "An unchanged frontier must not be polled")
        flow.lanes["waiting"] = .done
        try await waiter.value
        await flow.close()
    }

    func testSweepRejectsLostOrdersOrChangedExclusionCountsForEachScenario() {
        for (name, count) in HistorySequenceCoverage.expected {
            XCTAssertNoThrow(try HistorySequenceCoverage.validate(name, complete: count.complete, excluded: count.excluded))
            XCTAssertThrowsError(try HistorySequenceCoverage.validate(name, complete: count.complete - 1,
                                                                       excluded: count.excluded))
            XCTAssertThrowsError(try HistorySequenceCoverage.validate(name, complete: count.complete,
                                                                       excluded: count.excluded + 1))
        }
    }

    func testProbeAndLocalOutcomesMustEachBeAppliedExactlyOnce() {
        for kind in [UpstreamHistorySequenceHooks.Work.probe, .localEdits] {
            let flow = UpstreamHistorySequenceHarness()
            let id = UUID()
            flow.hooks.started(kind, id)
            XCTAssertThrowsError(try flow.validateApplications(), "Missing \(kind) outcome")
            flow.hooks.applied(id)
            XCTAssertNoThrow(try flow.validateApplications())
            flow.hooks.applied(id)
            XCTAssertThrowsError(try flow.validateApplications(), "Duplicate \(kind) outcome")
        }
    }
}
