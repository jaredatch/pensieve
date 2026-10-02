import XCTest
@testable import Pensieve

@MainActor
extension UpstreamHistoryRequestOwnershipTests {
    /// Protects 39.2-c and 39.2-k (R7-1): only the current probe waiter can act on its answer.
    func testCurrentRequestWinsAProbeSharedWithAnOlderRequest() async throws {
        let fixture = try sequenceFixture(.memory, moved: true)
        let flow = fixture.flow
        fixture.enqueue("A")
        try await flow.run(["A.request", "probe1.start"])
        fixture.enqueue("B", changed: true)
        try await flow.run(["B.request", "localEdits1.start", "probe1.finish", "probe1.resume"])

        // A has actually returned while B's local measurement is still held. Waiting for the
        // probe to disappear here was impossible: only B may consume its retained answer.
        XCTAssertEqual(flow.lanes["A"], .done)
        XCTAssertEqual(fixture.calls.values, ["probe"])
        XCTAssertEqual(flow.enabled, ["localEdits1.finish"])
        try await flow.run(["localEdits1.finish", "localEdits1.resume", "read1.start"])
        XCTAssertEqual(fixture.model.state, .refreshing(fixture.kept))
        try await flow.drain()

        XCTAssertEqual(fixture.calls.values, ["probe", "read"])
        XCTAssertEqual(fixture.model.state, .loaded(fixture.fresh))
        await flow.close()
    }

    /// Protects 39.2-c (R7-3): a disk answer joins the exact read already refreshing its question.
    func testDiskAnswerJoinsAnExactReadAlreadyInFlight() async throws {
        let diskResult = result(head: String(repeating: "1", count: 40), subject: "disk")
        let networkResult = result(head: String(repeating: "2", count: 40), subject: "network")
        let skill = installedHistorySkill()
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = TestWait.Gate(owner: self)
        let model = owner(cache: cache()) { _, _, _ in
            readStarted.signal()
            try releaseRead.wait()
            return networkResult
        }

        let older = Task { await model.request(skill: skill) }
        let readDidStart = await waitForHistorySemaphore(readStarted)
        XCTAssertTrue(readDidStart)
        try seedHistoryDisk(diskResult, for: skill, in: cache())
        let current = Task { await model.request(skill: skill) }
        let joined = await waitForHistoryCondition {
            model.state == .refreshing(diskResult)
                && model.reads.values.first?.waiters.count == 2
        }

        XCTAssertTrue(joined)
        XCTAssertEqual(model.state, .refreshing(diskResult))
        releaseRead.open()
        await older.value
        await current.value

        XCTAssertEqual(model.state, .loaded(networkResult))
    }
}
