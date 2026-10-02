import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryFlowAwayTests: UpstreamHistoryCacheTestCase {
    func testStaleLocalCompletionIsRemovedAndSameRevisionMeasuresAgain() async throws {
        let measurements = LockedHistoryMeasurements()
        let fixture = try sequenceFixture(.memory, measure: { measurements.next() })
        let flow = fixture.flow
        fixture.enqueue("A", changed: true)
        try await flow.run(["A.request", "localEdits1.start"])
        flow.enqueue("switch") { await fixture.model.request(skill: fixture.otherSkill) }
        try await flow.run(["switch.request", "localEdits1.finish", "localEdits1.resume"])
        XCTAssertEqual(fixture.model.state, .loaded(fixture.otherResult))
        XCTAssertEqual(flow.lanes["A"], .done)
        fixture.enqueue("B", changed: true)
        try await flow.run(["B.request", "localEdits2.start", "localEdits2.finish", "localEdits2.resume"])
        try await flow.drain()
        XCTAssertEqual(measurements.count, 2)
        XCTAssertEqual(fixture.model.state, .loaded(fixture.kept))
        try fixture.validatePublications()
        try flow.validateApplications()
        await flow.close()
    }

    func testProbeFinishingAwayIsConsumedOnceOnReturnForMovedHeadAndFailure() async throws {
        for fails in [false, true] {
            let fixture = try sequenceFixture(.memory, moved: true, fails: fails)
            let flow = fixture.flow
            fixture.enqueue("A")
            try await flow.run(["A.request", "probe1.start"])
            flow.enqueue("switch") { await fixture.model.request(skill: fixture.otherSkill) }
            try await flow.run(["switch.request", "probe1.finish", "probe1.resume"])
            XCTAssertEqual(fixture.model.state, .loaded(fixture.otherResult))
            fixture.enqueue("B")
            try await flow.drain()
            let returned = fixture.model.state
            if fails {
                guard case let .loadedWithFailure(result, message) = returned else { return XCTFail("Lost probe failure") }
                XCTAssertEqual(result, fixture.kept)
                XCTAssertTrue(message.contains("sequence offline"))
            } else { XCTAssertEqual(returned, .loaded(fixture.fresh)) }
            fixture.enqueue("C")
            try await flow.drain()
            XCTAssertEqual(fixture.model.state, returned)
            XCTAssertEqual(fixture.calls.values, fails ? ["probe"] : ["probe", "read"])
            XCTAssertNil(fixture.model.flows[fixture.skill.id]?.probeAnswer)
            try fixture.validatePublications()
            try flow.validateApplications()
            await flow.close()
        }
    }

    func testPublicationInvariantRejectsWrongSourceAndWrongRowsWithTwoRealSkills() throws {
        let fixture = try sequenceFixture(.memory)
        fixture.model.currentSkillID = fixture.skill.id
        fixture.model.publish(.loaded(fixture.otherResult), skillID: fixture.otherSkill.id)
        XCTAssertThrowsError(try fixture.validatePublications(), "Source identity must be checked against the visible skill")
        fixture.model.publish(.idle, skillID: fixture.skill.id)
        fixture.flow.publications.removeAll()
        fixture.model.publish(.loaded(fixture.otherResult), skillID: fixture.skill.id)
        XCTAssertThrowsError(try fixture.validatePublications(), "Correctly tagged foreign rows must still fail")
        fixture.model.publish(.idle, skillID: fixture.skill.id)
        fixture.flow.publications.removeAll()
        fixture.model.currentSkillID = fixture.otherSkill.id
        fixture.model.publish(.loaded(fixture.otherResult), skillID: fixture.otherSkill.id)
        XCTAssertNoThrow(try fixture.validatePublications())
        XCTAssertEqual(fixture.flow.publications.count, 1)
    }
}

private final class LockedHistoryMeasurements {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func next() -> UpstreamHistoryLocalEdits {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls == 1 ? .countsUnknown : .none
    }
}
