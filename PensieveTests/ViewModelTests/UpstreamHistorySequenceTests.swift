import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistorySequenceTests: UpstreamHistoryCacheTestCase {
    func testDiskReadAndPersistStayHeldUntilReleased() async throws {
        let fixture = try sequenceFixture(.empty)
        let flow = fixture.flow
        fixture.enqueue("A")
        fixture.enqueue("B")
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume",
                            "read1.start", "B.request", "disk2.start", "disk2.finish", "disk2.resume"])
        XCTAssertEqual(fixture.calls.values, ["read"])
        XCTAssertEqual(flow.enabled, ["read1.finish"])
        XCTAssertEqual(fixture.model.state, .loading)
        try await flow.run(["read1.finish", "read1.resume"])
        XCTAssertEqual(fixture.model.state, .loaded(fixture.fresh))
        XCTAssertTrue(flow.enabled.contains("persist1.start"))
        XCTAssertEqual(flow.work.values.filter { $0.name.hasPrefix("persist") }.count, 1)
        try await flow.run(["persist1.start", "persist1.finish", "persist1.resume"])
        XCTAssertTrue(flow.finished)
        XCTAssertEqual(flow.publications.map(\.state), [
            .loading, .loading, .loading, .loaded(fixture.fresh)
        ])
        await flow.close()
    }

    func testAnUnreleasedStepTimesOutAsAnXCTestFailure() async throws {
        let fixture = try sequenceFixture(.memory)
        fixture.enqueue("A")
        try await fixture.flow.release("A.request")
        XCTAssertEqual(fixture.flow.enabled, ["probe1.start"])
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { $0.compactDescription.contains("Unreleased probe") }
        XCTExpectFailure("An omitted release must fail the wall-clock wait", options: options)
        await TestWait.until(timeout: .milliseconds(50), // upper-bound: An omitted release must time out.
                             failureMessage: "Unreleased probe") {
            fixture.flow.finished
        }
        XCTAssertTrue(fixture.calls.values.isEmpty)
        XCTAssertEqual(fixture.flow.enabled, ["probe1.start"])
        try await fixture.flow.drain()
        await fixture.flow.close()
    }

    func testSharedLocalEditsResumeInEitherChosenOrder() async throws {
        for order in [["A", "B"], ["B", "A"]] {
            let fixture = try sequenceFixture(.memory, edits: .countsUnknown)
            let flow = fixture.flow
            fixture.enqueue("A", changed: true)
            fixture.enqueue("B", changed: true)
            try await flow.run(order.map { "\($0).request" })
            try await flow.run(["localEdits1.start", "localEdits1.finish", "localEdits1.resume"])
            try await flow.run(["probe1.start", "probe1.finish", "probe1.resume"])
            try await flow.drain()
            XCTAssertEqual(fixture.calls.values, ["probe"])
            XCTAssertEqual(fixture.model.state, .loaded(fixture.kept.replacing(localEdits: .countsUnknown)))
            XCTAssertEqual(flow.publications.filter { $0.event == "localEdits1.resume" }.count, 1)
            await flow.close()
        }
    }

    func testSharedProbeWaitersResumeInEitherChosenOrder() async throws {
        for order in [["A", "B"], ["B", "A"]] {
            let fixture = try sequenceFixture(.memory, moved: true)
            let flow = fixture.flow
            fixture.enqueue("A")
            fixture.enqueue("B")
            try await flow.run(["\(order[0]).request", "probe1.start", "\(order[1]).request", "probe1.finish"])
            XCTAssertEqual(flow.enabled, ["probe1.resume"])
            try await flow.release("probe1.resume")
            try flow.validateCompletedApplications()
            try await flow.drain()
            XCTAssertEqual(fixture.calls.values, ["probe", "read"])
            XCTAssertEqual(fixture.model.state, .loaded(fixture.fresh))
            await flow.close()
        }
    }

    func testDiskRetryKeepsRowsAndItsFailureOnReopen() async throws {
        let fixture = try sequenceFixture(.disk, fails: true)
        let flow = fixture.flow
        fixture.enqueue("A", intent: .retry)
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume", "read1.start"])
        XCTAssertEqual(fixture.model.state, .refreshing(fixture.kept))
        fixture.enqueue("B", intent: .mountedRefresh)
        try await flow.release("B.request")
        try await flow.drain()
        guard case let .loadedWithFailure(result, note) = fixture.model.state else {
            XCTFail("A failed refresh must retain the disk rows and show its note")
            await flow.close()
            return
        }
        XCTAssertEqual(result, fixture.kept)
        XCTAssertTrue(note.contains("sequence offline"))
        fixture.enqueue("C")
        try await flow.drain()
        XCTAssertEqual(fixture.model.state, .loadedWithFailure(result, note))
        XCTAssertEqual(fixture.calls.values, ["read"])
        await flow.close()
    }

}
