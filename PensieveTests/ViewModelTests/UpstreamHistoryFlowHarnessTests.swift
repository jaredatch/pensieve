import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryFlowHarnessTests: UpstreamHistoryCacheTestCase {
    func testNonRequestActionsAcknowledgeTheirStartAndPerformTheirMutation() async throws {
        let fixture = try sequenceFixture(.memory)
        let flow = fixture.flow
        fixture.enqueue("A")
        flow.enqueue("check", after: "A") { fixture.model.invalidateForManualCheck(skillID: fixture.skill.id) }
        flow.enqueue("remove", after: "check") { fixture.model.remove(skillID: fixture.skill.id) }
        try await flow.run(["A.request", "check.request"])
        XCTAssertEqual(fixture.model.manualCheckCount(skillID: fixture.skill.id), 1)
        try await flow.release("remove.request")
        XCTAssertEqual(fixture.model.state, .idle)
        XCTAssertEqual(fixture.model.manualCheckCount(skillID: fixture.skill.id), 0)
        try await flow.drain()
        try flow.validateApplications()
        XCTAssertEqual(flow.observed.prefix(3), ["A.request", "check.request", "remove.request"])
        await flow.close()
    }

    func testFrontierWaitsForRequestReturnAfterItsLastWorkerEnds() async throws {
        let fixture = try sequenceFixture(.memory)
        let flow = fixture.flow
        var held: CheckedContinuation<Void, Never>?
        flow.enqueue("A") {
            await fixture.model.request(skill: fixture.skill)
            await withCheckedContinuation { held = $0 }
        }
        try await flow.run(["A.request", "probe1.start", "probe1.finish"])
        var returned = false
        let release = Task { try await flow.release("probe1.resume"); returned = true }
        await TestWait.until(failureMessage: "The request did not reach its return hold") { held != nil }
        XCTAssertEqual(flow.lanes["A"], .running)
        XCTAssertFalse(returned, "A resumed request must leave the frontier closed until it returns")
        held?.resume()
        try await release.value
        XCTAssertTrue(flow.finished)
        await flow.close()
    }

    func testFirstCleanupFailureStopsReplayAndReportsScenarioAtCaller() async {
        var attempts = 0
        var message = ""
        var actualFile = ""
        var actualLine: UInt = 0
        for _ in 0..<3 {
            attempts += 1
            let flow = UpstreamHistorySequenceHarness()
            flow.scenario = "cleanup-stop-fixture"
            flow.cleanupTimeout = .milliseconds(20)
            flow.timeoutThreadSample = { nil } // This deliberately exercises a cleanup failure.
            var held: CheckedContinuation<Void, Never>?
            flow.enqueue("stuck") { await withCheckedContinuation { held = $0 } }
            flow.abort()
            await TestWait.until(failureMessage: "The request did not reach its hold") { held != nil }
            flow.cleanupReport = { text, file, line in message = text; actualFile = "\(file)"; actualLine = line }
            let succeeded = await flow.checkRun(file: #filePath, line: 1234, body: {})
            held?.resume()
            for task in flow.tasks { await task.value }
            if !succeeded { break }
        }
        XCTAssertEqual(attempts, 1, "A cleanup failure must end the sweep, not pay the timeout for each replay")
        XCTAssertTrue(message.contains("cleanup-stop-fixture"), message)
        XCTAssertEqual(actualFile, #filePath)
        XCTAssertEqual(actualLine, 1234)
    }
}
